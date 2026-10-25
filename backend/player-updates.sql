-- Additive, repeatable migration. Run AFTER schema.sql/account-update.sql.
-- Never make this bucket public. Players use get_player_release(known UUID),
-- then GET /storage/v1/object/player-releases/{download_path} with the public API key.
begin;

-- History deliberately survives project deletion: a published game identity/version
-- cannot be claimed by an imported project or have its bytes replaced later.
create table if not exists public.player_releases (
 game_id uuid not null, project_id uuid not null, version bigint not null check(version between 1 and 9007199254740991),
 name text not null, sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
 size bigint not null check(size between 1 and 1073741824), download_path text not null unique,
 created_at timestamptz not null default clock_timestamp(),
 primary key(game_id,version), unique(project_id,version)
);
alter table public.player_releases enable row level security;
revoke all on public.player_releases from public,anon,authenticated;
create index if not exists player_releases_project on public.player_releases(project_id);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('player-releases','player-releases',false,1073741824,array['application/octet-stream'])
on conflict(id) do update set public=false,file_size_limit=1073741824,allowed_mime_types=array['application/octet-stream'];

create or replace function public.get_player_release(p_game_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('game_id',r.game_id,'name',r.name,'version',r.version,
  'sha256',r.sha256,'size',r.size,'download_path',r.download_path,'created_at',r.created_at)
 from public.player_releases r join public.workshop_projects p on p.id=r.project_id
 where r.game_id=p_game_id and p.status='active' and (p.document->>'packageId')::uuid=r.game_id
 order by r.version desc limit 1;
$$;

create or replace function public.player_release_can_stage(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
 if p_name is null or p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[1-9][0-9]*/[0-9a-f]{64}\.rpgpack$'
  then return false;end if;
 return public.workshop_can_manage(split_part(p_name,'/',1)::uuid)
  and not exists(select 1 from public.player_releases where download_path=p_name);
exception when invalid_text_representation then return false;
end $$;

create or replace function public.player_release_is_current(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.player_releases r
  where r.download_path=p_name and public.get_player_release(r.game_id)->>'download_path'=p_name);
$$;

create or replace function public.publish_player_release(p_project_id uuid,p_expected_revision bigint,
 p_version bigint,p_path text,p_sha256 text,p_size bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare project public.workshop_projects; gid uuid; object_size numeric; latest bigint;
begin
 select * into project from public.workshop_projects where id=p_project_id for update;
 if not found or not public.workshop_can_manage(p_project_id) then
  raise exception 'Публикация доступна владельцу проекта и администратору.' using errcode='42501';end if;
 if p_expected_revision is null or project.revision<>p_expected_revision then
  raise exception 'Проект изменился. Обновите страницу и повторите публикацию.' using errcode='40001';end if;
 if project.status<>'active' or p_version is null or p_version<1 or p_version>9007199254740991
  or (project.document->>'version')::bigint<>p_version or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
  or p_size is null or p_size<1 or p_size>1073741824 or p_path is null
  or p_path<>p_project_id::text||'/'||p_version::text||'/'||p_sha256||'.rpgpack' then
  raise exception 'Некорректная версия, путь или контрольная сумма игрового пакета.' using errcode='23514';end if;
 gid:=(project.document->>'packageId')::uuid;
 -- Different imported projects may retain the same package UUID. Serialize that
 -- identity as well as this project's CAS lock; only its first publisher owns it.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(gid::text,17));
 if exists(select 1 from public.player_releases where game_id=gid and project_id<>p_project_id)
  or exists(select 1 from public.player_releases where project_id=p_project_id and game_id<>gid) then
  raise exception 'Идентификатор игры уже закреплён за другой публикацией. Создайте независимую копию проекта.' using errcode='23514';end if;
 select max(version) into latest from public.player_releases where game_id=gid;
 if p_version<=latest then
  raise exception 'Версия уже опубликована. Создайте новую сборку; понижение версии запрещено.' using errcode='23514';end if;
 select (o.metadata->>'size')::numeric into object_size from storage.objects o
  where o.bucket_id='player-releases' and o.name=p_path for share;
 if not found or object_size is null or object_size<>p_size then
  raise exception 'Игровой пакет не загружен или размер файла не совпадает.' using errcode='23514';end if;
 insert into public.player_releases(game_id,project_id,version,name,sha256,size,download_path)
 values(gid,p_project_id,p_version,project.document->>'name',p_sha256,p_size,p_path);
 return public.get_player_release(gid);
end $$;

-- RLS rejects normal client mutations; the trigger also protects immutable bytes
-- against service-role operations and publication/delete races. All operations
-- serialize with the same project row used by publication and project saves.
create or replace function public.player_release_guard_object()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if old.bucket_id='player-releases' then
  begin
   perform 1 from public.workshop_projects where id=split_part(old.name,'/',1)::uuid for update;
  exception when invalid_text_representation then null;end;
  if exists(select 1 from public.player_releases where download_path=old.name) then
   raise exception 'Опубликованный игровой пакет неизменяем.' using errcode='23514';end if;
 end if;
 if tg_op='DELETE' then return old;end if;
 return new;
end $$;
drop trigger if exists player_release_immutable_object on storage.objects;
create trigger player_release_immutable_object before update or delete on storage.objects
 for each row execute function public.player_release_guard_object();

revoke all on function public.get_player_release(uuid),public.publish_player_release(uuid,bigint,bigint,text,text,bigint),
 public.player_release_can_stage(text),public.player_release_is_current(text),public.player_release_guard_object()
 from public,anon,authenticated;
grant execute on function public.get_player_release(uuid),public.player_release_is_current(text) to anon,authenticated;
grant execute on function public.publish_player_release(uuid,bigint,bigint,text,text,bigint),public.player_release_can_stage(text) to authenticated;

drop policy if exists player_release_read on storage.objects;
create policy player_release_read on storage.objects for select to anon,authenticated
 using(bucket_id='player-releases' and current_setting('storage.operation',true)='storage.object.get_authenticated'
  and public.player_release_is_current(name));
drop policy if exists player_release_stage_lookup on storage.objects;
create policy player_release_stage_lookup on storage.objects for select to authenticated
 using(bucket_id='player-releases' and current_setting('storage.operation',true)
  in ('storage.object.delete','storage.object.delete_many') and public.player_release_can_stage(name));
drop policy if exists player_release_insert on storage.objects;
create policy player_release_insert on storage.objects for insert to authenticated
 with check(bucket_id='player-releases' and public.player_release_can_stage(name));
drop policy if exists player_release_delete on storage.objects;
create policy player_release_delete on storage.objects for delete to authenticated
 using(bucket_id='player-releases' and public.player_release_can_stage(name));
-- Intentionally no UPDATE policy: clients upload with upsert:false.
commit;
