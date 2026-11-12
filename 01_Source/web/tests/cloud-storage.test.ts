import 'fake-indexeddb/auto';
import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {createClient} from '@supabase/supabase-js';
import {CloudStorage} from '../src/cloud-storage.ts';
import {Storage,stageMedia} from '../src/storage.ts';
import type {Game} from '../src/types';

async function fixture(changeTarget=false,injectConflict=true){
  const id=crypto.randomUUID(),user=crypto.randomUUID();
  const game:Game={id,packageId:id,name:'Совместная игра',description:'',created:'2026-10-25T00:00:00Z',modified:'2026-10-25T00:00:00Z',version:0,locations:[],reserved_codes:['12345','23456'],builds:[],records:[
    {id:crypto.randomUUID(),code:'12345',title:'Запись А',location_id:null,modified:'2026-10-25T00:00:00Z',blocks:[],revision:1},
    {id:crypto.randomUUID(),code:'23456',title:'Запись Б',location_id:null,modified:'2026-10-25T00:00:00Z',blocks:[],revision:1},
  ]};
  let row={id,owner_id:user,revision:1,document:game,status:'active'},conflict=injectConflict;
  const media=new Map<string,Blob>();let mediaDownloads=0;
  const api=async(input:RequestInfo|URL,init?:RequestInit)=>{
    const url=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url);
    if(url.pathname.startsWith('/storage/v1/object/workshop-media/')){
      if(init?.method==='POST'){
        const blob=(init.body as FormData).get('') as Blob;media.set(url.pathname,blob);
        return Response.json({Id:crypto.randomUUID(),Key:url.pathname});
      }
      mediaDownloads++;return new Response(media.get(url.pathname));
    }
    if(url.pathname.endsWith('/rpc/save_workshop_project')){
      const body=JSON.parse(String(init?.body));
      if(conflict){conflict=false;row.revision++;const target=row.document.records[changeTarget?0:1];target.title='Правка коллеги';target.revision++;
        return new Response(JSON.stringify({code:'40001',message:'concurrent edit'}),{status:409,headers:{'content-type':'application/json'}});}
      assert.equal(body.p_expected_revision,row.revision);
      row={...row,revision:row.revision+1,document:body.p_document};
      return new Response(JSON.stringify(row),{headers:{'content-type':'application/json'}});
    }
    if(url.pathname.endsWith('/workshop_projects'))return new Response(JSON.stringify([row]),{headers:{'content-type':'application/json'}});
    throw new Error('Unexpected real adapter request: '+url.pathname);
  };
  const client=createClient('https://test.supabase.co','sb_publishable_test',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:api}});
  const store=await CloudStorage.open(client,user);
  return {store,game,getRow:()=>row,client,user,mediaDownloads:()=>mediaDownloads};
}

test('parallel edits of different records merge after a server revision conflict',async()=>{
  const {store,game,getRow}=await fixture();
  await store.saveRecord(game.id,{...game.records[0],title:'Моя правка А'});
  assert.equal(getRow().document.records[0].title,'Моя правка А');
  assert.equal(getRow().document.records[1].title,'Правка коллеги');
  assert.equal(getRow().document.records[0].code,'12345');
  store.close();
});

test('parallel edit of the same record is rejected instead of losing a colleague edit',async()=>{
  const {store,game,getRow}=await fixture(true);
  await assert.rejects(store.saveRecord(game.id,{...game.records[0],title:'Устаревшая правка'}),/другой вкладке/);
  assert.equal(getRow().document.records[0].title,'Правка коллеги');
  store.close();
  await assert.rejects(store.list(),/Сеанс завершён/);
});

test('a concurrent cache refresh cannot turn a successful save into a lost edit',async()=>{
  const {store,game,getRow,client,user}=await fixture(false,false);
  const otherTab=await CloudStorage.open(client,user),save=Storage.prototype.saveRecord;
  Storage.prototype.saveRecord=async function(...args){
    const saved=await save.apply(this,args);
    // Real other-tab read at the precise proposal/read boundary found in review.
    await otherTab.game(game.id);
    return saved;
  };
  try{
    const result=await store.saveRecord(game.id,{...game.records[0],title:'Сохранённая правка'});
    assert.equal(result.title,'Сохранённая правка');
    assert.equal(getRow().document.records[0].title,'Сохранённая правка');
  }finally{Storage.prototype.saveRecord=save;store.close();otherTab.close();}
});


test('saving uploaded media caches its actual bytes without downloading them again on reopen',async()=>{
  const f=await fixture(false,false);
  try{
    const file=new File([new Uint8Array(1024*1024).fill(42)],'video.mp4',{type:'video/mp4'});
    const asset=await stageMedia(file);
    const saved=await f.store.saveRecord(f.game.id,{title:'Видео',location_id:null,blocks:[{kind:'video',value:asset.path}]},[asset]);
    const reopened=await f.store.media(f.game.id,saved.blocks[0].value);
    assert.deepEqual(new Uint8Array(await reopened.blob.arrayBuffer()),new Uint8Array(await file.arrayBuffer()));
    assert.equal(f.mediaDownloads(),0,'file already uploaded in this editor should stay cached');
  }finally{f.store.close();}
});
