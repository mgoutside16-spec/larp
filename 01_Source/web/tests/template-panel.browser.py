"""Dedicated real Chromium checks. Run against Vite: LARP_TEMPLATE_URL=http://127.0.0.1:5174 python tests/template-panel.browser.py."""
import os
from pathlib import Path
import struct
import zipfile
from playwright.sync_api import sync_playwright, expect

url = os.environ.get('LARP_TEMPLATE_URL', 'http://127.0.0.1:5174')
artifacts = Path('/tmp/larp-template-panel-checks')
artifacts.mkdir(exist_ok=True)
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width':1280,'height':1000}, accept_downloads=True)
    errors=[]
    page.on('pageerror',lambda error: errors.append(str(error)))
    page.goto(url)
    page.wait_for_load_state('networkidle')
    codes=page.evaluate('''async()=>{
      const {Storage}=await import('/src/storage.ts');
      const {mountTemplatePanel}=await import('/src/template-panel.ts');
      await import('/src/template-panel.css');
      const store=await Storage.open('template-browser-'+crypto.randomUUID());
      const game=await store.create('Проверка шаблонов');
      const a=await store.addGroup(game.id,'Группа A');await store.addGroup(game.id,'Пустая группа');
      const one=await store.saveRecord(game.id,{title:'В группе',location_id:a,blocks:[]});
      const two=await store.saveRecord(game.id,{title:'Без группы',location_id:null,blocks:[]});
      document.body.innerHTML='<main id="panel" style="max-width:1100px;margin:20px auto;padding:16px"></main>';
      window.disposeTemplatePanel=await mountTemplatePanel(document.querySelector('#panel'),store,game.id);
      window.testStore=store;window.testGame=game.id;
      return [one.code,two.code];
    }''')
    expect(page.locator('.tpl-export')).to_be_disabled()
    page.get_by_role('button',name='Пример «Сновидение»').click()
    expect(page.locator('.tpl-canvas')).to_be_visible()
    expect(page.locator('.tpl-export')).to_be_enabled()
    assert page.locator('.tpl-canvas').evaluate('(c)=>[c.width,c.height]') == [761,916]
    page.locator('.tpl-save').click()
    expect(page.locator('.tpl-status')).to_have_text('Шаблон группы сохранён.')
    page.locator('.tpl-scope').select_option('1')
    expect(page.locator('.tpl-status')).to_contain_text('общий шаблон')
    expect(page.locator('.tpl-summary')).to_contain_text('Записей для печати: 1')
    rect=page.locator('.tpl-canvas').bounding_box()
    page.mouse.move(rect['x']+rect['width']*.52,rect['y']+rect['height']*.196)
    page.mouse.down();page.mouse.move(rect['x']+rect['width']*.4,rect['y']+rect['height']*.3);page.mouse.up()
    page.locator('.tpl-size').fill('42')
    page.locator('.tpl-color').fill('#b51218')
    page.locator('.tpl-font').select_option('serif')
    page.locator('.tpl-canvas').press('ArrowRight')
    page.once('dialog',lambda dialog:dialog.dismiss())
    page.locator('.tpl-scope').select_option('none')
    expect(page.locator('.tpl-scope')).to_have_value('1')
    with page.expect_download() as download:
        page.locator('.tpl-export').click()
    target=artifacts/'group.zip';download.value.save_as(target)
    with zipfile.ZipFile(target) as archive:
        assert archive.namelist()==[codes[0]+'.png'],archive.namelist()
        png=archive.read(codes[0]+'.png')
        assert struct.unpack('>II',png[16:24])==(761,916)
        offset=png.index(b'pHYs')+4
        assert struct.unpack('>IIB',png[offset:offset+9])==(11811,11811,1)
        (artifacts/'card.png').write_bytes(png)
    page.locator('.tpl-save').click()
    expect(page.locator('.tpl-status')).to_have_text('Шаблон группы сохранён.')
    saved=page.evaluate('async()=>((await testStore.game(testGame)).printTemplates["1"])')
    assert abs(saved['x']-(.4+1/761))<.002,saved
    assert abs(saved['y']-.3)<.002,saved
    assert saved['font']=='serif' and saved['color']=='#b51218' and round(saved['fontSize']*916)==42,saved
    page.locator('.tpl-scope').select_option('2')
    expect(page.locator('.tpl-export')).to_be_enabled()
    page.locator('.tpl-export').click()
    expect(page.locator('.tpl-status')).to_contain_text('нет записей')
    page.locator('.tpl-scope').select_option('none')
    expect(page.locator('.tpl-export')).to_be_enabled()
    with page.expect_download() as download:
        page.locator('.tpl-export').click()
    target=artifacts/'ungrouped.zip';download.value.save_as(target)
    with zipfile.ZipFile(target) as archive: assert archive.namelist()==[codes[1]+'.png']
    page.screenshot(path=str(artifacts/'desktop.png'),full_page=True)
    page.set_viewport_size({'width':390,'height':844})
    assert page.evaluate('document.documentElement.scrollWidth<=innerWidth'),'Horizontal overflow on mobile'
    page.screenshot(path=str(artifacts/'mobile.png'),full_page=True)
    page.evaluate('disposeTemplatePanel()')
    assert errors==[],errors
    print('PASS: image example, canvas dimensions, drag and keyboard coordinates, styles, unsaved-switch cancel, save, group/fallback/empty, real ZIP/PNG 300dpi, mobile width, disposal, no browser errors')
    browser.close()
