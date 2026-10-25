"""End-to-end acceptance checks against a built site (no UI mocks).

Run with the environment's Python containing Playwright and a running static
server. LARP_WEB_URL defaults to the internal test server. Never publish it.
"""
import json
import os
from pathlib import Path
import re
import shutil
import struct
import time
import zlib
import zipfile

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = Path(os.environ.get('LARP_WEB_ARTIFACTS', '/workspace/larp-artifacts/web-tests'))
ARTIFACTS.mkdir(parents=True, exist_ok=True)
URL = os.environ.get('LARP_WEB_URL', 'http://127.0.0.1:5173')
checks = []


def passed(message):
    checks.append(message)
    print('PASS:', message, flush=True)


def png():
    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 2, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress((b'\x00' + b'\x35\x79\xa5' * 32) * 32)) + chunk(b'IEND', b'')
    path = ARTIFACTS / 'Фото.png'
    path.write_bytes(data)
    return path


with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'), headless=True, args=['--no-sandbox'])
    context = browser.new_context(viewport={'width': 1440, 'height': 1000}, accept_downloads=True)
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.goto(URL)
    page.wait_for_load_state('networkidle')
    page.get_by_role('button', name='Создать игровой проект', exact=True).click()
    page.locator('dialog [name=name]').fill('Игра для проверки обновлений')
    page.locator('dialog [name=description]').fill('Демонстрационный проект. Не игровые материалы.')
    page.get_by_role('button', name='Создать проект', exact=True).click()
    expect(page.locator('dialog')).to_have_count(0)
    passed('Project created in real browser IndexedDB')

    page.locator('[data-page=locations]').click()
    page.get_by_role('button', name='Добавить локацию').click()
    page.locator('dialog [name=name]').fill('Библиотека')
    page.get_by_role('button', name='Сохранить локацию').click()
    page.locator('[data-page=materials]').click()
    page.locator('[data-action=new-record]').first.click()
    page.locator('#record-title').fill('Дневник смотрителя')
    page.locator('#record-location').select_option(label='Библиотека')
    page.locator('[data-add=text]').click()
    page.locator('[contenteditable=true]').fill('Страница дневника. Русские символы: ё, й, ж.')
    with page.expect_file_chooser() as chooser:
        page.locator('[data-add=image]').click()
    chooser.value.set_files(png())
    expect(page.locator('.content-block')).to_have_count(2)
    page.locator('[data-move="1,-1"]').click()
    page.locator('#editor-preview').click()
    expect(page.locator('.preview-dialog img')).to_have_count(1)
    expect(page.locator('.player-content')).to_contain_text('Страница дневника')
    page.get_by_role('button', name='Закрыть предпросмотр', exact=True).click()
    page.locator('#record-save').click()
    expect(page.locator('.record-editor')).to_have_count(0)
    code = page.locator('.code-pill').first.inner_text().strip()
    assert re.fullmatch(r'[1-9][0-9]{4}', code), code
    expect(page.locator('.location-name')).to_contain_text('Библиотека')
    passed('Text/image blocks, ordering, copied media, preview and auto-only code')

    page.reload()
    page.wait_for_load_state('networkidle')
    expect(page.locator('.code-pill')).to_have_text(code)
    page.locator('.record-title').click()
    expect(page.locator('.content-block').first).to_contain_text('Фото')
    page.locator('#record-title').fill('Дневник — новая редакция')
    page.locator('#record-save').click()
    expect(page.locator('.record-editor')).to_have_count(0)
    expect(page.locator('.record-title')).to_have_text('Дневник — новая редакция')
    expect(page.locator('.code-pill')).to_have_text(code)
    passed('Reload retains project/media; editing preserves assigned code')

    page.locator('#search').fill('Не существует')
    expect(page.locator('#record-rows tr')).to_have_count(0)
    page.locator('#search').fill(code)
    expect(page.locator('#record-rows tr')).to_have_count(1)
    page.locator('#search').fill('')
    page.locator('#location-filter').select_option('none')
    expect(page.locator('#record-rows tr')).to_have_count(0)
    page.locator('#location-filter').select_option('all')
    page.screenshot(path=str(ARTIFACTS / 'web-workshop.png'), full_page=True)
    passed('Search by code and location filtering')

    # An application update changes code files; IndexedDB must survive it.
    bundle = next(path for path in (ROOT / 'web/dist/assets').glob('index-*.js')
                  if 'LARP Studio <span>0.2</span>' in path.read_text())
    original = bundle.read_text()
    index = ROOT / 'web/dist/index.html'
    original_index = index.read_text()
    updated_bundle = bundle.with_name(bundle.stem + '-update.js')
    try:
        # Vite deploys a new content-hashed script URL, so test a new URL too.
        updated_bundle.write_text(original.replace('LARP Studio <span>0.2</span>', 'LARP Studio <span>0.2-update</span>'))
        index.write_text(original_index.replace(bundle.name, updated_bundle.name))
        os.utime(index, (time.time() + 2, time.time() + 2))
        session = context.new_cdp_session(page)
        session.send('Network.enable')
        session.send('Network.setCacheDisabled', {'cacheDisabled': True})
        page.set_extra_http_headers({'Cache-Control': 'no-cache'})
        page.reload()
        page.wait_for_load_state('networkidle')
        expect(page.locator('.version')).to_contain_text('0.2-update')
        expect(page.locator('.code-pill')).to_have_text(code)
        expect(page.locator('.record-title')).to_have_text('Дневник — новая редакция')
    finally:
        index.write_text(original_index)
        os.utime(index, None)
        updated_bundle.unlink(missing_ok=True)
    passed('Replacing deployed application JS preserves existing game and code')

    page.locator('[data-page=print]').click()
    for action, name in [('excel', 'codes.xlsx'), ('pdf', 'cards.pdf')]:
        with page.expect_download() as event:
            page.locator(f'[data-action={action}]').click()
        event.value.save_as(ARTIFACTS / name)
        assert (ARTIFACTS / name).stat().st_size > 500
    with zipfile.ZipFile(ARTIFACTS / 'codes.xlsx') as book:
        assert code in book.read('xl/sharedStrings.xml').decode()
        assert 'Дневник — новая редакция' in book.read('xl/sharedStrings.xml').decode()
    passed('Real XLSX and PDF downloads produced')

    page.locator('[data-page=builds]').click()
    with page.expect_download() as event:
        page.locator('.page-actions [data-action=package]').click()
    event.value.save_as(ARTIFACTS / 'game.rpgpack')
    with zipfile.ZipFile(ARTIFACTS / 'game.rpgpack') as archive:
        manifest = json.loads(archive.read('manifest.json'))
        assert manifest['records'][0]['code'] == code
        assert manifest['records'][0]['blocks'][0]['kind'] == 'image'
        assert manifest['version'] == 1
    passed('Portable versioned package contains correct code and ordered media')

    other = browser.new_context(viewport={'width': 1280, 'height': 900}, accept_downloads=True)
    imported = other.new_page()
    imported.goto(URL)
    imported.wait_for_load_state('networkidle')
    with imported.expect_file_chooser() as chooser:
        imported.locator('[data-action=import]').click()
    chooser.value.set_files(ARTIFACTS / 'game.rpgpack')
    expect(imported.locator('.code-pill')).to_have_text(code)
    imported.locator('.record-title').click()
    expect(imported.locator('.block-image')).to_have_count(1)
    assert imported.locator('.block-image').evaluate('(img)=>img.complete && img.naturalWidth===32')
    imported.locator('#editor-close').click()
    imported.reload()
    expect(imported.locator('.code-pill')).to_have_text(code)
    passed('Import into fresh browser/device restores project and real image bytes')

    mobile = browser.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True)
    small = mobile.new_page()
    small.goto(URL)
    small.wait_for_load_state('networkidle')
    assert small.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Horizontal page overflow'
    small.screenshot(path=str(ARTIFACTS / 'web-mobile.png'), full_page=True)
    passed('Narrow browser viewport remains usable without horizontal page overflow')
    assert errors == [], errors
    passed('No uncaught browser JavaScript errors')
    (ARTIFACTS / 'results.json').write_text(json.dumps({'passed': len(checks), 'checks': checks, 'browser_errors': errors}, ensure_ascii=False, indent=2))
    mobile.close()
    other.close()
    context.close()
    browser.close()
