"""Real UI regressions from independent review, offline protocol fixture."""
import os
import shutil
import unittest
from playwright.sync_api import sync_playwright, expect
from backend_fixture import BackendFixture

URL=os.environ.get('LARP_WEB_URL','http://127.0.0.1:5173')

class ReviewRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p=sync_playwright().start()
        cls.browser=cls.p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
    @classmethod
    def tearDownClass(cls):
        cls.browser.close();cls.p.stop()
    def setUp(self):
        self.backend=BackendFixture();self.context=self.browser.new_context(accept_downloads=True)
        self.backend.install(self.context)
        self.context.add_init_script('''() => {}''')
        self.context.add_init_script('''const originalInterval=window.setInterval;window.setInterval=function(fn,ms,...rest){if(ms===20000)window.__workshopPoll=fn;return originalInterval(fn,ms,...rest);};''')
        self.page=self.context.new_page()
    def tearDown(self):self.context.close()
    def ready(self):
        self.page.goto(URL);self.backend.login(self.page)
        self.page.get_by_role('button',name='Новый проект',exact=True).click()
        self.page.locator('dialog [name=name]').fill('Проверка ревью')
        self.page.get_by_role('button',name='Создать проект',exact=True).click()
        expect(self.page.locator('dialog')).to_have_count(0)
        self.page.locator('[data-action=new-record]').first.click()
        self.page.locator('#record-title').fill('Видение')
        self.page.locator('#record-save').click();expect(self.page.locator('.record-editor')).to_have_count(0)
        expect(self.page.locator('.record-title')).to_have_text('Видение')
    def template(self):
        self.ready();self.page.locator('[data-page=print]').click()
        self.page.get_by_role('button',name='Пример «Сновидение»').click()
        expect(self.page.locator('.tpl-export')).to_be_enabled()
        self.page.locator('.tpl-save').click();expect(self.page.locator('.tpl-status')).to_have_text('Шаблон группы сохранён.')
    def test_background_poll_does_not_cancel_a_clean_template_export(self):
        self.template()
        self.page.evaluate('''() => {const original=HTMLCanvasElement.prototype.toBlob;HTMLCanvasElement.prototype.toBlob=function(cb,...args){return original.call(this,blob=>setTimeout(()=>cb(blob),1200),...args);};}''')
        with self.page.expect_download(timeout=10000) as event:
            self.page.locator('.tpl-export').click()
            self.page.evaluate('window.__workshopPoll()')
        self.assertTrue(event.value.suggested_filename.endswith('.zip'))
        expect(self.page.locator('.tpl-status')).to_contain_text('ZIP готов')
    def test_large_font_still_fits_five_digits_on_the_image(self):
        self.template();self.page.locator('.tpl-size').fill('458')
        dimensions=self.page.locator('.tpl-canvas').evaluate('(c)=>({width:c.width,text:c.getContext("2d").measureText("12345").width})')
        self.assertLessEqual(dimensions['text'],dimensions['width']-4+.1)
    def test_registered_name_is_not_discarded_by_an_empty_workshop_profile(self):
        self.backend.users['master']['display_name']=''
        self.backend.users['master']['auth_display_name']='Имя при регистрации'
        self.page.goto(URL);self.backend.login(self.page,'master@example.test')
        expect(self.page.locator('.account-name')).to_contain_text('Имя при регистрации')
        self.assertEqual(self.backend.users['master']['display_name'],'Имя при регистрации')
    def test_duplicate_group_error_uses_the_new_group_name(self):
        self.ready();self.page.locator('[data-page=groups]').click()
        for attempt in range(2):
            self.page.get_by_role('button',name='Добавить группу',exact=True).click()
            self.page.locator('dialog [name=name]').fill('Сны')
            self.page.get_by_role('button',name='Сохранить группу',exact=True).click()
            if not attempt:expect(self.page.locator('dialog')).to_have_count(0)
        expect(self.page.locator('.dialog-error')).to_contain_text('Группа')
        self.assertNotIn('локац',self.page.locator('.dialog-error').inner_text().lower())
    def test_remotely_deleted_selection_falls_back_to_another_available_project(self):
        self.ready()
        self.page.get_by_role('button',name='Новый проект',exact=True).click()
        self.page.locator('dialog [name=name]').fill('Временно выбранный проект')
        self.page.get_by_role('button',name='Создать проект',exact=True).click()
        expect(self.page.locator('dialog')).to_have_count(0)
        selected=self.page.locator('#project-switch').input_value()
        del self.backend.projects[selected]
        self.page.evaluate('window.__workshopPoll()')
        expect(self.page.locator('.record-title')).to_have_text('Видение')

if __name__=='__main__':unittest.main(verbosity=2)
