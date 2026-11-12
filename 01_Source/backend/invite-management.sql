-- Minimal repeatable update for an already installed workshop schema.
-- Existing pending invitations receive the installation timestamp.
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
commit;
