"""Authenticated UI workflows using offline Supabase transport, never real mail.

This script verifies frontend account behavior, not PostgreSQL RLS. See the
fixture docstring and backend/test-policies.sql for that separation.
"""
import os
from pathlib import Path
import shutil
import struct
import zipfile

from playwright.sync_api import expect, sync_playwright
from backend_fixture import BackendFixture

URL = os.environ.get('LARP_WEB_URL', 'http://127.0.0.1:5173')
ARTIFACTS = Path(os.environ.get('LARP_WEB_ARTIFACTS', '/workspace/larp-artifacts/web-tests'))
ARTIFACTS.mkdir(parents=True, exist_ok=True)


def create_project(page, name):
    page.get_by_role('button', name='Новый проект', exact=True).click()
    page.locator('dialog [name=name]').fill(name)
    page.get_by_role('button', name='Создать проект', exact=True).click()
    expect(page.locator('dialog')).to_have_count(0)
    expect(page.locator('#project-switch option:checked')).to_have_text(name)
    return page.locator('#project-switch').input_value()


def record(page, name, text):
    page.locator('[data-page=materials]').click()
    page.locator('[data-action=new-record]').first.click()
    page.locator('#record-title').fill(name)
    page.locator('[data-add=text]').click()
    page.locator('[contenteditable]').fill(text)
    page.locator('#record-save').click()
    expect(page.locator('.record-editor')).to_have_count(0)
    expect(page.locator('.record-title').filter(has_text=name)).to_be_visible()


with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'),
                                headless=True, args=['--no-sandbox'])
    backend = BackendFixture()
    errors, console_errors, failures = [], [], []
    contexts = []

    def device(email=None):
        context = browser.new_context(viewport={'width': 1440, 'height': 1000}, accept_downloads=True)
        contexts.append(context)
        backend.install(context)
        page = context.new_page()
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('console', lambda message: console_errors.append(message.text) if message.type == 'error' else None)
        page.on('requestfailed', lambda request: failures.append((request.url, request.failure)))
        page.goto(URL)
        expect(page.locator('#account-form')).to_be_visible()
        expect(page.locator('#project-switch')).to_have_count(0)
        expect(page.get_by_role('heading', name='Вход в мастерскую')).to_be_visible()
        if email:
            backend.login(page, email=email)
        return page

    master = device('master@example.test')
    expect(master.locator('[data-page=admin]')).to_have_count(0)
    # SDK SIGNED_IN and explicit sign-in completion must mount one account once.
    assert backend.requests.count(('POST', '/rest/v1/rpc/get_workshop_identity')) == 1
    shared_id = create_project(master, 'Общая игра двух мастеров')
    record(master, 'Первая запись', 'Текст владельца, доступный коллегам.')
    first_code = master.locator('.code-pill').first.inner_text()
    master.locator('[data-page=members]').click()
    master.locator('.team-invite [name=email]').fill('colleague@example.test')
    master.get_by_role('button', name='Добавить участника', exact=True).click()
    expect(master.locator('.team-list')).to_contain_text('colleague@example.test')
    expect(master.locator('#toast')).to_have_text('Участник добавлен.')

    colleague = device('colleague@example.test')
    expect(colleague.locator('#project-switch option:checked')).to_have_text('Общая игра двух мастеров')
    expect(colleague.locator('.record-title')).to_have_text('Первая запись')
    expect(colleague.locator('.code-pill')).to_have_text(first_code)
    colleague.locator('[data-page=members]').click()
    expect(colleague.locator('.team-invite')).to_have_count(0)
    expect(colleague.locator('.team-list')).to_contain_text('Владелец')
    expect(colleague.locator('.team-list')).to_contain_text('Редактор')
    record(colleague, 'Запись коллеги', 'Изменение с другого компьютера.')
    master.reload()
    expect(master.locator('.record-title')).to_have_count(2)
    expect(master.locator('#record-rows')).to_contain_text('Запись коллеги')
    assert len(backend.projects[shared_id]['document']['records']) == 2
    print('PASS: real login, one account mount, sharing, two masters, cross-context cloud persistence', flush=True)

    # Start both edits from the same snapshot, then save in either order.
    master.get_by_role('button', name='Первая запись', exact=True).click()
    colleague.get_by_role('button', name='Запись коллеги', exact=True).click()
    master.locator('[contenteditable]').fill('Параллельная правка владельца.')
    colleague.locator('[contenteditable]').fill('Параллельная правка коллеги.')
    master.locator('#record-save').click()
    expect(master.locator('.record-editor')).to_have_count(0)
    colleague.locator('#record-save').click()
    expect(colleague.locator('.record-editor')).to_have_count(0)
    documents = {row['title']: row for row in backend.projects[shared_id]['document']['records']}
    assert 'Параллельная правка владельца.' in documents['Первая запись']['blocks'][0]['value']
    assert 'Параллельная правка коллеги.' in documents['Запись коллеги']['blocks'][0]['value']

    master.reload()
    master.get_by_role('button', name='Первая запись', exact=True).click()
    colleague.get_by_role('button', name='Первая запись', exact=True).click()
    master.locator('[contenteditable]').fill('Сохранённая новая редакция.')
    colleague.locator('[contenteditable]').fill('Мой несохранённый текст при конфликте.')
    master.locator('#record-save').click()
    expect(master.locator('.record-editor')).to_have_count(0)
    colleague.locator('#record-save').click()
    expect(colleague.locator('.dialog-error')).to_contain_text('Запись изменена')
    expect(colleague.locator('.record-editor')).to_be_visible()
    expect(colleague.locator('[contenteditable]')).to_have_text('Мой несохранённый текст при конфликте.')
    expect(colleague.locator('#record-save')).to_be_enabled()
    colleague.locator('#editor-cancel').click()
    # Unsaved-change confirmation is a real application dialog.
    if colleague.locator('dialog').count():
        colleague.locator('dialog .dialog-actions [type=submit]').click()
    expect(colleague.locator('.record-editor')).to_have_count(0)
    print('PASS: simultaneous different-record edits merge; same-record conflict keeps unsaved text', flush=True)

    private_id = create_project(colleague, 'Личная игра коллеги')
    record(colleague, 'Личный материал', 'Только для отдельного проекта.')
    colleague.locator('#project-switch').select_option(shared_id)
    expect(colleague.locator('#record-rows')).not_to_contain_text('Личный материал')
    expect(colleague.locator('.record-title')).to_have_count(2)
    master.reload()
    expect(master.locator('#project-switch option')).to_have_count(1)
    expect(master.locator('#project-switch')).not_to_contain_text('Личная игра коллеги')
    assert backend.projects[private_id]['owner_id'] == backend.users['colleague']['user_id']
    print('PASS: independent projects retain separate records and master visibility', flush=True)

    # Image templates use the real static PNG, canvas, multipart upload and ZIP.
    master.locator('[data-page=print]').click()
    expect(master.locator('.tpl-export')).to_be_disabled()
    master.get_by_role('button', name='Пример «Сновидение»').click()
    expect(master.locator('.tpl-canvas')).to_be_visible()
    assert master.locator('.tpl-canvas').evaluate('(canvas)=>[canvas.width,canvas.height]') == [761, 916]
    master.locator('.tpl-size').fill('42')
    master.locator('.tpl-color').fill('#b51218')
    master.locator('.tpl-font').select_option('serif')
    master.locator('.tpl-canvas').click(position={'x': 120, 'y': 180})
    master.locator('.tpl-save').click()
    expect(master.locator('.tpl-status')).to_have_text('Шаблон группы сохранён.')
    assert backend.media, 'Template must upload actual PNG bytes to cloud storage'
    saved = backend.projects[shared_id]['document']['printTemplates']['all']
    assert saved['font'] == 'serif' and saved['color'] == '#b51218'
    colleague.reload()
    colleague.locator('[data-page=print]').click()
    expect(colleague.locator('.tpl-canvas')).to_be_visible()
    expect(colleague.locator('.tpl-size')).to_have_value('42')
    expect(colleague.locator('.tpl-color')).to_have_value('#b51218')
    with colleague.expect_download() as download:
        colleague.locator('.tpl-export').click()
    target = ARTIFACTS / 'account-cards.zip'
    download.value.save_as(target)
    with zipfile.ZipFile(target) as archive:
        expected = sorted(row['code'] + '.png' for row in backend.projects[shared_id]['document']['records'])
        assert sorted(archive.namelist()) == expected
        for name in expected:
            data = archive.read(name)
            assert data.startswith(b'\x89PNG\r\n\x1a\n')
            assert struct.unpack('>II', data[16:24]) == (761, 916)
    print('PASS: saved cloud image template reopens on second computer and exports real code PNGs', flush=True)

    admin = device('admin@example.test')
    expect(admin.locator('#project-switch option')).to_have_count(2)
    admin.locator('[data-page=admin]').click()
    expect(admin.get_by_role('heading', name='Пользователи мастерской')).to_be_visible()
    expect(admin.locator('.team-list tbody tr')).to_have_count(3)
    admin.locator('.sidebar [data-page=profile]').click()
    expect(admin.locator('.profile-email').first).to_have_text('admin@example.test')
    admin.locator('.profile-form [name=name]').fill('Администратор проверки')
    admin.get_by_role('button', name='Сохранить имя', exact=True).click()
    expect(admin.locator('.account-name')).to_contain_text('Администратор проверки')
    admin.reload()
    expect(admin.locator('.account-name')).to_contain_text('Администратор проверки')
    print('PASS: admin sees all projects and user management; profile name persists', flush=True)

    # Switch accounts in one browser: no stale shell, data or admin privileges.
    admin.locator('[data-action=logout]').click()
    expect(admin.locator('#account-form')).to_be_visible()
    expect(admin.locator('.workspace')).to_have_count(0)
    expect(admin.locator('dialog')).to_have_count(0)
    admin.reload()
    expect(admin.locator('#account-form')).to_be_visible()
    backend.login(admin, email='master@example.test')
    expect(admin.locator('[data-page=admin]')).to_have_count(0)
    expect(admin.locator('.account-name')).to_contain_text('Master')
    expect(admin.locator('#project-switch option')).to_have_count(1)
    expect(admin.locator('#record-rows')).not_to_contain_text('Личный материал')
    admin.locator('[data-action=logout]').click()
    expect(admin.locator('#account-form')).to_be_visible()
    backend.login(admin, email='colleague@example.test')
    expect(admin.locator('#project-switch option')).to_have_count(2)
    expect(admin.locator('.account-name')).to_contain_text('Colleague')
    expect(admin.locator('[data-page=admin]')).to_have_count(0)
    print('PASS: logout, reload, rapid account changes clear private UI and restore correct permissions', flush=True)

    # Cross-tab SIGNED_OUT must invalidate an in-flight account initialization.
    backend.hold_next_identity = True
    delayed = admin.context.new_page()
    delayed.on('pageerror', lambda error: errors.append(str(error)))
    delayed.on('console', lambda message: console_errors.append(message.text) if message.type == 'error' else None)
    delayed.on('requestfailed', lambda request: failures.append((request.url, request.failure)))
    delayed.goto(URL)
    expect(delayed.locator('.auth-card')).to_contain_text('Проверяем доступ')
    delayed.wait_for_function('document.querySelector(".auth-card")?.textContent.includes("Проверяем доступ")')
    # Route callbacks are dispatched while Playwright waits for the next event.
    admin.locator('[data-action=logout]').click()
    expect(admin.locator('#account-form')).to_be_visible()
    assert len(backend.pending_identities) == 1
    backend.release_identities()
    expect(delayed.locator('#account-form')).to_be_visible()
    expect(delayed.locator('.workspace')).to_have_count(0)
    delayed.reload()
    expect(delayed.locator('#account-form')).to_be_visible()
    print('PASS: cross-tab logout wins over delayed account initialization and reload', flush=True)

    assert backend.unhandled == [], backend.unhandled
    assert backend.auth_mail_requests == [], backend.auth_mail_requests
    assert errors == [], errors
    assert console_errors == [], console_errors
    assert failures == [], failures
    for context in contexts:
        context.close()
    browser.close()
    print('PASS: no uncaught JavaScript, console, network or unhandled fixture errors; no real auth emails', flush=True)
