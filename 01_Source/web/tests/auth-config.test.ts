import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {validateBackendConfig,authMessage} from '../src/auth-config.ts';

test('only public connection keys can enter browser configuration',()=>{
  assert.equal(validateBackendConfig({supabaseUrl:'https://example.supabase.co/',supabasePublishableKey:'sb_publishable_public'}).supabaseUrl,'https://example.supabase.co');
  assert.throws(()=>validateBackendConfig({supabaseUrl:'https://example.supabase.co',supabasePublishableKey:'sb_secret_private'}),/публичный/);
  const serviceKey=`e30.${Buffer.from(JSON.stringify({role:'service_role'})).toString('base64url')}.signature`;
  assert.throws(()=>validateBackendConfig({supabaseUrl:'https://example.supabase.co',supabasePublishableKey:serviceKey}),/публичный/);
  assert.throws(()=>validateBackendConfig({supabaseUrl:'http://public.example',supabasePublishableKey:'sb_publishable_public'}),/HTTPS/);
});

test('authentication failures explain next action in Russian',()=>{
  assert.match(authMessage({message:'Email not confirmed'}),/подтверд/i);
  assert.match(authMessage({message:'Invalid login credentials'}),/почт.*парол/);
  assert.match(authMessage({message:'Email rate limit exceeded'}),/позже/);
});
