-- REM Atlas: let people delete their own account and everything in it (UK GDPR right to erasure).
-- Run once in the Supabase SQL editor.
--
-- Deleting a login normally needs the secret service key, which the website must never hold.
-- Instead, this function runs with the database owner's rights but can only ever delete the
-- account of whoever calls it. Their dreams go too (dreams.user_id is "on delete cascade").
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

-- Only signed-in people may call it; anonymous visitors may not.
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
