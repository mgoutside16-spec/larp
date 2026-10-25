import 'fake-indexeddb/auto';
import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {createClient} from '@supabase/supabase-js';
import {CloudStorage} from '../src/cloud-storage.ts';
import type {Game} from '../src/types';

for(const stale of [false,true])test(stale?'stale project deletion never removes media':'project deletion cleans referenced and unused media only after server success',async()=>{
  const id=crypto.randomUUID(),owner=crypto.randomUUID();let deleted=false;const removed:string[]=[];
  const document:Game={id,packageId:id,name:'Игра',description:'',version:0,created:'2026-10-25T00:00:00Z',modified:'2026-10-25T00:00:00Z',records:[],locations:[],reserved_codes:[],builds:[]};
  const api=async(input:RequestInfo|URL,init?:RequestInit)=>{
    const url=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url),body=init?.body?JSON.parse(String(init.body)):{};
    const result=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json'}});
    if(url.pathname.endsWith('/workshop_projects'))return result([{id,owner_id:owner,revision:1,status:'active',document}]);
    if(url.pathname.includes('/object/list/')){assert.equal(body.prefix,`${id}/media`);return result([{id:'one',name:'one.png'},{id:'unused',name:'unused.png'}]);}
    if(url.pathname.endsWith('/rpc/delete_workshop_project')){
      assert.equal(body.p_expected_revision,1);
      if(stale)return result({code:'40001',message:'concurrent change'},409);
      deleted=true;return result(null);
    }
    if(init?.method==='DELETE'&&url.pathname.endsWith('/object/workshop-media')){
      assert(deleted,'Files must not be deleted before the CAS succeeds');removed.push(...body.prefixes);return result([]);
    }
    throw new Error('Unexpected storage operation '+url.pathname);
  };
  const client=createClient('https://test.supabase.co','sb_publishable_test',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:api}});
  const store=await CloudStorage.open(client,owner);
  if(stale){await assert.rejects(store.deleteGame(id),/измен/);assert.deepEqual(removed,[]);assert.equal(deleted,false);}
  else{await store.deleteGame(id);assert.deepEqual(removed,[`${id}/media/one.png`,`${id}/media/unused.png`]);}
  store.close();
});
