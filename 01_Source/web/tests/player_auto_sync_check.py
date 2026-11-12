"""Real Chromium acceptance: character lists, permissions, polling and portable versions."""
import json
import os
import shutil
import zipfile
from playwright.sync_api import expect, sync_playwright
from backend_fixture import BackendFixture

URL = os.environ.get('LARP_WEB_URL', 'http://127.0.0.1:5173')

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'), headless=True, args=['--no-sandbox'])
    backend = BackendFixture()
    backend.player_auto_sync_available = True
    errors = []

    def login(user):
        context = browser.new_context(viewport={'width': 1280, 'height': 900}, accept_downloads=True)
        backend.install(context)
        page = context.new_page()
        page.clock.install()
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.goto(URL)
        backend.login(page, user + '@example.test')
        return page

    owner = login('master')
    owner.get_by_role('button', name='Новый проект', exact=True).click()
    owner.locator('dialog [name=name]').fill('Автоматическая игра')
    owner.get_by_role('button', name='Создать проект', exact=True).click()
    expect(owner.locator('dialog')).to_have_count(0)
    project_id = owner.locator('#project-switch').input_value()
    expect(owner.get_by_role('button', name='Игроки', exact=True)).to_be_visible()
    expect(owner.get_by_role('button', name='Участники проекта', exact=True)).to_be_visible()
    backend.players[project_id] = [{'participant_id': '11111111-1111-4111-8111-111111111111', 'character_name': '<Смотритель>',
                                  'first_seen': '2026-10-25T00:00:00Z', 'last_seen': '2026-10-25T01:00:00Z'}]
    owner.locator('[data-page=players]').click()
    expect(owner.get_by_role('heading', name='Игроки', exact=True)).to_be_visible()
    expect(owner.get_by_role('cell', name='<Смотритель>', exact=True)).to_be_visible()
    expect(owner.get_by_role('columnheader', name='Последняя связь')).to_be_visible()
    assert 'онлайн' not in owner.locator('main').inner_text().lower()
    assert '<Смотритель>' in owner.locator('main').inner_text()
    expect(owner.locator('main смотритель')).to_have_count(0)
    # Existing 20-second poll loads changes without navigation or another timer.
    backend.players[project_id][0]['character_name'] = 'Новое имя'
    owner.clock.fast_forward(20000)
    expect(owner.get_by_role('cell', name='Новое имя', exact=True)).to_be_visible()

    player_requests = backend.requests.count(('POST', '/rest/v1/rpc/list_game_players'))
    shared = login('colleague')
    expect(shared.locator('#project-switch option')).to_have_text('Создайте первый проект')
    shared.locator('[data-page=players]').click()
    expect(shared.get_by_text('Сначала откройте проект.', exact=True)).to_be_visible()
    assert backend.requests.count(('POST', '/rest/v1/rpc/list_game_players')) == player_requests
    backend.grant_membership(project_id)
    shared.clock.fast_forward(20000)
    expect(shared.locator('#project-switch option:checked')).to_have_text('Автоматическая игра')
    shared.locator('[data-page=players]').click()
    expect(shared.get_by_role('cell', name='Новое имя', exact=True)).to_be_visible()
    admin = login('admin')
    admin.locator('[data-page=players]').click()
    expect(admin.get_by_role('cell', name='Новое имя', exact=True)).to_be_visible()

    # Automatic source version can be ahead of the last manually built document.
    backend.projects[project_id]['player_version'] = 23
    owner.locator('[data-page=builds]').click()
    expect(owner.get_by_text('Сохранённые проекты и материалы автоматически загружаются', exact=False)).to_be_visible()
    with owner.expect_download() as download:
        owner.get_by_role('button', name='Создать игровой пакет', exact=True).click()
    manifest = json.loads(zipfile.ZipFile(download.value.path()).read('manifest.json'))
    assert manifest['version'] == 24
    assert backend.projects[project_id]['document']['version'] == 24
    assert backend.projects[project_id]['player_version'] == 24
    # Legacy publication remains available and uses the same increasing sequence.
    owner.get_by_role('button', name='Опубликовать обновление', exact=True).click()
    expect(owner.locator('#toast')).to_contain_text('Версия 25 опубликована')
    assert not errors, errors
    assert not backend.unhandled, backend.unhandled
    browser.close()
    print('PASS browser automatic sync: player names, owner/shared/admin access, 20s poll, portable v24 + legacy v25')
