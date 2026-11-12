"""Real Chromium UI/ZIP/SDK publication against offline transport; RLS tested in PostgreSQL."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import zipfile

from playwright.sync_api import expect, sync_playwright
from backend_fixture import BackendFixture

URL = os.environ.get('LARP_WEB_URL', 'http://127.0.0.1:5173')
ARTIFACTS = Path(os.environ.get('LARP_WEB_ARTIFACTS', '/workspace/larp-artifacts/web-tests'))
ARTIFACTS.mkdir(parents=True, exist_ok=True)

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'), headless=True, args=['--no-sandbox'])
    backend = BackendFixture()
    owner = browser.new_context(viewport={'width': 1440, 'height': 1000}, permissions=['clipboard-read', 'clipboard-write'])
    backend.install(owner)
    page = owner.new_page()
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.goto(URL)
    backend.login(page, 'master@example.test')
    page.get_by_role('button', name='Новый проект', exact=True).click()
    page.locator('dialog [name=name]').fill('Обновления для игрока')
    page.get_by_role('button', name='Создать проект', exact=True).click()
    expect(page.locator('dialog')).to_have_count(0)
    project_id = page.locator('#project-switch').input_value()
    game_id = backend.projects[project_id]['document']['packageId']
    page.locator('[data-page=builds]').click()
    expect(page.get_by_role('button', name='Опубликовать обновление', exact=True)).to_be_visible()
    expect(page.get_by_role('link', name='Скачать приложение · 22 МБ', exact=True)).to_have_attribute('href', 'https://github.com/mgoutside16-spec/larp/releases/latest/download/LARP-Player-arm64.apk')
    expect(page.get_by_role('link', name='Совместимая версия для старых телефонов', exact=True)).to_have_attribute('href', 'https://github.com/mgoutside16-spec/larp/releases/latest/download/LARP-Player.apk')
    expect(page.locator('.player-qr img')).to_be_visible()
    backend.player_updates_available = False
    page.get_by_role('button', name='Опубликовать обновление', exact=True).click()
    expect(page.locator('#toast')).to_contain_text('backend/player-updates.sql')
    assert backend.projects[project_id]['document']['version'] == 0
    assert not backend.player_archives
    backend.player_updates_available = True
    page.get_by_role('button', name='Опубликовать обновление', exact=True).click()
    expect(page.locator('#toast')).to_contain_text('Версия 1 опубликована')
    release = backend.player_releases[game_id]
    raw, _ = backend.player_archives[release['download_path']]
    assert hashlib.sha256(raw).hexdigest() == release['sha256']
    assert len(raw) == release['size']
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        manifest = json.loads(archive.read('manifest.json'))
    assert manifest['version'] == 1 and manifest['game']['id'] == game_id
    page.get_by_role('button', name='Скопировать ссылку игры', exact=True).click()
    expect(page.locator('#toast')).to_contain_text('Ссылка игры скопирована')
    assert page.evaluate('navigator.clipboard.readText()') == 'https://mgoutside16-spec.github.io/larp/?game=' + game_id
    page.get_by_role('button', name='Опубликовать обновление', exact=True).click()
    expect(page.locator('#toast')).to_contain_text('Версия 2 опубликована')
    assert backend.player_releases[game_id]['version'] == 2
    backend.grant_membership(project_id)
    member = browser.new_context(viewport={'width': 390, 'height': 844})
    backend.install(member)
    member_page = member.new_page()
    member_page.goto(URL)
    backend.login(member_page, 'colleague@example.test')
    member_page.locator('[data-page=builds]').click()
    expect(member_page.get_by_role('heading', name='Сборки и версии', exact=True)).to_be_visible()
    expect(member_page.get_by_role('button', name='Опубликовать обновление', exact=True)).to_have_count(0)
    assert member_page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'), member_page.evaluate("[...document.querySelectorAll('main *')].filter(e=>e.getBoundingClientRect().right>innerWidth).map(e=>[e.tagName,e.className,e.getBoundingClientRect().right])")
    page.screenshot(path=str(ARTIFACTS / 'player-publication.png'), full_page=True)
    assert not errors, errors
    assert not backend.unhandled, backend.unhandled
    browser.close()
    print('PASS browser publication: missing migration, real immutable ZIP upload, versions, game link, member restriction')
