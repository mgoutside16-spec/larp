-- PostgreSQL 17 disposable fixture only. Run after player-auto-sync.sql and
-- player-download-access.sql; all synthetic data rolls back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_ok(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end $$;
select pg_temp.assert_ok(to_regprocedure('public.player_storage_is_file_get(text,text)') is not null,'Storage GET compatibility guard installed');
insert into auth.users(id,email,email_confirmed_at) values('88888888-1111-4111-8111-111111111111','storage-fix@example.test',now());
insert into public.workshop_projects(id,owner_id,document) values('88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa','88888888-1111-4111-8111-111111111111',
 '{"id":"88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa","packageId":"88888888-bbbb-4bbb-8bbb-bbbbbbbbbbbb","name":"Synthetic GET fixture","description":"","created":"2026-10-25T00:00:00Z","modified":"2026-10-25T00:00:00Z","version":1,"locations":[],"records":[{"id":"88888888-cccc-4ccc-8ccc-cccccccccccc","title":"Fixture","code":"12345","location_id":null,"modified":"2026-10-25T00:00:00Z","revision":1,"blocks":[{"kind":"image","value":"media/referenced.png"}]}],"reserved_codes":["12345"],"builds":[],"printTemplates":{"private":"media/private-print.png"}}');
insert into storage.objects(bucket_id,name,metadata) values
 ('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png','{"size":3}'),
 ('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/private-print.png','{"size":3}'),
 ('player-releases','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack','{"size":3}'),
 ('player-releases','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('b',64)||'.rpgpack','{"size":3}');
insert into public.player_releases(game_id,project_id,version,name,sha256,size,download_path)
 values('88888888-bbbb-4bbb-8bbb-bbbbbbbbbbbb','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,'Fixture',repeat('a',64),3,'88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack');
set local role anon;
set local request.jwt.claim.sub='';
set local request.method='GET';
set local request.path='/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
set local storage.operation='';
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'missing operation GUC permits exact referenced media GET');
set local request.path='/object/authenticated/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'authenticated route alias works without operation GUC');
set local request.path='/storage/v1/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png?download=fixture.png';
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'gateway prefix and download query preserve exact object authorization');
set local request.path='/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/private-print.png';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'fallback never grants private print media');
set local request.path='/object/player-releases/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.rpgpack';
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'missing operation GUC permits current legacy archive GET');
set local request.path='/object/player-releases/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.rpgpack';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'fallback denies unpublished archive');
set local request.path='/object/list/workshop-media';
set local request.method='POST';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'missing-GUC Storage listing denied');
set local request.path='/object/sign/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'signed URL creation denied');
set local request.method='GET';
set local request.path='/rest/v1/objects';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'PostgREST metadata enumeration denied');
set local request.path='/object/info/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'object info route denied');
set local request.path='';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'direct database enumeration denied');
set local request.path='/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
set local request.method='POST';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'POST cannot exploit exact GET path');
set local request.method='HEAD';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'HEAD cannot exploit fallback');
set local request.method='GET';
set local storage.operation='storage.object.list';
select pg_temp.assert_ok((select count(*)=1 from storage.objects),'exact server-set GET path remains sufficient despite mismatched operation');
set local storage.operation='';
set local request.path='/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/%D0%9A%D0%B0%D0%B4%D1%80%201.png';
select pg_temp.assert_ok(public.player_storage_is_file_get('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/Кадр 1.png'),'encoded UTF8 filename matches exact requested path');
select pg_temp.assert_ok(not public.player_storage_is_file_get('workshop-media','88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/Other.png'),'encoded path cannot authorize another object');
set local request.path='/object/workshop-media/project/media/%D0%9A%D0%B0%D0%B4%D1%80%20(1)!.png';
select pg_temp.assert_ok(public.player_storage_is_file_get('workshop-media','project/media/Кадр (1)!.png'),'URI component punctuation with encoded UTF8 matches mobile encoding');
set local storage.operation='object.get_authenticated';
set local request.path='';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'unprefixed authenticated GET operation supported');
set local storage.operation='storage.object.get_authenticated';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'existing prefixed authenticated GET operation preserved');
do $$ declare table_name text;begin
 foreach table_name in array array['workshop_projects','workshop_profiles','player_participants'] loop
  begin
   execute 'select 1 from public.'||quote_ident(table_name);
   raise exception 'FAIL private table access: %',table_name;
  exception when insufficient_privilege then raise notice 'PASS private % still inaccessible',table_name;
  end;
 end loop;
end $$;
reset role;
delete from public.player_releases where game_id='88888888-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
delete from public.workshop_projects where id='88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
set local role anon;
set local storage.operation='';
set local request.path='/object/workshop-media/88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/referenced.png';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'deleted canonical source remains inaccessible with fallback');
rollback;
