import 'fake-indexeddb/auto';
import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { strToU8, zipSync, unzipSync } from 'fflate';
import { Storage, stageMedia } from '../src/storage.ts';
import { makePackage, readPackage, importPackage } from '../src/packages.ts';

async function setup() {
  const store=await Storage.open(`test-${crypto.randomUUID()}`),game=await store.create('Русская игра');
  const media=await stageMedia(new File(['image'],'image.png',{type:'image/png'}));
  await store.saveRecord(game.id,{title:'Запись',location_id:null,blocks:[{kind:'text',value:'<p>Привет</p>'},{kind:'image',value:media.path}]},[media]);
  return {store,game:await store.game(game.id)};
}

test('versioned package roundtrip preserves game identity, codes, media and order', async()=>{
  const {store,game}=await setup();
  const bytes=await makePackage(store,game.id);
  const parsed=await readPackage(bytes);
  assert.equal(parsed.manifest.game.name,'Русская игра');
  assert.equal(parsed.manifest.version,1);
  const copy=await importPackage(store,bytes);
  assert.notEqual(copy.id,game.id);
  assert.equal(copy.packageId,game.packageId);
  assert.equal(copy.records[0].code,game.records[0].code);
  assert.equal(await (await store.media(copy.id,copy.records[0].blocks[1].value)).blob.text(),'image');
  assert.equal(copy.records[0].blocks[0].value,'<p>Привет</p>');
  assert.equal((await store.game(game.id)).version,1);
  store.close();
});

test('tampered media is rejected without adding a project',async()=>{
  const {store,game}=await setup(),bytes=await makePackage(store,game.id);
  const files=unzipSync(bytes),name=Object.keys(files).find(n=>n.startsWith('media/'))!;
  files[name]=strToU8('tampered');
  await assert.rejects(importPackage(store,zipSync(files)),/сумм/);
  assert.equal((await store.list()).length,1);
  store.close();
});

test('unsafe Windows paths and duplicate case aliases are rejected',async()=>{
  const {store,game}=await setup(),bytes=await makePackage(store,game.id);
  for (const name of ['../escape','media/CON.png','media/a:stream','media/photo.']) {
    const files=unzipSync(bytes);files[name]=strToU8('evil');
    await assert.rejects(readPackage(zipSync(files)));
  }
  const files=unzipSync(bytes); files['media/A.png']=strToU8('a');files['media/a.png']=strToU8('b');
  await assert.rejects(readPackage(zipSync(files)),/имена/);
  store.close();
});

test('truncated and unsupported packages fail clearly',async()=>{
  await assert.rejects(readPackage(strToU8('not zip')));
  await assert.rejects(readPackage(zipSync({'manifest.json':strToU8('{')})));
});

test('oversized manifest export fails without recording a successful backup',async()=>{
  const store=await Storage.open(`test-${crypto.randomUUID()}`),game=await store.create('Большая игра');
  await store.saveRecord(game.id,{title:'Длинный текст',location_id:null,blocks:[{kind:'text',value:'x'.repeat(16*1024**2)}]});
  await assert.rejects(makePackage(store,game.id),/описание|Описание|16 МиБ/);
  const saved=await store.game(game.id);
  assert.equal(saved.version,0);assert.equal(saved.builds.length,0);
  store.close();
});
