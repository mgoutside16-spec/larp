-- Additive, repeatable repair AFTER player-auto-sync.sql.
-- Player content is intentionally public. Authorize its current referenced
-- bytes directly; hosted Storage need not provide any particular operation GUC.
-- Listing/signing can reveal metadata only for these same public player files.
begin;
drop policy if exists player_release_read on storage.objects;
create policy player_release_read on storage.objects for select to anon,authenticated
 using(bucket_id='player-releases' and public.player_release_is_current(name));
drop policy if exists player_auto_media_get on storage.objects;
create policy player_auto_media_get on storage.objects for select to anon,authenticated
 using(bucket_id='workshop-media' and public.player_auto_media_referenced(name));
-- Private print/unreferenced/staged files do not satisfy either predicate.
-- Bucket public flags, master policies, account RLS and every write policy stay
-- unchanged. The earlier player_storage_* compatibility helpers are unused.
commit;
