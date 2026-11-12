-- PostgreSQL17 disposable only. Public player files are readable regardless
-- of hosted Storage context; no private media, accounts or writes are opened.
\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_ok(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end $$;
insert into auth.users(id,email,email_confirmed_at) values('88888888-1111-4111-8111-111111111111','storage-fix@example.test',now()),('88888888-3333-4333-8333-333333333333','storage-outsider@example.test',now());
insert into public.workshop_projects(id,owner_id,document) values('88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa','88888888-1111-4111-8111-111111111111',
 '{"id":"88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa","packageId":"88888888-bbbb-4bbb-8bbb-bbbbbbbbbbbb","name":"Synthetic GET fixture","description":"","created":"2026-10-25T00:00:00Z","modified":"2026-10-25T00:00:00Z","version":1,"locations":[],"records":[{"id":"88888888-cccc-4ccc-8ccc-cccccccccccc","title":"Fixture","code":"12345","location_id":null,"modified":"2026-10-25T00:00:00Z","revision":1,"blocks":[{"kind":"image","value":"media/referenced.png"}]}],"reserved_codes":["12345"],"builds":[],"printTemplates":{"private":"media/private-print.png"}}');
insert into storage.objects(bucket_id,name,metadata) values
 ('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png','{"size":3}'),
 ('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/private-print.png','{"size":3}'),
 ('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/unreferenced.png','{"size":3}'),
 ('player-releases','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack','{"size":3}'),
 ('player-releases','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('b',64)||'.rpgpack','{"size":3}');
insert into public.player_releases(game_id,project_id,version,name,sha256,size,download_path)
 values('88888888-bbbb-4bbb-8bbb-bbbbbbbbbbbb','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,'Fixture',repeat('a',64),3,'88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack');

set local role anon;
set local request.jwt.claim.sub='';
set local storage.operation='';
set local request.method='';
set local request.path='';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'public current archive and referenced media visible without ambient Storage context');
select pg_temp.assert_ok((select count(*)=1 from storage.objects where bucket_id='workshop-media'),'only referenced player media public');
select pg_temp.assert_ok((select count(*)=1 from storage.objects where bucket_id='player-releases'),'only current published archive public');
select pg_temp.assert_ok(not exists(select 1 from storage.objects where name like '%private-print.png'),'private print media denied');
select pg_temp.assert_ok(not exists(select 1 from storage.objects where name like '%unreferenced.png'),'unreferenced non-print media denied');
select pg_temp.assert_ok(not exists(select 1 from storage.objects where name like '%/2/%'),'staged archive denied');
set local storage.operation='storage.object.list';
set local request.method='POST';
set local request.path='/object/list/workshop-media';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'listing exposes only already-public player file metadata');
set local storage.operation='storage.object.get_authenticated';
set local request.method='GET';
set local request.path='/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'ordinary Storage GET reads public player files');
set local storage.operation='object.sign';
set local request.method='POST';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'public file visibility also supports signed downloads');
with deleted as (delete from storage.objects returning *) select pg_temp.assert_ok((select count(*)=0 from deleted),'anonymous still cannot delete any files');
with changed as (update storage.objects set metadata='{"size":999}' returning *) select pg_temp.assert_ok((select count(*)=0 from changed),'anonymous still cannot overwrite any files');
do $$ begin
 begin
  insert into storage.objects(bucket_id,name,metadata) values('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/attack.png','{"size":1}');
  raise exception 'FAIL anonymous upload allowed';
 exception when insufficient_privilege then raise notice 'PASS anonymous upload denied';end;
end $$;
set local role authenticated;
set local request.jwt.claim.sub='88888888-3333-4333-8333-333333333333';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'unrelated authenticated account gets only public player files');
with deleted as (delete from storage.objects returning *) select pg_temp.assert_ok((select count(*)=0 from deleted),'unrelated authenticated account cannot delete public files');
select pg_temp.assert_ok((select count(*)=0 from public.workshop_projects),'authenticated outsider cannot read master projects');
select pg_temp.assert_ok(not exists(select 1 from public.workshop_profiles where user_id='88888888-1111-4111-8111-111111111111'),'authenticated outsider cannot read another account profile');
do $$ begin
 begin
  perform 1 from public.player_participants;
  raise exception 'FAIL participant table access';
 exception when insufficient_privilege then raise notice 'PASS participant table inaccessible';end;
end $$;
set local role anon;
do $$ declare table_name text;begin
 foreach table_name in array array['workshop_projects','workshop_profiles','player_participants'] loop
  begin
   execute 'select 1 from public.'||quote_ident(table_name);
   raise exception 'FAIL private table access: %',table_name;
  exception when insufficient_privilege then raise notice 'PASS private % still inaccessible',table_name;end;
 end loop;
end $$;
reset role;
delete from public.player_releases where game_id='88888888-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
delete from public.workshop_projects where id='88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
set local role anon;
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'deleted source and unpublished archives immediately cease public access');
rollback;
