-- Disposable PostgreSQL 17 only, after schema.sql/account-update.sql/player-updates.sql.
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
select pg_temp.assert_ok(to_regprocedure('public.get_player_release(uuid)') is not null,'player lookup RPC installed');
create function pg_temp.doc() returns jsonb language sql as $$
 select '{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","packageId":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","name":"Игра игрока","description":"Секрет мастера","created":"2026-10-25T00:00:00Z","modified":"2026-10-25T00:00:00Z","version":1,"locations":[],"records":[],"reserved_codes":[],"builds":[{"version":1,"created":"2026-10-25T00:00:00Z","filename":"game.rpgpack"}]}'::jsonb;
$$;
insert into auth.users(id,email,email_confirmed_at) values
 ('11111111-1111-4111-8111-111111111111','player-owner@example.test',now()),
 ('22222222-2222-4222-8222-222222222222','player-member@example.test',now()),
 ('33333333-3333-4333-8333-333333333333','player-outsider@example.test',now()),
 ('44444444-4444-4444-8444-444444444444','player-admin@example.test',now());
insert into public.workshop_admins values('44444444-4444-4444-8444-444444444444');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select public.save_workshop_project(pg_temp.doc(),0);
select public.add_workshop_member('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','player-member@example.test');
insert into storage.objects(bucket_id,name,metadata) values('player-releases','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack','{"size":123}');
select pg_temp.assert_ok(public.get_player_release('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') is null,'staged archive is unpublished');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',0,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'40001','stale revision rejected');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,2,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'23514','version must match active document');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),122)$q$,'23514','declared archive size must match Storage');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('b',64)||'.rpgpack',repeat('b',64),123)$q$,'23514','missing archive rejected');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'../1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'23514','arbitrary archive path rejected');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',null,123)$q$,'23514','null checksum rejected');
set local request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'42501','project member cannot publish');
select pg_temp.expect_error($q$insert into storage.objects(bucket_id,name,metadata) values('player-releases','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('c',64)||'.rpgpack','{"size":123}')$q$,'42501','project member cannot stage releases');
set local request.jwt.claim.sub='33333333-3333-4333-8333-333333333333';
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'42501','outsider cannot publish');
set local role anon;
set local request.jwt.claim.sub='';
select pg_temp.assert_ok(public.get_player_release('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') is null,'anonymous lookup unpublished returns null');
select pg_temp.expect_error('select * from public.workshop_projects','42501','anonymous cannot enumerate projects');
select pg_temp.expect_error('select * from public.workshop_profiles','42501','anonymous cannot enumerate profiles');
select pg_temp.expect_error('select * from public.player_releases','42501','anonymous cannot enumerate release metadata');
set local storage.operation='storage.object.get_authenticated';
select pg_temp.assert_ok((select count(*)=0 from storage.objects where bucket_id='player-releases'),'anonymous cannot download staged archives');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select pg_temp.assert_ok(public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)->>'game_id'='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','published identity comes from packageId');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'23514','same version cannot be replaced');
set local storage.operation='storage.object.delete';
with deleted as (delete from storage.objects where bucket_id='player-releases' returning *) select pg_temp.assert_ok((select count(*)=0 from deleted),'owner cannot delete published archive');
set local role anon;
set local request.jwt.claim.sub='';
select pg_temp.assert_ok(public.get_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') is null,'project UUID is not substituted for package identity');
select pg_temp.assert_ok(public.get_player_release('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') @> jsonb_build_object('game_id','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','name','Игра игрока','version',1,'sha256',repeat('a',64),'size',123,'download_path','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack'),'anonymous gets exact safe metadata by known game UUID');
select pg_temp.assert_ok((select count(*)=7 from jsonb_object_keys(public.get_player_release('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'))),'metadata has no document or owner data');
set local storage.operation='storage.object.get_authenticated';
select pg_temp.assert_ok((select count(*)=1 from storage.objects where bucket_id='player-releases'),'anonymous can download current archive');
set local storage.operation='storage.object.list';
select pg_temp.assert_ok((select count(*)=0 from storage.objects where bucket_id='player-releases'),'anonymous cannot list release objects');
set local storage.operation='';
select pg_temp.assert_ok((select count(*)=0 from storage.objects where bucket_id='player-releases'),'direct Storage metadata enumeration denied');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select public.save_workshop_project(jsonb_set(pg_temp.doc(),'{version}','2'),1);
insert into storage.objects(bucket_id,name,metadata) values('player-releases','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('b',64)||'.rpgpack','{"size":456}');
insert into storage.objects(bucket_id,name,metadata) values('player-releases','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('c',64)||'.rpgpack','{"size":456}');
set local storage.operation='storage.object.delete';
with deleted as (delete from storage.objects where name like '%'||repeat('c',64)||'.rpgpack' returning *) select pg_temp.assert_ok((select count(*)=1 from deleted),'owner can delete own staged archive');
set local request.jwt.claim.sub='44444444-4444-4444-8444-444444444444';
select pg_temp.assert_ok(public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',2,2,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('b',64)||'.rpgpack',repeat('b',64),456)->>'version'='2','administrator can publish newer active version');
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,2,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/2/'||repeat('b',64)||'.rpgpack',repeat('b',64),456)$q$,'40001','concurrent stale publication rejected');
set local role anon;
set local request.jwt.claim.sub='';
set local storage.operation='storage.object.get_authenticated';
select pg_temp.assert_ok((select count(*)=1 and bool_and(name like '%/2/%') from storage.objects where bucket_id='player-releases'),'only latest published archive can be downloaded');
reset role;
select pg_temp.expect_error($q$update storage.objects set metadata='{"size":1}' where bucket_id='player-releases' and name like '%/1/%'$q$,'23514','published historical archive immutable even with service access');
select pg_temp.expect_error($q$delete from storage.objects where bucket_id='player-releases' and name like '%/2/%'$q$,'23514','published current archive cannot be deleted by bypassing RLS');
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
select public.save_workshop_project(pg_temp.doc(),2);
select pg_temp.expect_error($q$select public.publish_player_release('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',3,1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/1/'||repeat('a',64)||'.rpgpack',repeat('a',64),123)$q$,'23514','downgrade rejected even if workshop document version was lowered');
select public.save_workshop_project(jsonb_set(jsonb_set(pg_temp.doc(),'{id}','"dddddddd-dddd-4ddd-8ddd-dddddddddddd"'),'{version}','3'),0);
insert into storage.objects(bucket_id,name,metadata) values('player-releases','dddddddd-dddd-4ddd-8ddd-dddddddddddd/3/'||repeat('d',64)||'.rpgpack','{"size":123}');
select pg_temp.expect_error($q$select public.publish_player_release('dddddddd-dddd-4ddd-8ddd-dddddddddddd',1,3,'dddddddd-dddd-4ddd-8ddd-dddddddddddd/3/'||repeat('d',64)||'.rpgpack',repeat('d',64),123)$q$,'23514','imported project cannot hijack an already published game UUID');
select public.save_workshop_project(jsonb_set(jsonb_set(pg_temp.doc(),'{id}','"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"'),'{packageId}','"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"'),0,false);
insert into storage.objects(bucket_id,name,metadata) values('player-releases','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/1/'||repeat('e',64)||'.rpgpack','{"size":123}');
select pg_temp.expect_error($q$select public.publish_player_release('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',1,1,'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/1/'||repeat('e',64)||'.rpgpack',repeat('e',64),123)$q$,'23514','inactive import cannot be published');
rollback;
