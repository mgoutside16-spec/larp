import 'fake-indexeddb/auto';
import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {createClient} from '@supabase/supabase-js';
import {CloudStorage} from '../src/cloud-storage.ts';
import {Storage} from '../src/storage.ts';
import {makePackage,readPackage} from '../src/packages.ts';

async function fixture(version:unknown=17,errorCode?:string){
  const local=await Storage.open(`auto-${crypto.randomUUID()}`),game=await local.create('Автоматическая игра');
  let document=game,revision=1;
  const participant={participant_id:crypto.randomUUID(),character_name:'<Смотритель>',first_seen:'2026-10-25T00:00:00Z',last_seen:'2026-10-25T01:00:00Z'};
  const client=createClient('https://test.supabase.co','sb_publishable_test',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:async(input,init)=>{
    const path=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url).pathname;
    const body=JSON.parse(String(init?.body||'{}'));
    const ok=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});
    if(path.endsWith('/workshop_projects'))return ok([{id:game.id,owner_id:'owner',status:'active',revision,document}]);
    assert.equal(body.p_project_id||body.p_document?.id,game.id);
    if(errorCode)return ok({code:errorCode,message:'backend failure'},errorCode==='PGRST202'?404:403);
    if(path.endsWith('/get_player_source_version'))return ok(version);
    if(path.endsWith('/list_game_players'))return ok([{...participant,token:'secret never rendered'}]);
    if(path.endsWith('/save_workshop_project')){assert.equal(body.p_expected_revision,revision);revision++;document=body.p_document;return ok({id:game.id,owner_id:'owner',status:'active',revision,document});}
    throw new Error('Unexpected request: '+path);
  }}});
  const store=await CloudStorage.open(client,crypto.randomUUID());local.close();
  return {store,game,participant};
}

test('local player version follows the portable document version',async()=>{
  const store=await Storage.open(`auto-${crypto.randomUUID()}`),game=await store.create('Локальная игра');
  try{await makePackage(store,game.id);assert.equal(await store.playerVersion(game.id),1);}finally{store.close();}
});

test('portable cloud package advances beyond automatic player versions',async()=>{
  const {store,game}=await fixture(17);
  try{const {manifest}=await readPackage(await makePackage(store,game.id));assert.equal(manifest.version,18);assert.equal((await store.game(game.id)).version,18);}finally{store.close();}
});

test('portable cloud package also advances a newer document version',async()=>{
  const {store,game}=await fixture(2);
  try{await store.update(game.id,g=>{g.version=7;});const {manifest}=await readPackage(await makePackage(store,game.id));assert.equal(manifest.version,8);}finally{store.close();}
});

test('missing automatic sync migration preserves existing cloud export',async()=>{
  const {store,game}=await fixture(undefined,'PGRST202');
  try{assert.equal(await store.playerVersion(game.id),0);}finally{store.close();}
});

for(const value of [-1,1.5,'17',null,Number.MAX_SAFE_INTEGER+1])test(`invalid player version ${value} fails before recording an export`,async()=>{
  const {store,game}=await fixture(value);
  try{await assert.rejects(makePackage(store,game.id),/верси/);assert.equal((await store.game(game.id)).builds.length,0);}finally{store.close();}
});

test('player list contains public character fields and no registration token',async()=>{
  const {store,game,participant}=await fixture();
  try{assert.deepEqual(await store.players(game.id),[participant]);}finally{store.close();}
});

test('denied player list and version request never use cached private data',async()=>{
  const {store,game}=await fixture(undefined,'42501');
  try{await assert.rejects(store.players(game.id),/нет доступа/);await assert.rejects(store.playerVersion(game.id),/нет доступа/);}finally{store.close();}
});

test('export still rejects a concurrent edit during player version lookup',async()=>{
  const store=await Storage.open(`auto-${crypto.randomUUID()}`),game=await store.create('Конкурентная игра');
  await store.cacheSnapshot({...game,modified:'2020-01-01T00:00:00Z'});
  store.playerVersion=async()=>{await store.rename(game.id,'Правка коллеги','');return 9;};
  try{await assert.rejects(makePackage(store,game.id),/изменился/);assert.equal((await store.game(game.id)).builds.length,0);}finally{store.close();}
});
