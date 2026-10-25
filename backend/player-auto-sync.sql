-- Additive, repeatable migration. Run AFTER schema.sql, account-update.sql and
-- player-updates.sql. Existing private workshop/account policies are unchanged.
-- Active projects become public player material automatically; print templates,
-- unreferenced media and account data remain private. Metadata/signing for the
-- same public player files is permitted; Storage context GUCs are not required.
begin;
-- Prevent a save/publication from escaping the initial version/binding backfill.
lock table public.workshop_projects in exclusive mode;
lock table public.player_releases in share row exclusive mode;

alter table public.workshop_projects add column if not exists player_version bigint
 check(player_version between 1 and 9007199254740991);

-- Deliberately no project FK: identity ownership survives deletion forever.
create table if not exists public.player_auto_sources (
 game_id uuid primary key, project_id uuid not null unique,
 created_at timestamptz not null default clock_timestamp()
);
alter table public.player_auto_sources enable row level security;
revoke all on public.player_auto_sources from public,anon,authenticated;
-- An existing first publisher always has priority, including deleted projects.
insert into public.player_auto_sources(game_id,project_id)
 select distinct on (game_id) game_id,project_id from public.player_releases
 order by game_id,created_at,version on conflict do nothing;
-- The schema records creation in the document rather than a separate column.
insert into public.player_auto_sources(game_id,project_id)
 select (document->>'packageId')::uuid,id from public.workshop_projects
 where status='active'
 order by (document->>'created')::timestamptz,id on conflict do nothing;

drop trigger if exists player_auto_project_version on public.workshop_projects;
-- Force one fresh player install after migration: a previously exported package
-- may have this same document.version while the master has since edited content.
-- At the wire integer ceiling, abort atomically rather than regress or overflow.
do $$ begin
 if exists(select 1 from public.workshop_projects p where p.player_version is null and (
  (p.document->>'version')::bigint>=9007199254740991 or p.revision>=9007199254740991 or
  exists(select 1 from public.player_releases r where r.version>=9007199254740991
   and (r.project_id=p.id or r.game_id=(p.document->>'packageId')::uuid)))) then
  raise exception 'Достигнут предел версий игры. Создайте независимую копию проекта.' using errcode='23514';
 end if;
end $$;
update public.workshop_projects p set player_version=greatest(p.player_version,
 (p.document->>'version')::bigint,p.revision,
 coalesce((select max(r.version) from public.player_releases r
  where r.project_id=p.id or r.game_id=(p.document->>'packageId')::uuid),0))+1
 where p.player_version is null;
alter table public.workshop_projects alter column player_version set default 1;
alter table public.workshop_projects alter column player_version set not null;

-- Exactly the fields sent to the player. Master builds, print settings, modified
-- bookkeeping and record revision alone do not invalidate an offline snapshot.
create or replace function public.player_auto_content(p_document jsonb)
returns jsonb language sql immutable set search_path = '' as $$
 select jsonb_build_object('game',jsonb_build_object('id',(p_document->>'packageId')::uuid,
 'name',p_document->'name','description',p_document->'description'),
 'created',p_document->'created','version',p_document->'version',
 'locations',p_document->'locations','records',coalesce((select jsonb_agg(r.value-'revision' order by r.ordinality)
 from jsonb_array_elements(p_document->'records') with ordinality r(value,ordinality)),'[]'::jsonb),
 'reserved_codes',p_document->'reserved_codes');
$$;
create or replace function public.player_auto_project_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare gid uuid:=(new.document->>'packageId')::uuid;
begin
 if tg_op='INSERT' then
  new.player_version:=greatest(1,new.revision,(new.document->>'version')::bigint,
   coalesce((select max(version) from public.player_releases where project_id=new.id or game_id=gid),1));
 else
  new.player_version:=old.player_version;
  if old.status is distinct from new.status or
   public.player_auto_content(old.document) is distinct from public.player_auto_content(new.document) then
   if old.player_version>=9007199254740991 then
    raise exception 'Достигнут предел версий игры.' using errcode='23514';end if;
   new.player_version:=greatest(old.player_version+1,(new.document->>'version')::bigint);
  end if;
 end if;
 if new.status='active' then
  -- Same identity lock as manual publication. ON CONFLICT also arbitrates
  -- concurrent imported copies before either project row becomes visible.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(gid::text,17));
  insert into public.player_auto_sources(game_id,project_id) values(gid,new.id) on conflict do nothing;
 end if;
 return new;
end $$;
create trigger player_auto_project_version before insert or update on public.workshop_projects
 for each row execute function public.player_auto_project_change();

-- Keep the existing manual archive protocol, extending its identity protection
-- to games which were automatically available before their first manual release.
create or replace function public.player_auto_release_identity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.game_id::text,17));
 insert into public.player_auto_sources(game_id,project_id) values(new.game_id,new.project_id) on conflict do nothing;
 if not exists(select 1 from public.player_auto_sources where game_id=new.game_id and project_id=new.project_id) then
  raise exception 'Идентификатор игры уже закреплён за другим проектом.' using errcode='23514';end if;
 return new;
end $$;
drop trigger if exists player_auto_release_source on public.player_releases;
create trigger player_auto_release_source before insert on public.player_releases
 for each row execute function public.player_auto_release_identity();

create or replace function public.get_player_source_version(p_project_id uuid)
returns bigint language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.workshop_can_access(p_project_id) then
  raise exception 'Проект недоступен.' using errcode='42501';end if;
 return (select player_version from public.workshop_projects where id=p_project_id);
end $$;

create or replace function public.get_player_catalog(p_after uuid default null,p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit<1 or p_limit>200 then
  raise exception 'Размер страницы должен быть от 1 до 200.' using errcode='23514';end if;
 select coalesce(jsonb_agg(x.item order by x.game_id),'[]'::jsonb) into result from (
  select s.game_id,jsonb_build_object('game_id',s.game_id,'project_id',p.id,
   'name',p.document->'name','description',left(coalesce(p.document->>'description',''),4000),'version',p.player_version,
   'record_count',jsonb_array_length(p.document->'records'),'updated_at',p.updated_at) item
  from public.player_auto_sources s join public.workshop_projects p on p.id=s.project_id
  where p.status='active' and (p.document->>'packageId')::uuid=s.game_id
   and (p_after is null or s.game_id>p_after)
  order by s.game_id limit p_limit
 ) x;
 return result;
end $$;

create or replace function public.get_player_snapshot(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare p public.workshop_projects; item record; size_text text; file_size bigint;
 files jsonb:='[]'; checksums jsonb:='{}'; checksum text; records jsonb;
begin
 select w.* into p from public.player_auto_sources s join public.workshop_projects w on w.id=s.project_id
 where s.game_id=p_game_id and w.status='active' and (w.document->>'packageId')::uuid=s.game_id;
 if not found then return null;end if;
 for item in select distinct b.value->>'value' path
  from jsonb_array_elements(p.document->'records') r,
   lateral jsonb_array_elements(r->'blocks') b
  where b.value->>'kind' in ('image','audio','video') order by path loop
  -- Never cast untrusted Storage metadata before verifying its bounded shape.
  select o.metadata->>'size' into size_text from storage.objects o
   where o.bucket_id='workshop-media' and o.name=p.id::text||'/'||item.path;
  if not found or size_text is null or size_text !~ '^[0-9]{1,10}$' then
   raise exception 'Медиафайл отсутствует или имеет некорректный размер.' using errcode='23514';end if;
  file_size:=size_text::bigint;
  if file_size<1 or file_size>536870912 then
   raise exception 'Недопустимый размер медиафайла.' using errcode='23514';end if;
  checksum:=substring(item.path from '^media/([0-9a-f]{64})\.[a-zA-Z0-9]+$');
  files:=files||jsonb_build_array(jsonb_build_object('path',item.path,
   'storage_path',p.id::text||'/'||item.path,'size',file_size,'sha256',checksum));
  checksums:=checksums||jsonb_build_object(item.path,checksum);
 end loop;
 select coalesce(jsonb_agg(r.value-'revision' order by r.ordinality),'[]'::jsonb) into records
  from jsonb_array_elements(p.document->'records') with ordinality r(value,ordinality);
 return jsonb_build_object('game_id',p_game_id,'project_id',p.id,'version',p.player_version,
  'manifest',jsonb_build_object('format_version',1,'version',p.player_version,'created',p.document->'created',
   'game',jsonb_build_object('id',p_game_id,'name',p.document->'name','description',p.document->'description'),
   'locations',p.document->'locations','records',records,'reserved_codes',p.document->'reserved_codes','checksums',checksums),
  'files',files);
end $$;

create or replace function public.player_auto_media_referenced(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.player_auto_sources s join public.workshop_projects p on p.id=s.project_id,
  lateral jsonb_array_elements(p.document->'records') r,
  lateral jsonb_array_elements(r->'blocks') b
  where p.status='active' and (p.document->>'packageId')::uuid=s.game_id
   and b->>'kind' in ('image','audio','video') and p_name=p.id::text||'/'||(b->>'value'));
$$;
-- Legacy compatibility helpers retained for installed clients; the public
-- player policies below authorize file references without relying on context.
create or replace function public.player_storage_encode_path(p_path text)
returns text language plpgsql immutable strict set search_path = '' as $$
declare bytes bytea:=pg_catalog.convert_to(p_path,'UTF8'); result text:=''; i integer; b integer;
begin
 for i in 0..pg_catalog.octet_length(bytes)-1 loop
  b:=pg_catalog.get_byte(bytes,i);
  if b between 48 and 57 or b between 65 and 90 or b between 97 and 122 or b in (33,39,40,41,42,45,46,47,95,126) then
   result:=result||pg_catalog.chr(b);
  else result:=result||'%'||pg_catalog.upper(pg_catalog.lpad(pg_catalog.to_hex(b),2,'0'));end if;
 end loop;
 return result;
end $$;
create or replace function public.player_storage_is_file_get(p_bucket text,p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
 select coalesce(current_setting('storage.operation',true)
  in ('storage.object.get_authenticated','object.get_authenticated'),false)
 or (current_setting('request.method',true)='GET' and exists(
  select 1 from unnest(array['/object/','/object/authenticated/',
   '/storage/v1/object/','/storage/v1/object/authenticated/']) prefix
  where split_part(current_setting('request.path',true),'?',1)
   in (prefix||p_bucket||'/'||p_name,public.player_storage_encode_path(prefix||p_bucket||'/'||p_name))));
$$;
revoke all on function public.player_storage_encode_path(text),public.player_storage_is_file_get(text,text)
 from public,anon,authenticated;
grant execute on function public.player_storage_is_file_get(text,text) to anon,authenticated;

drop policy if exists player_auto_media_get on storage.objects;
create policy player_auto_media_get on storage.objects for select to anon,authenticated
 using(bucket_id='workshop-media' and public.player_auto_media_referenced(name));

-- Preserve the legacy archive protocol and current-release restriction.
drop policy if exists player_release_read on storage.objects;
create policy player_release_read on storage.objects for select to anon,authenticated
 using(bucket_id='player-releases' and public.player_release_is_current(name));

create table if not exists public.player_participants (
 participant_id uuid primary key default gen_random_uuid(),
 game_id uuid not null references public.player_auto_sources(game_id),
 token_hash text not null check(token_hash ~ '^[0-9a-f]{64}$'),
 character_name text not null check(length(character_name) between 1 and 100 and character_name !~ '[[:cntrl:]]'),
 first_seen timestamptz not null default clock_timestamp(),
 last_seen timestamptz not null default clock_timestamp(), unique(game_id,token_hash)
);
alter table public.player_participants enable row level security;
revoke all on public.player_participants from public,anon,authenticated;

create or replace function public.register_player(p_game_id uuid,p_character_name text,p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare player public.player_participants; character text:=trim(p_character_name);
begin
 if character is null or length(character) not between 1 and 100 or character ~ '[[:cntrl:]]'
  or p_token is null or length(p_token) not between 32 and 256 or p_token ~ '[[:cntrl:]]' then
  raise exception 'Некорректное имя персонажа или токен устройства.' using errcode='23514';end if;
 -- Hold the source row until the upsert is finished, serializing deletion/status
 -- changes with registration without allowing participant enumeration.
 perform 1 from public.player_auto_sources s join public.workshop_projects p on p.id=s.project_id
  where s.game_id=p_game_id and p.status='active' and (p.document->>'packageId')::uuid=s.game_id for share of p;
 if not found then raise exception 'Игра недоступна.' using errcode='23514';end if;
 insert into public.player_participants(game_id,token_hash,character_name)
 values(p_game_id,pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_token,'UTF8')),'hex'),character)
 on conflict(game_id,token_hash) do update set character_name=excluded.character_name,last_seen=clock_timestamp()
 returning * into player;
 return jsonb_build_object('participant_id',player.participant_id,'character_name',player.character_name,
  'first_seen',player.first_seen,'last_seen',player.last_seen);
end $$;

create or replace function public.list_game_players(p_project_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.workshop_can_access(p_project_id) then
  raise exception 'Проект недоступен.' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('participant_id',a.participant_id,
  'character_name',a.character_name,'first_seen',a.first_seen,'last_seen',a.last_seen)
  order by a.last_seen desc,a.participant_id),'[]'::jsonb)
  from public.player_participants a join public.player_auto_sources s on s.game_id=a.game_id
  where s.project_id=p_project_id);
end $$;

revoke all on function public.player_auto_content(jsonb),public.player_auto_project_change(),
 public.player_auto_release_identity(),public.get_player_source_version(uuid),public.get_player_catalog(uuid,integer),
 public.get_player_snapshot(uuid),public.player_auto_media_referenced(text),
 public.register_player(uuid,text,text),public.list_game_players(uuid) from public,anon,authenticated;
grant execute on function public.get_player_catalog(uuid,integer),public.get_player_snapshot(uuid),
 public.player_auto_media_referenced(text),public.register_player(uuid,text,text) to anon,authenticated;
grant execute on function public.get_player_source_version(uuid),public.list_game_players(uuid) to authenticated;
commit;
