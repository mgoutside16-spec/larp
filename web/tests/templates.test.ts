import 'fake-indexeddb/auto';
import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { Storage, stageMedia } from '../src/storage.ts';
import { validateTemplate, canvasPosition, pngWithDpi } from '../src/print-layout.ts';

const config={imagePath:'media/example.png',width:800,height:1200,x:.5,y:.2,fontSize:.05,color:'#000000',font:'sans' as const,bold:true};

test('groups are project-specific; legacy groups and assigned codes survive updates',async()=>{
  const store=await Storage.open(`groups-${crypto.randomUUID()}`);
  const first=await store.create('Первая'),second=await store.create('Вторая');
  const legacy=await store.addLocation(first.id,'Старое имя');
  const row=await store.saveRecord(first.id,{title:'Видение',location_id:legacy,blocks:[]});
  await store.renameGroup(first.id,legacy,'Сны');
  assert.equal((await store.game(first.id)).locations[0].name,'Сны');
  assert.equal((await store.game(first.id)).records[0].code,row.code);
  await store.addGroup(second.id,'ЭП');
  assert.equal((await store.game(first.id)).locations.length,1);
  assert.equal((await store.game(second.id)).locations[0].name,'ЭП');
  await store.deleteGroup(first.id,legacy);
  assert.equal((await store.game(first.id)).records[0].location_id,null);
  store.close();
});

test('template and source image survive reopening and independent project copy',async()=>{
  const name=`templates-${crypto.randomUUID()}`,store=await Storage.open(name),game=await store.create('Шаблон');
  const asset=await stageMedia(new File(['template'],'Карта.png',{type:'image/png'}));
  await store.savePrintTemplate(game.id,'all',{...config,imagePath:asset.path},asset);
  store.close();
  const reopened=await Storage.open(name),saved=await reopened.game(game.id);
  assert.equal(saved.printTemplates?.all.x,.5);
  assert.equal(await (await reopened.media(game.id,asset.path)).blob.text(),'template');
  const copy=await reopened.copy(game.id);
  assert.equal(copy.printTemplates?.all.imagePath,asset.path);
  await reopened.savePrintTemplate(copy.id,'all',{...config,imagePath:asset.path,x:.8});
  assert.equal((await reopened.game(game.id)).printTemplates?.all.x,.5);
  reopened.close();
});

test('invalid template cannot replace the saved template',async()=>{
  const store=await Storage.open(`templates-${crypto.randomUUID()}`),game=await store.create('Игра');
  const asset=await stageMedia(new File(['template'],'image.png',{type:'image/png'}));
  await store.savePrintTemplate(game.id,'all',{...config,imagePath:asset.path},asset);
  await assert.rejects(store.savePrintTemplate(game.id,'all',{...config,imagePath:asset.path,x:10}));
  assert.equal((await store.game(game.id)).printTemplates?.all.x,.5);
  assert.throws(()=>validateTemplate({...config,imagePath:'../outside.png'}));
  store.close();
});

test('drag coordinates use actual canvas bounds and clamp to the image',()=>{
  assert.deepEqual(canvasPosition(150,75,{left:50,top:25,width:200,height:100}),{x:.5,y:.5});
  assert.deepEqual(canvasPosition(-10,1000,{left:50,top:25,width:200,height:100}),{x:0,y:1});
});

test('PNG print metadata is 300 DPI, preserving original image data',()=>{
  const input=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8b8AAAAASUVORK5CYII=','base64');
  const output=pngWithDpi(input,300),view=new DataView(output.buffer,output.byteOffset,output.byteLength);
  let offset=8,phys=false,idat:Uint8Array|undefined;
  while(offset<output.length){const len=view.getUint32(offset);const kind=new TextDecoder().decode(output.subarray(offset+4,offset+8));
    if(kind==='pHYs'){assert.equal(view.getUint32(offset+8),11811);assert.equal(view.getUint32(offset+12),11811);assert.equal(output[offset+16],1);phys=true;}
    if(kind==='IDAT')idat=output.subarray(offset+8,offset+8+len);
    offset+=len+12;
  }
  assert(phys);assert(idat);assert.equal(Buffer.from(idat).toString('hex'),'78da63fcff1f0003030200');
});
