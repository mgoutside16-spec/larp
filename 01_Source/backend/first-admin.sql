-- Run separately in the Supabase SQL Editor AFTER signup and email verification.
-- Explicitly promotes the confirmed account mgoutside16@gmail.com. Preserves all existing admins.
-- Never expose service-role keys in the web app.
begin;
do $$
declare account_id uuid;
begin
 select id into strict account_id from auth.users
 where lower(email)=lower('mgoutside16@gmail.com') and email_confirmed_at is not null;
 insert into public.workshop_admins(user_id) values(account_id) on conflict do nothing;
exception when no_data_found then
 raise exception 'Указанный подтверждённый аккаунт не найден. Сначала создайте и подтвердите аккаунт mgoutside16@gmail.com.';
end $$;
commit;
