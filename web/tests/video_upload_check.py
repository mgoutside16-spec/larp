"""Real browser/SDK/HTTP upload regressions; all accounts/files are synthetic."""
import base64
import hashlib
import os
from pathlib import Path
import re
import shutil
import struct
import unittest
from playwright.sync_api import sync_playwright, expect
from backend_fixture import BackendFixture

URL = os.environ.get('LARP_WEB_URL', 'http://127.0.0.1:5173')
ROOT = Path(__file__).resolve().parents[2]
VIDEO = base64.b64decode(re.search(r"base64Decode\(\s*'([^']+)'", (ROOT / 'mobile/integration_test/media_fixture.dart').read_text()).group(1))

class VideoUploadCheck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = sync_playwright().start()
        cls.browser = cls.p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'), headless=True, args=['--no-sandbox'])
    @classmethod
    def tearDownClass(cls):
        cls.browser.close(); cls.p.stop()
    def setUp(self):
        self.context = self.browser.new_context(viewport={'width': 1280, 'height': 900})
        self.backend = BackendFixture(); self.backend.install(self.context)
        self.page = self.context.new_page(); self.errors = []; self.held = []
        self.page.on('pageerror', lambda e: self.errors.append(str(e)))
        self.page.goto(URL); self.page.wait_for_load_state('networkidle'); self.backend.login(self.page)
        self.page.get_by_role('button', name='Новый проект', exact=True).click()
        self.page.locator('dialog [name=name]').fill('Проверка видео')
        self.page.get_by_role('button', name='Создать проект', exact=True).click()
        expect(self.page.locator('dialog')).to_have_count(0)
        self.page.locator('[data-action=new-record]').first.click()
        self.page.locator('#record-title').fill('Видео и текст')
        self.page.locator('[data-add=text]').click(); self.page.locator('[contenteditable]').fill('Не потерять этот текст')
    def tearDown(self):
        self.assertEqual(self.errors, []); self.assertEqual(self.backend.unhandled, [])
        for route in self.held:
            try: route.abort()
            except Exception: pass  # The browser may already have cancelled it.
        self.context.unroute_all(behavior="ignoreErrors")
        self.context.close()
    def add_video(self, data=VIDEO):
        with self.page.expect_file_chooser() as chooser:
            self.page.locator('[data-add=video]').click()
        chooser.value.set_files({'name': 'Проверка.mp4', 'mimeType': 'video/mp4', 'buffer': data})
        expect(self.page.locator('video')).to_have_count(1)
        expect(self.page.locator('#record-save')).to_be_enabled()
    def hold_uploads(self):
        held = []
        def route(request):
            if request.request.method == 'POST':
                held.append(request); self.held.append(request)
            else: request.fallback()
        self.context.route(self.backend.backend + '/storage/v1/object/workshop-media/**', route)
        return held
    def test_pending_upload_is_visible_and_can_be_stopped_without_losing_the_draft(self):
        self.add_video(); held = self.hold_uploads()
        self.page.locator('#record-save').click()
        expect(self.page.get_by_role('status').filter(has_text='Загружаем')).to_be_visible()
        expect(self.page.get_by_role('progressbar')).to_be_visible()
        self.page.get_by_role('button', name='Остановить загрузку').click()
        expect(self.page.locator('#record-save')).to_be_enabled()
        expect(self.page.locator('.record-editor')).to_be_visible()
        expect(self.page.locator('#record-title')).to_have_value('Видео и текст')
        expect(self.page.locator('[contenteditable]')).to_have_text('Не потерять этот текст')
        expect(self.page.locator('video')).to_have_count(1)
        self.assertEqual(sum(len(r['document']['records']) for r in self.backend.projects.values()), 0)
        self.assertTrue(held)
    def test_stalled_upload_times_out_and_can_retry_the_same_draft(self):
        self.add_video(); held = self.hold_uploads()
        self.page.clock.install()
        self.page.locator('#record-save').click()
        expect(self.page.get_by_role('status').filter(has_text='Загружаем')).to_be_visible()
        self.page.clock.fast_forward(65000)
        expect(self.page.locator('#record-save')).to_be_enabled()
        expect(self.page.locator('.dialog-error')).to_contain_text('не отвечает')
        expect(self.page.locator('#record-title')).to_have_value('Видео и текст')
        self.context.unroute(self.backend.backend + '/storage/v1/object/workshop-media/**')
        self.page.locator('#record-save').click()
        expect(self.page.locator('.record-editor')).to_have_count(0, timeout=15000)
        self.assertEqual(next(iter(self.backend.media.values()))[0], VIDEO)
    def test_stop_also_cancels_verification_of_an_already_uploaded_video(self):
        self.add_video()
        # First transfer succeeds in storage but loses its acknowledgement; retry
        # must verify a duplicate without letting another stalled GET trap Stop.
        project_id = self.page.locator('#project-switch').input_value()
        import hashlib
        key = project_id + '/media/' + hashlib.sha256(VIDEO).hexdigest() + '.mp4'
        self.backend.media[key] = (VIDEO, 'video/mp4')
        def hold_download(route):
            if route.request.method == 'GET': self.held.append(route)
            else: route.fallback()
        self.context.route(self.backend.backend + '/storage/v1/object/workshop-media/**', hold_download)
        self.page.locator('#record-save').click()
        self.page.wait_for_function("() => document.querySelector('#editor-cancel')?.textContent==='Остановить загрузку'")
        # Wait for the actual duplicate-verification request to be pending.
        expect(self.page.get_by_role('status').filter(has_text='Загружаем')).to_be_visible()
        self.page.wait_for_timeout(200)
        self.assertTrue(self.held)
        self.page.get_by_role('button', name='Остановить загрузку').click()
        expect(self.page.locator('#record-save')).to_be_enabled(timeout=3000)
        expect(self.page.locator('#record-title')).to_have_value('Видео и текст')
    def test_slow_real_upload_reports_intermediate_byte_progress(self):
        self.add_video()
        cdp = self.context.new_cdp_session(self.page)
        cdp.send('Network.enable')
        cdp.send('Network.emulateNetworkConditions', {'offline': False, 'latency': 0, 'uploadThroughput': 65536, 'downloadThroughput': -1})
        self.page.locator('#record-save').click()
        self.page.wait_for_function("() => {const p=document.querySelector('#editor-transfer progress');return p && p.value>0 && p.value<100;}", timeout=15000)
        expect(self.page.locator('#editor-transfer')).to_contain_text('из')
        self.page.screenshot(path=os.environ.get('LARP_WEB_ARTIFACTS', '/workspace/larp-artifacts') + '/video-progress.png')
        self.page.get_by_role('button', name='Остановить загрузку').click()
        expect(self.page.locator('#record-save')).to_be_enabled()
        cdp.send('Network.emulateNetworkConditions', {'offline': False, 'latency': 0, 'uploadThroughput': -1, 'downloadThroughput': -1})
    def test_forty_megabyte_video_saves_exact_bytes_and_reopens_with_its_code(self):
        size = 40 * 1024 * 1024
        padding = size - len(VIDEO)
        data = VIDEO + struct.pack('>I4s', padding, b'free') + bytes(padding - 8)
        self.add_video(data)
        self.page.locator('#record-save').click()
        expect(self.page.locator('.record-editor')).to_have_count(0, timeout=30000)
        raw = next(iter(self.backend.media.values()))[0]
        self.assertEqual(len(raw), size); self.assertEqual(hashlib.sha256(raw).digest(), hashlib.sha256(data).digest())
        code = self.page.locator('.code-pill').inner_text()
        self.page.locator('.record-title').click()
        expect(self.page.locator('video')).to_have_count(1)
        expect(self.page.locator('[contenteditable]')).to_have_text('Не потерять этот текст')
        expect(self.page.locator('.permanent-code strong')).to_have_text(code)

if __name__ == '__main__': unittest.main()
