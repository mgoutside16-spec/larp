import 'fake-indexeddb/auto';
import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { Storage, allocateCode, stageMedia } from '../src/storage.ts';
import { deleteWorkshopProject, markPublished } from '../src/packages.ts';

async function storage() { return Storage.open(`test-${crypto.randomUUID()}`); }

test('code allocation is automatic, unique, five-digit and reserves deleted codes', async () => {
  const store = await storage();
  const game = await store.create('Остров Лафей', 'Описание');
  const first = await store.saveRecord(game.id, { title: 'Первая', location_id: null, blocks: [] });
  assert.match(first.code, /^[1-9][0-9]{4}$/);
  const codes = new Set([first.code]);
  for (let i = 0; i < 120; i++) {
    const row = await store.saveRecord(game.id, { title: `Запись ${i}`, location_id: null, blocks: [] });
    assert(!codes.has(row.code)); codes.add(row.code);
  }
  await store.deleteRecord(game.id, first.id);
  assert((await store.game(game.id)).reserved_codes.includes(first.code));
  store.close();
});

test('data and immutable codes survive closing and updating application connection', async () => {
  const name = `test-${crypto.randomUUID()}`;
  const store = await Storage.open(name);
  const game = await store.create('Игра на русском', 'Ёж');
  const row = await store.saveRecord(game.id, { title: 'Дневник', location_id: null, blocks: [{kind:'text', value:'<b>Текст</b>'}] });
  await store.saveRecord(game.id, { ...row, title: 'Изменена' });
  store.close();
  const upgradedApp = await Storage.open(name);
  const saved = await upgradedApp.game(game.id);
  assert.equal(saved.name, 'Игра на русском');
  assert.equal(saved.records[0].title, 'Изменена');
  assert.equal(saved.records[0].code, row.code);
  assert.equal(saved.records[0].blocks[0].value, '<b>Текст</b>');
  upgradedApp.close();
});

test('blocks and copied media persist, original file is no longer needed', async () => {
  const store = await storage(), game = await store.create('Медиа');
  const file = new File(['picture'], 'фото.png', {type:'image/png'});
  const asset = await stageMedia(file);
  const row = await store.saveRecord(game.id, { title:'Запись',location_id:null,blocks:[
    {kind:'image', value:asset.path}, {kind:'text', value:'После фото'}
  ]}, [asset]);
  const saved = await store.media(game.id,asset.path);
  assert.equal(await saved.blob.text(),'picture');
  assert.equal((await store.game(game.id)).records[0].blocks[1].value,'После фото');
  assert.match(row.code,/^[1-9][0-9]{4}$/);
  store.close();
});

test('invalid save rolls back metadata and media', async () => {
  const store = await storage(), game = await store.create('Игра');
  const row = await store.saveRecord(game.id,{title:'Оригинал',location_id:null,blocks:[]});
  await assert.rejects(store.saveRecord(game.id,{...row,title:'Потеря',blocks:[{kind:'image',value:'media/missing.png'}]}));
  assert.equal((await store.game(game.id)).records[0].title,'Оригинал');
  store.close();
});

test('parallel tabs cannot overwrite a newer edit', async () => {
  const store = await storage(), game = await store.create('Игра');
  const row = await store.saveRecord(game.id,{title:'Оригинал',location_id:null,blocks:[]});
  await store.saveRecord(game.id,{...row,title:'Первая правка'});
  await assert.rejects(store.saveRecord(game.id,{...row,title:'Устаревшая правка'}),/другой вкладке/);
  assert.equal((await store.game(game.id)).records[0].title,'Первая правка');
  store.close();
});

test('deleting a location preserves records; duplication is independent', async () => {
  const store=await storage(), game=await store.create('Игра');
  const loc=await store.addLocation(game.id,'Архив');
  const row=await store.saveRecord(game.id,{title:'Записка',location_id:loc,blocks:[]});
  await store.deleteLocation(game.id,loc);
  assert.equal((await store.game(game.id)).records[0].location_id,null);
  const copy=await store.copy(game.id);
  assert.notEqual(copy.packageId,game.packageId);
  assert.equal(copy.records[0].code,row.code);
  await store.deleteRecord(copy.id,row.id);
  assert.equal((await store.game(game.id)).records.length,1);
  store.close();
});

test('code exhaustion is explicit', () => {
  assert.throws(()=>allocateCode(Array.from({length:90000},(_,i)=>String(i+10000))),/исчерпан/);
});

test('deleting one project keeps the other project and its media after reopening', async () => {
  const name = `test-${crypto.randomUUID()}`;
  const store = await Storage.open(name);
  const removed = await store.create('Удалённая');
  const active = await store.create('Действующая');
  const asset = await stageMedia(new File(['picture'], 'image.png', {type:'image/png'}));
  for (const game of [removed, active]) {
    await store.saveRecord(game.id, {
      title: 'Запись', location_id: null, blocks: [{kind:'image', value:asset.path}],
    }, [asset]);
  }
  await store.deleteGame(removed.id);
  store.close();

  const reopened = await Storage.open(name);
  assert.deepEqual((await reopened.list()).map(game => game.id), [active.id]);
  assert.equal(await (await reopened.media(active.id, asset.path)).blob.text(), 'picture');
  await assert.rejects(() => reopened.media(removed.id, asset.path));
  reopened.close();
});

test('deleting an imported publication uses the public ID and preserves the local project on failure', async () => {
  const store = await storage();
  const imported = await store.create('Импортированная');
  const publicId = crypto.randomUUID();
  await store.update(imported.id, game => { game.packageId = publicId; });
  await markPublished(store, imported.id, 3, new Date().toISOString());

  const calls: string[] = [];
  let available = false;
  const publication = {connected: true, unpublish: async (id: string) => {
    calls.push(id);
    if (!available) throw new Error('GitHub недоступен');
    return true;
  }};
  await assert.rejects(deleteWorkshopProject(store, imported.id, publication), /GitHub/);
  assert.equal((await store.game(imported.id)).packageId, publicId);

  const copy = await store.create('Локальная копия');
  await store.update(copy.id, game => { game.packageId = publicId; });
  await markPublished(store, copy.id, 2, new Date().toISOString());
  await deleteWorkshopProject(store, copy.id, publication);
  assert.deepEqual(calls, [publicId]);
  available = true;
  await deleteWorkshopProject(store, imported.id, publication);
  assert.deepEqual(calls, [publicId, publicId]);
  assert.deepEqual(await store.list(), []);
  store.close();
});
