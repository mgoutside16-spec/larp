-- PostgreSQL 17 integration tests. Run after test-bootstrap.sql and schema.sql.
-- All synthetic accounts, projects, roles and storage rows roll back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_ok(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end $$;
create function pg_temp.expect_error(statement text,expected_state text,label text) returns void language plpgsql as $$
declare actual text;
begin
 begin execute statement; exception when others then get stacked diagnostics actual=returned_sqlstate;end;
 if actual is distinct from expected_state then raise exception 'FAIL %: wanted %, got %',label,expected_state,coalesce(actual,'SUCCESS');end if;
 raise notice 'PASS %',label;
end $$;
create function pg_temp.doc(project_id uuid default 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') returns jsonb language sql as $$
 select jsonb_build_object('id',project_id,'packageId','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 'name','Первая игра','description','','created','2026-10-25T00:00:00Z','modified','2026-10-25T00:00:00Z',
 'version',0,'locations',jsonb_build_array(jsonb_build_object('id',1,'name','Сны')),
 'records','[{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","code":"12345","title":"Сон","location_id":1,"modified":"2026-10-25T00:00:00Z","revision":1,"blocks":[{"kind":"text","value":"Привет"}]}]'::jsonb,
 'reserved_codes','["12345"]'::jsonb,'builds','[]'::jsonb);
$$;
insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
 ('11111111-1111-4111-8111-111111111111','owner@example.com',now(),'{"role":"admin","is_admin":true,"email":"mgoutside16@gmail.com","email_verified":true}'),
 ('22222222-2222-4222-8222-222222222222','member@example.com',now(),'{}'),
 ('33333333-3333-4333-8333-333333333333','outsider@example.com',now(),'{}'),
 ('44444444-4444-4444-8444-444444444444','admin@example.com',now(),'{}'),
 ('55555555-5555-4555-8555-555555555555','invited@example.com',null,'{"email":"owner@example.com","email_verified":true}');
select pg_temp.assert_ok((select count(*)=5 from public.workshop_profiles),'signup trigger creates all master profiles');
select pg_temp.assert_ok((select count(*)=0 from public.workshop_admins),'signup metadata cannot create administrator');
insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
 ('66666666-6666-4666-8666-666666666666','mgoutside16@gmail.com',null,'{"email_verified":true,"is_admin":true}');
select pg_temp.assert_ok((select count(*)=0 from public.workshop_admins),'authorized bootstrap email still requires real verification');
update auth.users set email_confirmed_at=now() where id='66666666-6666-4666-8666-666666666666';
select pg_temp.assert_ok(exists(select 1 from public.workshop_admins where user_id='66666666-6666-4666-8666-666666666666'),'authorized verified email becomes initial admin');
select pg_temp.assert_ok((select count(*)=0 from public.workshop_admin_bootstrap),'initial admin authorization consumed once');
delete from auth.users where id='66666666-6666-4666-8666-666666666666';
insert into auth.users(id,email,email_confirmed_at) values
 ('66666666-6666-4666-8666-666666666666','mgoutside16@gmail.com',now());
select pg_temp.assert_ok((select count(*)=0 from public.workshop_admins),'consumed authorization cannot automatically grant admin again');
delete from auth.users where id='66666666-6666-4666-8666-666666666666';
insert into public.workshop_admins(user_id) values('44444444-4444-4444-8444-444444444444');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select pg_temp.assert_ok(public.get_workshop_identity()->>'is_admin'='false','owner identity is master');
select pg_temp.assert_ok(public.set_workshop_display_name('  Антон  ')->>'display_name'='Антон','display name saved and trimmed');
select pg_temp.expect_error($q$select public.set_workshop_display_name(null)$q$,'23514','null display name rejected');
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc(),0)).revision=1,'owner creates project');
select pg_temp.assert_ok((select count(*)=1 from public.workshop_projects),'owner reads own project');
insert into storage.objects(bucket_id,name) values('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/file.png');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name) values('workshop-media','11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/old.png')$q$,'42501','legacy owner-prefixed path rejected');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name) values('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/../evil.png')$q$,'42501','nested media traversal rejected');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name) values('workshop-media','zzzzzzzz-zzzz-4zzz-8zzz-zzzzzzzzzzzz/media/file.png')$q$,'42501','invalid media project identifier rejected');
select pg_temp.expect_error($q$select public.validate_workshop_document(pg_temp.doc(),null)$q$,'42501','internal validation helper private');
select pg_temp.expect_error($q$select * from public.workshop_admin_bootstrap$q$,'42501','bootstrap authorization table private');
select pg_temp.expect_error($q$select * from public.workshop_record_history$q$,'42501','record tombstone table private');
select pg_temp.expect_error($q$update public.workshop_projects set owner_id='22222222-2222-4222-8222-222222222222'$q$,'42501','direct project writes denied');
select pg_temp.expect_error($q$insert into public.workshop_admins values('11111111-1111-4111-8111-111111111111')$q$,'42501','direct administrator escalation denied');
select pg_temp.expect_error($q$update public.workshop_profiles set email='admin@example.com'$q$,'42501','direct email spoof denied');
select pg_temp.expect_error($q$select public.set_workshop_admin('11111111-1111-4111-8111-111111111111',true)$q$,'42501','administrator RPC escalation denied');
select pg_temp.expect_error($q$select * from public.list_workshop_users()$q$,'42501','masters cannot enumerate accounts');
select pg_temp.expect_error($q$select public.save_workshop_project(pg_temp.doc(),0)$q$,'40001','stale document revision rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(pg_temp.doc(),null)$q$,'23514','null revision rejected');
select pg_temp.expect_error($q$select public.delete_workshop_project('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null)$q$,'40001','null delete revision rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(jsonb_set(pg_temp.doc(),'{reserved_codes}','["12345","99999"]'),'{records,0,code}','"99999"'),1)$q$,'23514','existing record code immutable');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(jsonb_set(pg_temp.doc(),'{records}','[]'),'{reserved_codes}','[]'),1)$q$,'23514','reserved code history cannot shrink');
-- Validate missing and JSON-null cases: SQL NULL must never turn an invalid predicate into acceptance.
do $$ declare field text;bad jsonb;begin
 foreach field in array array['packageId','name','description','created','modified','version','locations','records','reserved_codes','builds'] loop
  perform pg_temp.expect_error(format('select public.save_workshop_project(%L::jsonb,1)',pg_temp.doc()-field),'23514','missing document '||field);
  bad:=jsonb_set(pg_temp.doc(),array[field],'null');
  perform pg_temp.expect_error(format('select public.save_workshop_project(%L::jsonb,1)',bad),'23514','null document '||field);
 end loop;
 foreach field in array array['id','code','title','location_id','modified','revision','blocks'] loop
  bad:=jsonb_set(pg_temp.doc(),'{records,0}',(pg_temp.doc()#>'{records,0}')-field);
  perform pg_temp.expect_error(format('select public.save_workshop_project(%L::jsonb,1)',bad),'23514','missing record '||field);
  if field<>'location_id' then
   bad:=jsonb_set(pg_temp.doc(),array['records','0',field],'null');
   perform pg_temp.expect_error(format('select public.save_workshop_project(%L::jsonb,1)',bad),'23514','null record '||field);
  end if;
 end loop;
end $$;
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{reserved_codes}','[12345]'),1)$q$,'23514','numeric reserved code rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{records,0,blocks}','[{"kind":"text","value":null}]'),1)$q$,'23514','null block value rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{records,0,location_id}','2'),1)$q$,'23514','unknown group rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{records,0,blocks}','[{"kind":"image","value":"../secret"}]'),1)$q$,'23514','unsafe media path rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{builds}','[null]'),1)$q$,'23514','null build rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{printTemplates}','null'),1)$q$,'23514','null print settings rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{created}','"infinity"'),1)$q$,'23514','infinite timestamp rejected');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{records,0,blocks}','[{"kind":"text","value":"a","extra":true}]'),1)$q$,'23514','extra block fields rejected');
select pg_temp.assert_ok(public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','  MEMBER@EXAMPLE.COM  ')->>'status'='added','owner adds verified member by normalized email');
select pg_temp.assert_ok(public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','member@example.com')->>'status'='added','adding member is idempotent');
select pg_temp.assert_ok((select count(*)=2 from public.list_workshop_members('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')),'member list includes owner exactly once');
select pg_temp.assert_ok((select count(*)=2 from public.workshop_profiles),'owner sees only own and shared profile');
select pg_temp.assert_ok(public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','invited@example.com')->>'status'='invited','unverified email receives pending invitation');
select pg_temp.expect_error($q$select public.remove_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111')$q$,'23514','owner cannot be removed');
select pg_temp.expect_error($q$select public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null)$q$,'23514','null invite rejected');
-- Import staging is hidden from project listing, but owner can upload before activation.
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc('dddddddd-dddd-4ddd-8ddd-dddddddddddd'),0,false)).status='importing','import creates stage');
select pg_temp.assert_ok((select count(*)=1 from public.workshop_projects),'staging project hidden from listing');
insert into storage.objects(bucket_id,name) values('workshop-media','dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/staged.png');
select pg_temp.assert_ok(public.add_workshop_member('dddddddd-dddd-4ddd-8ddd-dddddddddddd','member@example.com')->>'status'='added','stage membership can be prepared');
set local request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
select pg_temp.assert_ok((select count(*)=1 from public.workshop_projects),'member sees only active shared project');
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'member reads shared media but not stage media');
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(pg_temp.doc(),'{name}','"Общая игра"'),1)).revision=2,'member edits shared project');
insert into storage.objects(bucket_id,name) values('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/member.png');
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'member uploads shared project media');
select pg_temp.expect_error($q$select public.delete_workshop_project('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',2)$q$,'42501','member cannot delete project');
select pg_temp.expect_error($q$select public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','outsider@example.com')$q$,'42501','member cannot grant access');
select pg_temp.expect_error($q$select public.remove_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','22222222-2222-4222-8222-222222222222')$q$,'42501','member cannot change membership');
select pg_temp.expect_error($q$insert into public.workshop_members(project_id,user_id) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','33333333-3333-4333-8333-333333333333')$q$,'42501','direct membership escalation denied');
select pg_temp.expect_error($q$select public.save_workshop_project(pg_temp.doc('dddddddd-dddd-4ddd-8ddd-dddddddddddd'),1,true)$q$,'42501','member cannot activate owner stage');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name) values('workshop-media','dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/evil.png')$q$,'42501','member cannot upload to hidden stage');
select pg_temp.expect_error($q$update storage.objects set name='33333333-3333-4333-8333-333333333333/media/moved.png' where name like '%member.png'$q$,'42501','member cannot move media into inaccessible project');
set local request.jwt.claim.sub='33333333-3333-4333-8333-333333333333';
select pg_temp.assert_ok((select count(*)=0 from public.workshop_projects),'nonmember projects isolated');
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'nonmember media isolated');
select pg_temp.assert_ok((select count(*)=0 from public.workshop_members),'nonmember membership list isolated');
select pg_temp.assert_ok((select count(*)=1 from public.workshop_profiles),'nonmember sees only own profile');
select pg_temp.expect_error($q$select public.save_workshop_project(pg_temp.doc(),2)$q$,'42501','nonmember cannot edit');
select pg_temp.expect_error($q$select * from public.list_workshop_members('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$q$,'42501','nonmember cannot enumerate team');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name) values('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/evil.png')$q$,'42501','nonmember cannot upload media');
with removed as (delete from storage.objects returning id) select pg_temp.assert_ok((select count(*)=0 from removed),'nonmember cannot delete hidden media');
-- A spoofed metadata email and unconfirmed actual email cannot claim invitation.
set local request.jwt.claim.sub='55555555-5555-4555-8555-555555555555';
select pg_temp.assert_ok(public.claim_workshop_invites()=0,'unverified email cannot claim invite');
select pg_temp.assert_ok((select count(*)=0 from public.workshop_projects),'unverified user remains isolated');
reset role;
update auth.users set email_confirmed_at=now() where id='55555555-5555-4555-8555-555555555555';
set local role authenticated;
select pg_temp.assert_ok(public.claim_workshop_invites()=1,'verified auth email claims invite');
select pg_temp.assert_ok(public.claim_workshop_invites()=0,'invite claim is idempotent');
select pg_temp.assert_ok((select count(*)=1 from public.workshop_projects),'claimed invitation grants project access');
set local request.jwt.claim.sub='44444444-4444-4444-8444-444444444444';
select pg_temp.assert_ok(public.get_workshop_identity()->>'is_admin'='true','explicit administrator recognized');
select pg_temp.assert_ok((select count(*)=5 from public.list_workshop_users()),'administrator lists all accounts');
select pg_temp.assert_ok((select count(*)=5 from public.workshop_profiles),'administrator reads all profiles');
select pg_temp.assert_ok((select count(*)=3 from storage.objects),'administrator reads all project media including staging');
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc('dddddddd-dddd-4ddd-8ddd-dddddddddddd'),1)).status='active','administrator activates foreign stage');
select pg_temp.assert_ok((select count(*)=2 from public.workshop_projects),'administrator sees all active projects');
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc('dddddddd-dddd-4ddd-8ddd-dddddddddddd'),2,false)).status='active','active project cannot be hidden by false activation');
select pg_temp.assert_ok(public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','outsider@example.com')->>'status'='added','administrator adds foreign project member');
select public.remove_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','33333333-3333-4333-8333-333333333333');
select pg_temp.assert_ok(not exists(select 1 from public.workshop_members where user_id='33333333-3333-4333-8333-333333333333'),'administrator removes foreign project member');
select pg_temp.expect_error($q$select public.set_workshop_admin('44444444-4444-4444-8444-444444444444',false)$q$,'23514','last administrator cannot be removed');
select public.set_workshop_admin('33333333-3333-4333-8333-333333333333',true);
select pg_temp.assert_ok((select is_admin from public.list_workshop_users() where user_id='33333333-3333-4333-8333-333333333333'),'administrator grants role');
select public.set_workshop_admin('33333333-3333-4333-8333-333333333333',false);
select pg_temp.assert_ok(not (select is_admin from public.list_workshop_users() where user_id='33333333-3333-4333-8333-333333333333'),'administrator revokes role');
-- Deletion creates a tombstone: a different identifier cannot recycle its code;
-- the deleted identifier cannot receive a new code either.
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(pg_temp.doc(),'{records}','[]'),2)).revision=3,'administrator edits foreign project and deletes record');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{records,0,id}','"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"'),3)$q$,'23514','deleted code cannot be recycled');
select pg_temp.expect_error($q$select public.save_workshop_project(jsonb_set(jsonb_set(pg_temp.doc(),'{reserved_codes}','["12345","99999"]'),'{records,0,code}','"99999"'),3)$q$,'23514','deleted record identifier retains immutable code');
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(jsonb_set(jsonb_set(pg_temp.doc(),'{reserved_codes}','["12345","99999"]'),'{records,0,code}','"99999"'),'{records,0,id}','"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"'),3)).revision=4,'new identifier can use genuinely new code');
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select public.remove_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','22222222-2222-4222-8222-222222222222');
set local request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
select pg_temp.assert_ok((select count(*)=1 from public.workshop_projects),'removed member retains only other shared project');
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'removed member loses former project media immediately');
select pg_temp.expect_error($q$select public.save_workshop_project(pg_temp.doc(),4)$q$,'42501','removed member cannot save');
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc('ffffffff-ffff-4fff-8fff-ffffffffffff'),0)).owner_id=auth.uid(),'master can create independent own project');
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select pg_temp.assert_ok((select count(*)=2 from public.workshop_projects),'master cannot see another master independent project');
set local request.jwt.claim.sub='44444444-4444-4444-8444-444444444444';
select pg_temp.expect_error($q$select public.delete_workshop_project('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',3)$q$,'40001','administrator delete still requires current revision');
select public.delete_workshop_project('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',4);
select pg_temp.assert_ok((select count(*)=2 from public.workshop_projects),'administrator deletes foreign project');
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'orphaned storage objects become inaccessible after project deletion');
-- Identity backfills profiles for accounts created before the migration.
reset role;
delete from public.workshop_profiles where user_id='33333333-3333-4333-8333-333333333333';
set local role authenticated;
set local request.jwt.claim.sub='33333333-3333-4333-8333-333333333333';
select pg_temp.assert_ok(public.get_workshop_identity()->>'email'='outsider@example.com','existing account profile repaired by identity RPC');
set local role anon;
set local request.jwt.claim.sub='';
select pg_temp.expect_error($q$select * from public.workshop_projects$q$,'42501','anonymous project access denied');
select pg_temp.expect_error($q$select public.get_workshop_identity()$q$,'42501','anonymous RPC access denied');
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'anonymous media access denied');
reset role;
-- Every definer uses a fixed empty search_path, including internal helpers.
select pg_temp.assert_ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname like '%workshop%' and p.prosecdef
 and not ('search_path=""'=any(coalesce(p.proconfig,'{}')))),'all definer RPC search paths are fixed and empty');
rollback;
