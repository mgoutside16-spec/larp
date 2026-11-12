-- «Без правил»: paste into the Supabase SQL Editor. Repeatable; preserves project data.
-- Authentication comes from Supabase Auth. Signup creates a master, except the explicitly
-- authorized initial administrator mgoutside16@gmail.com after email verification.
begin;

create table if not exists public.workshop_projects (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  revision bigint not null default 1 check (revision > 0),
  document jsonb not null,
  updated_at timestamptz not null default now(),
  constraint document_matches_id check (document ->> 'id' = id::text)
);
alter table public.workshop_projects add column if not exists status text not null default 'active'
  check (status in ('active', 'importing'));
create index if not exists workshop_projects_owner_updated on public.workshop_projects(owner_id,updated_at desc);
create table if not exists public.workshop_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '', display_name text not null default ''
);
create table if not exists public.workshop_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
-- One authorized, verified email may claim the initial administrator role once.
-- This is never based on signup order or user-controlled metadata.
create table if not exists public.workshop_admin_bootstrap (
  email text primary key check(email=lower(trim(email)))
);
insert into public.workshop_admin_bootstrap(email)
select 'mgoutside16@gmail.com' where not exists(select 1 from public.workshop_admins)
on conflict do nothing;
create table if not exists public.workshop_members (
  project_id uuid not null references public.workshop_projects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  added_by uuid references auth.users(id) on delete set null,
  primary key(project_id,user_id)
);
create index if not exists workshop_members_user on public.workshop_members(user_id,project_id);
create table if not exists public.workshop_invites (
  project_id uuid not null references public.workshop_projects(id) on delete cascade,
  email text not null check(email = lower(trim(email))),
  added_by uuid references auth.users(id) on delete set null,
  primary key(project_id,email)
);
alter table public.workshop_invites add column if not exists created_at timestamptz not null default now();
-- Cleanup authorization survives project deletion without exposing deleted documents.
create table if not exists public.workshop_deleted_projects (
  id uuid primary key,owner_id uuid not null references auth.users(id) on delete cascade
);
alter table public.workshop_deleted_projects enable row level security;
revoke all on public.workshop_deleted_projects from public,anon,authenticated;
-- Kept outside the document so deleted record identifiers cannot acquire a new code later.
create table if not exists public.workshop_record_history (
  project_id uuid not null references public.workshop_projects(id) on delete cascade,
  record_id uuid not null, code text not null,
  primary key(project_id,record_id), unique(project_id,code)
);
insert into public.workshop_record_history(project_id,record_id,code)
select p.id,(r->>'id')::uuid,r->>'code' from public.workshop_projects p,
  lateral jsonb_array_elements(p.document->'records') r on conflict do nothing;

create or replace function public.workshop_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and exists(select 1 from public.workshop_admins where user_id=auth.uid());
$$;
create or replace function public.workshop_can_access(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and exists(select 1 from public.workshop_projects p where p.id=p_id and
 (p.owner_id=auth.uid() or public.workshop_is_admin() or (p.status='active' and exists
 (select 1 from public.workshop_members m where m.project_id=p.id and m.user_id=auth.uid()))));
$$;
create or replace function public.workshop_can_manage(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and exists(select 1 from public.workshop_projects p where p.id=p_id and
 (p.owner_id=auth.uid() or public.workshop_is_admin()));
$$;
create or replace function public.workshop_can_view_profile(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and (p_user_id=auth.uid() or public.workshop_is_admin() or exists(
 select 1 from public.workshop_projects p where p.status='active' and public.workshop_can_access(p.id)
 and (p.owner_id=p_user_id or exists(select 1 from public.workshop_members m
 where m.project_id=p.id and m.user_id=p_user_id))));
$$;

alter table public.workshop_projects enable row level security;
alter table public.workshop_profiles enable row level security;
alter table public.workshop_admins enable row level security;
alter table public.workshop_admin_bootstrap enable row level security;
alter table public.workshop_members enable row level security;
alter table public.workshop_invites enable row level security;
alter table public.workshop_record_history enable row level security;
revoke all on public.workshop_projects,public.workshop_profiles,public.workshop_admins,
 public.workshop_members,public.workshop_invites,public.workshop_record_history,public.workshop_admin_bootstrap from public,anon,authenticated;
grant select on public.workshop_projects,public.workshop_profiles,public.workshop_members,
 public.workshop_invites to authenticated;
drop policy if exists workshop_read_own on public.workshop_projects;
drop policy if exists workshop_read_accessible on public.workshop_projects;
create policy workshop_read_accessible on public.workshop_projects for select to authenticated
 using (status='active' and public.workshop_can_access(id));
drop policy if exists workshop_profile_read on public.workshop_profiles;
create policy workshop_profile_read on public.workshop_profiles for select to authenticated
 using (public.workshop_can_view_profile(user_id));
drop policy if exists workshop_members_read on public.workshop_members;
create policy workshop_members_read on public.workshop_members for select to authenticated
 using (public.workshop_can_access(project_id));
drop policy if exists workshop_invites_read on public.workshop_invites;
create policy workshop_invites_read on public.workshop_invites for select to authenticated
 using (public.workshop_can_manage(project_id));

create or replace function public.workshop_sync_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.workshop_profiles(user_id,email) values(new.id,coalesce(new.email,''))
 on conflict(user_id) do update set email=excluded.email;
 if new.email_confirmed_at is not null then
  -- DELETE locks and consumes the authorization atomically, including concurrent confirmations.
  with authorized as (delete from public.workshop_admin_bootstrap
   where email=lower(new.email) returning email)
  insert into public.workshop_admins(user_id) select new.id from authorized on conflict do nothing;
 end if;
 return new;
end $$;
drop trigger if exists workshop_auth_profile on auth.users;
create trigger workshop_auth_profile after insert or update of email,email_confirmed_at on auth.users
 for each row execute function public.workshop_sync_profile();
insert into public.workshop_profiles(user_id,email) select id,coalesce(email,'') from auth.users
 on conflict(user_id) do update set email=excluded.email;
-- Also supports an already registered, verified owner when installing the schema.
with authorized as (delete from public.workshop_admin_bootstrap b using auth.users u
 where lower(u.email)=b.email and u.email_confirmed_at is not null returning u.id)
insert into public.workshop_admins(user_id) select id from authorized on conflict do nothing;

create or replace function public.get_workshop_identity()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who uuid := auth.uid(); result jsonb;
begin
 if who is null then raise exception 'Необходим вход в аккаунт.' using errcode='42501'; end if;
 insert into public.workshop_profiles(user_id,email) select id,coalesce(email,'') from auth.users where id=who
 on conflict(user_id) do update set email=excluded.email;
 select jsonb_build_object('user_id',p.user_id,'email',p.email,'display_name',p.display_name,
 'is_admin',public.workshop_is_admin()) into result from public.workshop_profiles p where p.user_id=who;
 if result is null then raise exception 'Аккаунт не найден.' using errcode='42501'; end if;
 return result;
end $$;
create or replace function public.set_workshop_display_name(p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if p_name is null or length(trim(p_name))>100 then raise exception 'Имя должно содержать не более 100 символов.' using errcode='23514';end if;
 perform public.get_workshop_identity();
 update public.workshop_profiles set display_name=trim(p_name) where user_id=auth.uid();
 return public.get_workshop_identity();
end $$;
create or replace function public.list_workshop_users()
returns table(user_id uuid,email text,display_name text,is_admin boolean)
language plpgsql security definer set search_path = '' as $$
begin
 if not public.workshop_is_admin() then raise exception 'Нужны права администратора.' using errcode='42501';end if;
 insert into public.workshop_profiles(user_id,email) select u.id,coalesce(u.email,'') from auth.users u
 on conflict on constraint workshop_profiles_pkey do update set email=excluded.email;
 return query select p.user_id,p.email,p.display_name,exists(select 1 from public.workshop_admins a where a.user_id=p.user_id)
 from public.workshop_profiles p order by lower(p.email),p.user_id;
end $$;
create or replace function public.set_workshop_admin(p_user_id uuid,p_admin boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
 -- Serialize role mutations, including concurrent attempts to remove the last two admins.
 lock table public.workshop_admins in share row exclusive mode;
 if not public.workshop_is_admin() then raise exception 'Нужны права администратора.' using errcode='42501';end if;
 if p_admin is null or p_user_id is null then raise exception 'Не указана роль или пользователь.' using errcode='23514';end if;
 if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'Пользователь не найден.' using errcode='23514';end if;
 if p_admin then insert into public.workshop_admins(user_id) values(p_user_id) on conflict do nothing;
 else
  if exists(select 1 from public.workshop_admins where user_id=p_user_id)
    and (select count(*) from public.workshop_admins)=1 then
   raise exception 'Нельзя удалить последнего администратора.' using errcode='23514';end if;
  delete from public.workshop_admins where user_id=p_user_id;
 end if;
end $$;

create or replace function public.validate_workshop_document(d jsonb,previous jsonb)
returns void language plpgsql set search_path = '' as $$
declare r jsonb; b jsonb; loc jsonb; build jsonb; old_record jsonb; c jsonb;
 seen_codes text[] := '{}'; seen_ids uuid[] := '{}'; seen_locations bigint[] := '{}';
 seen_names text[] := '{}'; rid uuid; lid bigint;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>16777216
 or jsonb_typeof(d->'id') is distinct from 'string' or jsonb_typeof(d->'packageId') is distinct from 'string'
 or jsonb_typeof(d->'name') is distinct from 'string' or coalesce(length(trim(d->>'name')),0)=0 or length(d->>'name')>500
 or jsonb_typeof(d->'description') is distinct from 'string'
 or jsonb_typeof(d->'created') is distinct from 'string' or jsonb_typeof(d->'modified') is distinct from 'string'
 or jsonb_typeof(d->'version') is distinct from 'number' or (d->>'version') !~ '^[0-9]+$'
 or jsonb_typeof(d->'records') is distinct from 'array' or jsonb_typeof(d->'locations') is distinct from 'array'
 or jsonb_typeof(d->'reserved_codes') is distinct from 'array' or jsonb_typeof(d->'builds') is distinct from 'array'
 then raise exception 'Некорректные данные проекта.' using errcode='23514';end if;
 perform (d->>'id')::uuid; perform (d->>'packageId')::uuid;
 if not isfinite((d->>'created')::timestamptz) or not isfinite((d->>'modified')::timestamptz) then
  raise exception 'Некорректная дата проекта.' using errcode='23514';end if;
 if (d->>'version')::numeric>9007199254740991 or jsonb_array_length(d->'records')>90000
 or jsonb_array_length(d->'reserved_codes')>90000 then raise exception 'Превышен допустимый размер.' using errcode='23514';end if;
 for c in select value from jsonb_array_elements(d->'reserved_codes') loop
  if jsonb_typeof(c) is distinct from 'string' or (c#>>'{}') !~ '^[1-9][0-9]{4}$' then
   raise exception 'Некорректный пятизначный код.' using errcode='23514';end if;
 end loop;
 if (select count(*) from jsonb_array_elements(d->'reserved_codes'))<>
 (select count(distinct value) from jsonb_array_elements(d->'reserved_codes')) then
 raise exception 'Коды в истории не должны повторяться.' using errcode='23514';end if;
 if previous is not null and not ((d->'reserved_codes') @> (previous->'reserved_codes')) then
 raise exception 'Историю выданных кодов нельзя удалять.' using errcode='23514';end if;
 for loc in select value from jsonb_array_elements(d->'locations') loop
  if jsonb_typeof(loc) is distinct from 'object' or jsonb_typeof(loc->'id') is distinct from 'number'
   or (loc->>'id') !~ '^[1-9][0-9]*$' or jsonb_typeof(loc->'name') is distinct from 'string'
   or coalesce(length(trim(loc->>'name')),0)=0 then raise exception 'Некорректная группа.' using errcode='23514';end if;
  if (loc->>'id')::numeric>9007199254740991 then raise exception 'Некорректный номер группы.' using errcode='23514';end if;
  lid := (loc->>'id')::bigint;
  if lid=any(seen_locations) or (loc->>'name')=any(seen_names) then raise exception 'Группы повторяются.' using errcode='23514';end if;
  seen_locations:=array_append(seen_locations,lid); seen_names:=array_append(seen_names,loc->>'name');
 end loop;
 for r in select value from jsonb_array_elements(d->'records') loop
  if jsonb_typeof(r) is distinct from 'object' or jsonb_typeof(r->'id') is distinct from 'string'
   or jsonb_typeof(r->'title') is distinct from 'string' or coalesce(length(trim(r->>'title')),0)=0
   or jsonb_typeof(r->'code') is distinct from 'string' or (r->>'code') !~ '^[1-9][0-9]{4}$'
   or jsonb_typeof(r->'blocks') is distinct from 'array' or jsonb_typeof(r->'modified') is distinct from 'string'
   or jsonb_typeof(r->'revision') is distinct from 'number' or (r->>'revision') !~ '^[1-9][0-9]*$'
   or not (r ? 'location_id') or not (d->'reserved_codes' ? (r->>'code'))
   then raise exception 'Некорректная запись.' using errcode='23514';end if;
  rid:=(r->>'id')::uuid;
  if not isfinite((r->>'modified')::timestamptz) then raise exception 'Некорректная дата записи.' using errcode='23514';end if;
  if (r->>'revision')::numeric>9007199254740991 or rid=any(seen_ids) or (r->>'code')=any(seen_codes)
   then raise exception 'Повторяющиеся записи и коды.' using errcode='23514';end if;
  if r->'location_id'<>'null'::jsonb then
   if jsonb_typeof(r->'location_id') is distinct from 'number' or (r->>'location_id') !~ '^[1-9][0-9]*$'
    then raise exception 'Некорректная группа записи.' using errcode='23514';end if;
   if not ((r->>'location_id')::numeric=any(seen_locations)) then raise exception 'Группа не найдена.' using errcode='23514';end if;
  end if;
  seen_codes:=array_append(seen_codes,r->>'code'); seen_ids:=array_append(seen_ids,rid);
  if previous is not null then
   select value into old_record from jsonb_array_elements(previous->'records') where (value->>'id')::uuid=rid;
   if old_record is not null and old_record->>'code'<>r->>'code' then
    raise exception 'Код существующей записи менять нельзя.' using errcode='23514';end if;
   if old_record is null and previous->'reserved_codes' ? (r->>'code') then
    raise exception 'Этот код уже использовался в проекте.' using errcode='23514';end if;
  end if;
  for b in select value from jsonb_array_elements(r->'blocks') loop
   if jsonb_typeof(b) is distinct from 'object' or jsonb_typeof(b->'kind') is distinct from 'string'
    or (b->>'kind') not in ('text','image','audio','video') or jsonb_typeof(b->'value') is distinct from 'string'
    or b- 'kind'- 'value'<>'{}'::jsonb
    then raise exception 'Некорректный блок.' using errcode='23514';end if;
   if b->>'kind'<>'text' and (b->>'value') !~ '^media/[^/\\[:cntrl:]]+$'
    then raise exception 'Некорректный путь медиафайла.' using errcode='23514';end if;
  end loop;
 end loop;
 for build in select value from jsonb_array_elements(d->'builds') loop
  if jsonb_typeof(build) is distinct from 'object' or jsonb_typeof(build->'version') is distinct from 'number'
   or (build->>'version') !~ '^[1-9][0-9]*$' or jsonb_typeof(build->'created') is distinct from 'string'
   or jsonb_typeof(build->'filename') is distinct from 'string' or coalesce(length(trim(build->>'filename')),0)=0
   then raise exception 'Некорректная сборка.' using errcode='23514';end if;
  if (build->>'version')::numeric>9007199254740991 or not isfinite((build->>'created')::timestamptz)
   then raise exception 'Некорректная версия или дата сборки.' using errcode='23514';end if;
 end loop;
 if d ? 'printTemplates' and jsonb_typeof(d->'printTemplates') is distinct from 'object'
  then raise exception 'Некорректные настройки печати.' using errcode='23514';end if;
exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range then
 raise exception 'Некорректный идентификатор, дата или число.' using errcode='23514';
end $$;

-- Drop the previous overload: PostgREST must see exactly one unambiguous save RPC.
drop function if exists public.save_workshop_project(jsonb,bigint);
create or replace function public.save_workshop_project(p_document jsonb,p_expected_revision bigint,p_activate boolean default true)
returns public.workshop_projects language plpgsql security definer set search_path = '' as $$
declare who uuid:=auth.uid(); pid uuid; previous public.workshop_projects; result public.workshop_projects;
begin
 if who is null or not exists(select 1 from auth.users where id=who) then raise exception 'Необходим вход в аккаунт.' using errcode='42501';end if;
 if p_expected_revision is null or p_expected_revision<0 or p_activate is null then raise exception 'Не указана версия проекта.' using errcode='23514';end if;
 begin pid:=(p_document->>'id')::uuid;
 exception when invalid_text_representation then raise exception 'Некорректный идентификатор проекта.' using errcode='23514';end;
 if pid is null then raise exception 'У проекта нет идентификатора.' using errcode='23514';end if;
 -- Serialize creation for this UUID too; concurrent first saves must produce a CAS conflict.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(pid::text,0));
 select * into previous from public.workshop_projects where id=pid for update;
 if found then
  if not public.workshop_can_access(pid) then raise exception 'Проект недоступен.' using errcode='42501';end if;
  if previous.revision<>p_expected_revision then raise exception 'Проект изменён. Обновите страницу и повторите действие.' using errcode='40001';end if;
  perform public.validate_workshop_document(p_document,previous.document);
  if exists(select 1 from jsonb_array_elements(p_document->'records') r join public.workshop_record_history h
   on h.project_id=pid and h.record_id=(r->>'id')::uuid where h.code<>r->>'code') then
   raise exception 'Код удалённой записи менять нельзя.' using errcode='23514';end if;
  update public.workshop_projects set document=p_document,revision=revision+1,updated_at=clock_timestamp(),
   status=case when status='active' or p_activate then 'active' else 'importing' end where id=pid returning * into result;
 else
  if p_expected_revision<>0 or exists(select 1 from public.workshop_deleted_projects where id=pid)
   then raise exception 'Проект удалён или ещё не создан.' using errcode='40001';end if;
  perform public.validate_workshop_document(p_document,null);
  insert into public.workshop_projects(id,owner_id,document,status) values(pid,who,p_document,
   case when p_activate then 'active' else 'importing' end) returning * into result;
 end if;
 insert into public.workshop_record_history(project_id,record_id,code)
 select pid,(r->>'id')::uuid,r->>'code' from jsonb_array_elements(p_document->'records') r on conflict do nothing;
 return result;
end $$;
create or replace function public.delete_workshop_project(p_id uuid,p_expected_revision bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare previous public.workshop_projects;
begin
 select * into previous from public.workshop_projects where id=p_id for update;
 if not found or not public.workshop_can_manage(p_id) then raise exception 'Проект недоступен.' using errcode='42501';end if;
 if p_expected_revision is null or previous.revision<>p_expected_revision then raise exception 'Проект изменён. Обновите страницу.' using errcode='40001';end if;
 insert into public.workshop_deleted_projects(id,owner_id) values(p_id,previous.owner_id)
 on conflict(id) do nothing;
 delete from public.workshop_projects where id=p_id;
end $$;

create or replace function public.list_workshop_members(p_project_id uuid)
returns table(user_id uuid,email text,display_name text,is_owner boolean)
language plpgsql security definer set search_path = '' as $$
begin
 if not public.workshop_can_access(p_project_id) then raise exception 'Проект недоступен.' using errcode='42501';end if;
 return query select p.user_id,p.email,p.display_name,p.user_id=w.owner_id
 from public.workshop_projects w join public.workshop_profiles p on p.user_id=w.owner_id or exists(
 select 1 from public.workshop_members m where m.project_id=w.id and m.user_id=p.user_id)
 where w.id=p_project_id order by (p.user_id=w.owner_id) desc,lower(p.email);
end $$;
create or replace function public.add_workshop_member(p_project_id uuid,p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target uuid; normalized text:=lower(trim(p_email));
begin
 perform 1 from public.workshop_projects where id=p_project_id for update;
 if not public.workshop_can_manage(p_project_id) then raise exception 'Нужны права владельца проекта.' using errcode='42501';end if;
 if normalized is null or length(normalized)>320 or normalized !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 then raise exception 'Укажите корректный email.' using errcode='23514';end if;
 select id into target from auth.users where lower(email)=normalized and email_confirmed_at is not null limit 1;
 if target is null then
  insert into public.workshop_invites(project_id,email,added_by) values(p_project_id,normalized,auth.uid()) on conflict do nothing;
  return jsonb_build_object('status','invited');
 end if;
 if not exists(select 1 from public.workshop_projects where id=p_project_id and owner_id=target) then
  insert into public.workshop_members(project_id,user_id,added_by) values(p_project_id,target,auth.uid()) on conflict do nothing;
 end if;
 delete from public.workshop_invites where project_id=p_project_id and email=normalized;
 return jsonb_build_object('status','added');
end $$;
create or replace function public.remove_workshop_member(p_project_id uuid,p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
 perform 1 from public.workshop_projects where id=p_project_id for update;
 if not public.workshop_can_manage(p_project_id) then raise exception 'Нужны права владельца проекта.' using errcode='42501';end if;
 if exists(select 1 from public.workshop_projects where id=p_project_id and owner_id=p_user_id)
 then raise exception 'Владельца нельзя удалить из проекта.' using errcode='23514';end if;
 delete from public.workshop_members where project_id=p_project_id and user_id=p_user_id;
end $$;
create or replace function public.list_workshop_invites(p_project_id uuid)
returns table(email text,created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
 if not public.workshop_can_manage(p_project_id) then
  raise exception 'Нужны права владельца проекта.' using errcode='42501';end if;
 return query select i.email,i.created_at from public.workshop_invites i
 where i.project_id=p_project_id order by i.created_at,i.email;
end $$;

create or replace function public.remove_workshop_invite(p_project_id uuid,p_email text)
returns void language plpgsql security definer set search_path = '' as $$
declare normalized text:=lower(trim(p_email));
begin
 perform 1 from public.workshop_projects where id=p_project_id for update;
 if not public.workshop_can_manage(p_project_id) then
  raise exception 'Нужны права владельца проекта.' using errcode='42501';end if;
 if normalized is null or length(normalized)>320 or normalized !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
  raise exception 'Укажите корректный email.' using errcode='23514';end if;
 delete from public.workshop_invites where project_id=p_project_id and email=normalized;
end $$;

create or replace function public.claim_workshop_invites()
returns integer language plpgsql security definer set search_path = '' as $$
declare verified_email text; total integer;
begin
 if auth.uid() is null then raise exception 'Необходим вход в аккаунт.' using errcode='42501';end if;
 select lower(email) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if verified_email is null then return 0;end if;
 -- Deleting and claiming use one statement: an invitation can be claimed only once.
 with claimed as (delete from public.workshop_invites where email=verified_email returning project_id,added_by),
 added as (insert into public.workshop_members(project_id,user_id,added_by)
 select c.project_id,auth.uid(),c.added_by from claimed c join public.workshop_projects p on p.id=c.project_id
 where p.owner_id<>auth.uid() on conflict do nothing returning 1)
 select count(*)::integer into total from added;
 return total;
end $$;

-- Only named client entry points are executable. Trigger/validation helpers remain private.
do $$ declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and (p.proname like '%workshop%') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 end loop;
end $$;
grant execute on function public.workshop_is_admin(),public.workshop_can_access(uuid),public.workshop_can_manage(uuid),
 public.workshop_can_view_profile(uuid),public.get_workshop_identity(),public.set_workshop_display_name(text),
 public.list_workshop_users(),public.set_workshop_admin(uuid,boolean),public.list_workshop_members(uuid),
 public.add_workshop_member(uuid,text),public.remove_workshop_member(uuid,uuid),public.claim_workshop_invites(),
 public.list_workshop_invites(uuid),public.remove_workshop_invite(uuid,text),
 public.save_workshop_project(jsonb,bigint,boolean),public.delete_workshop_project(uuid,bigint) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit)
values('workshop-media','workshop-media',false,536870912)
on conflict(id) do update set public=false,file_size_limit=536870912;
create or replace function public.workshop_media_access(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
 if p_name is null or p_name !~ '^[0-9a-fA-F-]{36}/media/[^/\\[:cntrl:]]+$' then return false;end if;
 return public.workshop_can_access(split_part(p_name,'/',1)::uuid);
exception when invalid_text_representation then return false;
end $$;
revoke all on function public.workshop_media_access(text) from public,anon;
grant execute on function public.workshop_media_access(text) to authenticated;
create or replace function public.workshop_media_delete_access(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare pid uuid;
begin
 if auth.uid() is null or p_name is null or p_name !~ '^[0-9a-fA-F-]{36}/media/[^/\\[:cntrl:]]+$' then return false;end if;
 pid:=split_part(p_name,'/',1)::uuid;
 return public.workshop_is_admin() or public.workshop_can_access(pid) or
 (not exists(select 1 from public.workshop_projects where id=pid) and exists(
  select 1 from public.workshop_deleted_projects where id=pid and owner_id=auth.uid()));
exception when invalid_text_representation then return false;
end $$;
revoke all on function public.workshop_media_delete_access(text) from public,anon;
grant execute on function public.workshop_media_delete_access(text) to authenticated;
drop policy if exists workshop_media_cleanup_lookup on storage.objects;
drop policy if exists workshop_media_read on storage.objects;
drop policy if exists workshop_media_insert on storage.objects;
drop policy if exists workshop_media_update on storage.objects;
drop policy if exists workshop_media_delete on storage.objects;
-- PostgreSQL targeted DELETE also requires SELECT visibility. Storage sets this
-- operation server-side; GET, signed URLs and listing never receive this exception.
create policy workshop_media_cleanup_lookup on storage.objects for select to authenticated
 using(bucket_id='workshop-media' and current_setting('storage.operation',true)
  in ('storage.object.delete','storage.object.delete_many') and public.workshop_media_delete_access(name));
create policy workshop_media_read on storage.objects for select to authenticated
 using(bucket_id='workshop-media' and public.workshop_media_access(name));
create policy workshop_media_insert on storage.objects for insert to authenticated
 with check(bucket_id='workshop-media' and public.workshop_media_access(name));
create policy workshop_media_update on storage.objects for update to authenticated
 using(bucket_id='workshop-media' and public.workshop_media_access(name))
 with check(bucket_id='workshop-media' and public.workshop_media_access(name));
create policy workshop_media_delete on storage.objects for delete to authenticated
 using(bucket_id='workshop-media' and public.workshop_media_delete_access(name));

-- Realtime is optional on plain PostgreSQL; Supabase supplies this publication.
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
 select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='workshop_projects') then
  alter publication supabase_realtime add table public.workshop_projects;
 end if;
end $$;
commit;
