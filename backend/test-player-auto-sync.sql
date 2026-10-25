-- Disposable PostgreSQL 17 only; never run this fixture in a real project.
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
select pg_temp.assert_ok(to_regprocedure('public.get_player_catalog(uuid,integer)') is not null,'automatic catalog installed');
create function pg_temp.doc(pid uuid default 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',gid uuid default 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') returns jsonb language sql as $$
 select jsonb_build_object('id',pid,'packageId',gid,'name','Automatic fixture','description',repeat('Fixture description ',500),
 'created','2026-10-25T00:00:00Z','modified','2026-10-25T00:00:00Z','version',0,'locations','[]'::jsonb,
 'records',jsonb_build_array(jsonb_build_object('id','cccccccc-cccc-4ccc-8ccc-cccccccccccc','code','12345','title','Fixture record','location_id',null,
 'modified','2026-10-25T00:00:00Z','revision',1,'blocks',jsonb_build_array(
 jsonb_build_object('kind','text','value','Synthetic fixture'),
 jsonb_build_object('kind','image','value','media/'||repeat('a',64)||'.png'),
 jsonb_build_object('kind','audio','value','media/legacy.ogg'),
 jsonb_build_object('kind','image','value','media/'||repeat('a',64)||'.png')))),
 'reserved_codes','["12345"]'::jsonb,'builds','[]'::jsonb,'printTemplates',jsonb_build_object('private','media/private-print.png'));
$$;
insert into auth.users(id,email,email_confirmed_at) values
 ('11111111-1111-4111-8111-111111111111','auto-owner@example.test',now()),
 ('22222222-2222-4222-8222-222222222222','auto-member@example.test',now()),
 ('33333333-3333-4333-8333-333333333333','auto-outsider@example.test',now()),
 ('44444444-4444-4444-8444-444444444444','auto-admin@example.test',now());
insert into public.workshop_admins values('44444444-4444-4444-8444-444444444444');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc(),0)).player_version=1,'first save gets player version without browser publish');
select public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','auto-member@example.test');
insert into storage.objects(bucket_id,name,metadata) values
 ('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/'||repeat('a',64)||'.png','{"size":123}'),
 ('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/legacy.ogg','{"size":"456"}'),
 ('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/private-print.png','{"size":99}'),
 ('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/unreferenced.png','{"size":88}');
select pg_temp.assert_ok(public.get_player_source_version('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=1,'owner gets source version');
select pg_temp.assert_ok(public.list_game_players('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')='[]','new project has empty participant list');
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(pg_temp.doc(),'{printTemplates,private}','"changed"'),1)).player_version=1,'print templates do not bump player version');
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(pg_temp.doc(),'{name}','"Changed"'),2)).player_version=2,'player content bumps independently from master revision');
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(pg_temp.doc(),'{version}','3'),3)).player_version=3,'manual export aligns server version');
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(pg_temp.doc(),'{version}','20'),4)).player_version=20,'explicit newer package version never regresses');
select pg_temp.assert_ok((public.save_workshop_project(pg_temp.doc(),5)).player_version=21,'lowered document version cannot regress player version');
select public.save_workshop_project(jsonb_set(pg_temp.doc('dddddddd-dddd-4ddd-8ddd-dddddddddddd','dddddddd-dddd-4ddd-8ddd-dddddddddddd'),'{records}','[]'),0);
select pg_temp.assert_ok((public.save_workshop_project(jsonb_set(jsonb_set(jsonb_set(pg_temp.doc('dddddddd-dddd-4ddd-8ddd-dddddddddddd','dddddddd-dddd-4ddd-8ddd-dddddddddddd'),'{records}','[]'),'{modified}','"2026-10-26T00:00:00Z"'),'{builds}','[{"version":1,"created":"2026-10-25T00:00:00Z","filename":"fixture.rpgpack"}]'),1)).player_version=1,'modified and build history alone do not bump player version');
select public.save_workshop_project(pg_temp.doc('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),0,false);
select public.save_workshop_project(pg_temp.doc('ffffffff-ffff-4fff-8fff-ffffffffffff'),0);
select public.save_workshop_project(jsonb_set(pg_temp.doc('ffffffff-ffff-4fff-8fff-ffffffffffff'),'{version}','1'),1);
insert into storage.objects(bucket_id,name,metadata) values('player-releases','ffffffff-ffff-4fff-8fff-ffffffffffff/1/'||repeat('f',64)||'.rpgpack','{"size":123}');
select pg_temp.expect_error($q$select public.publish_player_release('ffffffff-ffff-4fff-8fff-ffffffffffff',2,1,'ffffffff-ffff-4fff-8fff-ffffffffffff/1/'||repeat('f',64)||'.rpgpack',repeat('f',64),123)$q$,'23514','import cannot publish identity already automatically bound');
set local role anon;
set local request.jwt.claim.sub='';
select pg_temp.assert_ok(jsonb_array_length(public.get_player_catalog())=2,'active canonical projects and empty projects visible without publication');
select pg_temp.assert_ok(public.get_player_catalog(null,1)->0->>'game_id'='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','catalog sorted and paginated');
select pg_temp.assert_ok(public.get_player_catalog('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',1)->0->>'game_id'='dddddddd-dddd-4ddd-8ddd-dddddddddddd','catalog cursor advances');
select pg_temp.assert_ok(public.get_player_catalog('ffffffff-ffff-4fff-8fff-ffffffffffff',200)='[]','catalog end is empty array');
select pg_temp.expect_error('select public.get_player_catalog(null,0)','23514','zero page size rejected');
select pg_temp.expect_error('select public.get_player_catalog(null,201)','23514','page size cannot exceed 200');
select pg_temp.expect_error('select public.get_player_catalog(null,null)','23514','null page size rejected');
select pg_temp.assert_ok((select count(*)=7 from jsonb_object_keys(public.get_player_catalog()->0)),'catalog has exact public fields');
select pg_temp.assert_ok(length(public.get_player_catalog()->0->>'description')=4000,'large valid description is bounded in catalog preview');
select pg_temp.assert_ok(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')#>>'{manifest,game,description}'=pg_temp.doc()->>'description','snapshot preserves full valid description');
select pg_temp.assert_ok(public.get_player_catalog()->0 @> '{"version":21,"record_count":1,"name":"Automatic fixture"}'::jsonb,'catalog returns server version and count');
select pg_temp.assert_ok(public.get_player_snapshot('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') is null,'snapshot uses game UUID');
select pg_temp.assert_ok(public.get_player_snapshot('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee') is null,'inactive snapshot hidden');
select pg_temp.assert_ok(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') @> '{"version":21,"manifest":{"format_version":1,"version":21,"game":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}}}'::jsonb,'snapshot emits installable manifest identity/version');
select pg_temp.assert_ok(jsonb_array_length(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')->'files')=2,'snapshot deduplicates only record media');
select pg_temp.assert_ok((select count(*)=5 from jsonb_object_keys(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'))),'snapshot has exact top-level fields');
select pg_temp.assert_ok((select count(*)=8 from jsonb_object_keys(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')->'manifest')),'manifest has exact v1 fields');
select pg_temp.assert_ok((select count(*)=4 from jsonb_object_keys(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')#>'{files,0}')),'file descriptors have exact public fields');
select pg_temp.assert_ok((public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')#>'{manifest,checksums}') @> jsonb_build_object('media/'||repeat('a',64)||'.png',repeat('a',64),'media/legacy.ogg',null),'content-addressed checksums and null legacy checksum');
select pg_temp.assert_ok(not (public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')#>'{manifest,records,0}') ? 'revision','record revision omitted');
select pg_temp.assert_ok(not (public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')->'manifest') ?| array['printTemplates','builds','owner_id'],'master metadata absent');
select pg_temp.assert_ok((public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')->'files') @> '[{"path":"media/legacy.ogg","storage_path":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/legacy.ogg","size":456,"sha256":null}]','snapshot includes guarded file size and exact storage path');
set local storage.operation='storage.object.get_authenticated';
select pg_temp.assert_ok((select count(*)=2 from storage.objects where bucket_id='workshop-media'),'anonymous GET sees only referenced media');
select pg_temp.assert_ok(not exists(select 1 from storage.objects where name like '%private-print.png'),'private print media never readable by anonymous GET');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name,metadata) values('workshop-media','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/media/attack.png','{"size":1}')$q$,'42501','anonymous cannot write media');
with deleted as (delete from storage.objects returning *) select pg_temp.assert_ok((select count(*)=0 from deleted),'anonymous cannot delete media');
set local storage.operation='storage.object.list';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'anonymous listing contains only public referenced files');
set local storage.operation='';
select pg_temp.assert_ok((select count(*)=2 from storage.objects),'only public referenced metadata is visible');
select pg_temp.expect_error('select * from public.player_auto_sources','42501','source bindings private');
select pg_temp.expect_error('select * from public.workshop_projects','42501','project table remains private');
select pg_temp.expect_error('select * from public.workshop_profiles','42501','profiles remain private');
select pg_temp.expect_error('select * from public.player_participants','42501','participants table private');
select pg_temp.expect_error($q$select public.list_game_players('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$q$,'42501','anonymous cannot list players');
select pg_temp.expect_error($q$select public.get_player_source_version('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$q$,'42501','anonymous cannot query source version');
select pg_temp.expect_error($q$select public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','',repeat('a',64))$q$,'23514','empty character rejected');
select pg_temp.expect_error($q$select public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',E'bad\nname',repeat('a',64))$q$,'23514','control characters rejected');
select pg_temp.expect_error($q$select public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',repeat('x',101),repeat('a',64))$q$,'23514','long character rejected');
select pg_temp.expect_error($q$select public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Character','short')$q$,'23514','weak short token rejected');
select pg_temp.expect_error($q$select public.register_player('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','Character',repeat('a',64))$q$,'23514','inactive game registration rejected');
create temp table profile_result as select public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','  Character  ',repeat('a',64)) result;
select pg_temp.assert_ok((select result->>'character_name'='Character' and (select count(*)=4 from jsonb_object_keys(result)) from profile_result),'registration trims name and returns only public fields');
select pg_temp.assert_ok(public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Renamed',repeat('a',64))->>'participant_id'=(select result->>'participant_id' from profile_result),'same token renames existing participant');
select pg_temp.assert_ok(public.register_player('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Renamed',repeat('a',64))->>'first_seen'=(select result->>'first_seen' from profile_result),'heartbeat preserves original first seen');
reset role;
select pg_temp.assert_ok((select count(*)=1 and bool_and(token_hash=encode(sha256(convert_to(repeat('a',64),'UTF8')),'hex')) from public.player_participants),'only SHA256 token digest stored');
select pg_temp.assert_ok(not exists(select 1 from information_schema.columns where table_schema='public' and table_name='player_participants' and column_name='token'),'raw token has no storage column');
set local role authenticated;
set local request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
select pg_temp.assert_ok(jsonb_array_length(public.list_game_players('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'))=1,'shared master can list players');
select pg_temp.assert_ok(public.get_player_source_version('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=21,'shared master can obtain source version');
set local request.jwt.claim.sub='33333333-3333-4333-8333-333333333333';
select pg_temp.expect_error($q$select public.list_game_players('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$q$,'42501','outsider cannot list players');
select pg_temp.expect_error($q$select public.get_player_source_version('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$q$,'42501','outsider cannot query source version');
set local request.jwt.claim.sub='44444444-4444-4444-8444-444444444444';
select pg_temp.assert_ok(public.list_game_players('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')->0->>'character_name'='Renamed','administrator can list characters');
reset role;
update storage.objects set metadata='{"size":"invalid"}' where name like '%/legacy.ogg';
select pg_temp.expect_error($q$select public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$q$,'23514','malformed size rejected safely');
update storage.objects set metadata='{"size":536870913}' where name like '%/legacy.ogg';
select pg_temp.expect_error($q$select public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$q$,'23514','oversize media rejected');
delete from storage.objects where name like '%/legacy.ogg';
select pg_temp.expect_error($q$select public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$q$,'23514','missing media rejects entire snapshot');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select public.delete_workshop_project('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',6);
set local role anon;
set local request.jwt.claim.sub='';
select pg_temp.assert_ok(public.get_player_snapshot('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') is null,'deleted canonical source is unavailable');
select pg_temp.assert_ok(jsonb_array_length(public.get_player_catalog())=1,'import duplicate cannot claim deleted identity');
set local storage.operation='storage.object.get_authenticated';
select pg_temp.assert_ok((select count(*)=0 from storage.objects),'deleted source referenced media inaccessible');
reset role;
select pg_temp.assert_ok(exists(select 1 from public.player_auto_sources where game_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and project_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'source binding survives deletion as tombstone');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
do $$ declare i integer; pid uuid;begin
 for i in 1..205 loop
  pid:=md5('automatic-pagination-fixture-'||i::text)::uuid;
  perform public.save_workshop_project(jsonb_set(pg_temp.doc(pid,pid),'{records}','[]'),0);
 end loop;
end $$;
set local role anon;
set local request.jwt.claim.sub='';
select pg_temp.assert_ok(jsonb_array_length(public.get_player_catalog(null,200))=200,'large catalog returns full first page');
do $$ declare page jsonb; cursor_id uuid; total integer:=0;begin
 loop
  page:=public.get_player_catalog(cursor_id,100);
  exit when jsonb_array_length(page)=0;
  total:=total+jsonb_array_length(page);
  cursor_id:=(page->-1->>'game_id')::uuid;
 end loop;
 perform pg_temp.assert_ok(total=206,'pagination enumerates every project beyond 200');
end $$;
rollback;
