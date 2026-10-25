"""Regression cases reproduced by independent review, against the real UI."""
import os
from pathlib import Path
import shutil
import unittest

from playwright.sync_api import sync_playwright, expect

URL = os.environ.get('LARP_WEB_URL', 'http://127.0.0.1:5173')


class BrowserRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'), headless=True, args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.context = self.browser.new_context()
        self.page = self.context.new_page()
        self.page.goto(URL)
        self.page.wait_for_load_state('networkidle')
        self.page.get_by_role('button', name='Новый проект', exact=True).click()
        self.page.locator('dialog [name=name]').fill('Регрессионная проверка')
        self.page.get_by_role('button', name='Создать проект', exact=True).click()
        expect(self.page.locator('dialog')).to_have_count(0)
        self.page.locator('[data-action=new-record]').first.click()
        self.page.locator('#record-title').fill('Запись для проверки')
        self.page.locator('[data-add=text]').click()

    def tearDown(self):
        self.context.close()

    def test_enter_keeps_separate_lines_after_save_and_reopen(self):
        field = self.page.locator('[contenteditable]')
        field.fill('Первая строка')
        field.press('End')
        field.press('Enter')
        field.press_sequentially('Вторая строка')
        self.page.locator('#record-save').click()
        expect(self.page.locator('.record-editor')).to_have_count(0)
        self.page.locator('.record-title').click()
        text = self.page.locator('[contenteditable]').inner_text()
        self.assertIn('Первая строка', text)
        self.assertIn('\n', text)
        self.assertNotIn('строкаВторая', text)

    def test_pending_media_and_text_edits_are_saved_together(self):
        self.page.locator('[contenteditable]').fill('Текст до загрузки')
        self.page.evaluate('''() => {
          const digest = crypto.subtle.digest.bind(crypto.subtle);
          crypto.subtle.digest = async (...args) => {
            await new Promise(resolve => setTimeout(resolve, 1500));
            return digest(...args);
          };
        }''')
        with self.page.expect_file_chooser() as chooser:
            self.page.locator('[data-add=image]').click()
        chooser.value.set_files({'name': 'test.png', 'mimeType': 'image/png', 'buffer': b'copy-race-fixture'})
        expect(self.page.locator('.dialog-error')).to_contain_text('Копирование')
        self.page.locator('[contenteditable]').fill('Текст во время загрузки')
        expect(self.page.locator('#record-save')).to_be_disabled()
        self.page.locator('#record-save').click()
        expect(self.page.locator('.record-editor')).to_have_count(0)
        self.page.locator('.record-title').click()
        expect(self.page.locator('.content-block')).to_have_count(2)
        expect(self.page.locator('[contenteditable]')).to_have_text('Текст во время загрузки')
        expect(self.page.locator('.block-image')).to_have_count(1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
