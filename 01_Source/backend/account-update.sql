-- Repeatable update for already installed accounts: invitation management and safe media cleanup.
-- Storage clients must collect paths BEFORE successful CAS deletion, then call remove(paths).
begin;

alter table public.workshop_invites add column if not exists created_at timestamptz not null default now();

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

revoke all on function public.list_workshop_invites(uuid),public.remove_workshop_invite(uuid,text)
 from public,anon,authenticated;
grant execute on function public.list_workshop_invites(uuid),public.remove_workshop_invite(uuid,text)
 to authenticated;

-- Cleanup authorization survives project deletion without exposing deleted documents.
create table if not exists public.workshop_deleted_projects (
  id uuid primary key,owner_id uuid not null references auth.users(id) on delete cascade
);
alter table public.workshop_deleted_projects enable row level security;
revoke all on public.workshop_deleted_projects from public,anon,authenticated;

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
create policy workshop_media_cleanup_lookup on storage.objects for select to authenticated
 using(bucket_id='workshop-media' and current_setting('storage.operation',true)
  in ('storage.object.delete','storage.object.delete_many') and public.workshop_media_delete_access(name));
drop policy if exists workshop_media_delete on storage.objects;
create policy workshop_media_delete on storage.objects for delete to authenticated
 using(bucket_id='workshop-media' and public.workshop_media_delete_access(name));
commit;
