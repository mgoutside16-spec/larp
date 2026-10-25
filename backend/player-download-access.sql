-- Additive, repeatable repair AFTER player-auto-sync.sql. No data/bucket changes.
-- Storage GET context is server-set; neither request headers nor a client's SQL
-- parameters can establish it. Match the exact file path as an independent
-- alternative to storage.operation, which is absent on some deployed requests.
begin;
create or replace function public.player_storage_encode_path(p_path text)
returns text language plpgsql immutable strict set search_path = '' as $$
declare bytes bytea:=pg_catalog.convert_to(p_path,'UTF8'); result text:=''; i integer; b integer;
begin
 for i in 0..pg_catalog.octet_length(bytes)-1 loop
  b:=pg_catalog.get_byte(bytes,i);
  if b between 48 and 57 or b between 65 and 90 or b between 97 and 122 or b in (45,46,47,95,126) then
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

drop policy if exists player_release_read on storage.objects;
create policy player_release_read on storage.objects for select to anon,authenticated
 using(bucket_id='player-releases' and public.player_storage_is_file_get(bucket_id,name)
  and public.player_release_is_current(name));
drop policy if exists player_auto_media_get on storage.objects;
create policy player_auto_media_get on storage.objects for select to anon,authenticated
 using(bucket_id='workshop-media' and public.player_storage_is_file_get(bucket_id,name)
  and public.player_auto_media_referenced(name));
-- All existing master, account and cleanup policies are untouched. The buckets
-- stay private; no listing, signing, metadata REST access or write is granted.
commit;
