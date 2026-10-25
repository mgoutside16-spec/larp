import 'fake-indexeddb/auto';
import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {createClient} from '@supabase/supabase-js';
import {CloudStorage} from '../src/cloud-storage.ts';
import {readPackage} from '../src/packages.ts';
import {sha256,type Game} from '../src/types.ts';

async function fixture(failure?:'migration'|'conflict'|'upload'|'changed',badField?:string,uppercaseIdentity=false){
  const id=crypto.randomUUID(),packageId=uppercaseIdentity?crypto.randomUUID().toUpperCase():crypto.randomUUID(),user=crypto.randomUUID();
  const game:Game={id,packageId,name:'Онлайн игра',description:'',created:'2026-10-25T00:00:00Z',modified:'2026-10-25T00:00:00Z',version:0,locations:[],records:[],reserved_codes:[],builds:[]};
  let row={id,owner_id:user,revision:7,document:game,status:'active'},archive:Uint8Array|undefined,published:any;
  const api=async(input:RequestInfo|URL,init?:RequestInit)=>{
    const url=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url);
    const ok=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json'}});
    if(url.pathname.endsWith('/workshop_projects'))return ok([row]);
    if(url.pathname.endsWith('/rpc/get_player_release'))return ok(null);
    if(url.pathname.endsWith('/rpc/save_workshop_project')){
      const body=JSON.parse(String(init?.body));assert.equal(body.p_expected_revision,7);
      row={...row,document:body.p_document,revision:8};return ok(row);
    }
    if(url.pathname.startsWith('/storage/v1/object/player-releases/')){
      if(failure==='upload')return ok({message:'Network unavailable',statusCode:'503'},503);
      const body=init?.body as Blob|FormData;
      const blob=body instanceof FormData?[...body.values()].find(v=>typeof v!=='string') as Blob:body;
      archive=new Uint8Array(await blob.arrayBuffer());
      const digest=await sha256(archive);
      assert.equal(url.pathname,`/storage/v1/object/player-releases/${id}/1/${digest}.rpgpack`);
      assert.equal(new Headers(init?.headers).get('x-upsert'),'false');
      if(failure==='changed'){row.revision++;row.document.name='Параллельная правка';}
      return ok({Key:`player-releases/${id}/1/${digest}.rpgpack`});
    }
    if(url.pathname.endsWith('/rpc/publish_player_release')){
      if(failure==='migration')return ok({code:'PGRST202',message:'function not found'},404);
      if(failure==='conflict'||failure==='changed')return ok({code:'40001',message:'stale revision'},409);
      const body=JSON.parse(String(init?.body));
      assert.ok(archive);assert.equal(body.p_size,archive.length);assert.equal(body.p_expected_revision,8);
      const {manifest}=await readPackage(archive);
      assert.equal(manifest.game.id,packageId);assert.equal(manifest.version,1);
      assert.deepEqual(body,{p_project_id:id,p_expected_revision:8,p_version:1,p_path:`${id}/1/${await sha256(archive)}.rpgpack`,p_sha256:await sha256(archive),p_size:archive.length});
      published={game_id:packageId.toLowerCase(),name:manifest.game.name,version:1,sha256:body.p_sha256,size:archive.length,download_path:body.p_path,created_at:'2026-10-25T00:00:00Z'};
      if(badField)published[badField]=badField==='size'?123:'incorrect';
      return ok(published);
    }
    throw new Error('Unexpected real SDK request '+url.pathname);
  };
  const client=createClient('https://test.supabase.co','sb_publishable_test',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:api}});
  const store=await CloudStorage.open(client,user);
  return {store,id,packageId,getRow:()=>row,getPublished:()=>published};
}

for(const field of ['game_id','name','version','sha256','size','download_path','created_at']){
  test(`publication rejects a response with invalid ${field}`,async()=>{
    const {publishPlayerUpdate}=await import('../src/player-publication.ts');
    const f=await fixture(undefined,field);
    try{await assert.rejects(publishPlayerUpdate(f.store,f.id),/некорректную публикацию/);}
    finally{f.store.close();}
  });
}

test('publication uploads a real versioned archive and shares package UUID, not workshop project UUID',async()=>{
  const {publishPlayerUpdate,playerGameLink}=await import('../src/player-publication.ts');
  const f=await fixture();
  try{
    const release=await publishPlayerUpdate(f.store,f.id);
    assert.deepEqual(release,f.getPublished());assert.equal(f.getRow().document.version,1);
    assert.equal(playerGameLink(release.game_id),`https://mgoutside16-spec.github.io/larp/?game=${f.packageId}`);
  }finally{f.store.close();}
});

test('imported uppercase package UUID remains the same published game identity',async()=>{
  const {publishPlayerUpdate,playerGameLink}=await import('../src/player-publication.ts');
  const f=await fixture(undefined,undefined,true);
  try{
    const release=await publishPlayerUpdate(f.store,f.id);
    assert.equal(release.game_id,f.packageId.toLowerCase());
    assert.equal(playerGameLink(f.packageId),`https://mgoutside16-spec.github.io/larp/?game=${f.packageId.toLowerCase()}`);
  }finally{f.store.close();}
});

for(const [failure,message] of [['migration',/player-updates\.sql/],['conflict',/изменился/],['upload',/связи/],['changed',/изменился/]] as const){
  test(`publication reports ${failure} in Russian and does not claim success`,async()=>{
    const {publishPlayerUpdate}=await import('../src/player-publication.ts');
    const f=await fixture(failure);
    try{await assert.rejects(publishPlayerUpdate(f.store,f.id),message);assert.equal(f.getPublished(),undefined);}
    finally{f.store.close();}
  });
}
