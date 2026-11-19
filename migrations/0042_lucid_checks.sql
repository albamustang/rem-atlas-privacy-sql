-- REM Atlas: lucid trainer reminders (CLAUDE.md section 8n, step 7). Run once in the Supabase SQL editor.
--
-- Opt-in reality-check notifications for members, at 10:00, 13:00, 16:00 and 19:00 on the person's
-- clock, on devices with notifications switched on. They never contain anything from dreams.

alter table public.profiles
  add column if not exists lucid_checks boolean not null default false,
  add column if not exists lucid_checks_last timestamptz;

-- Marks people as sent in the same statement, so overlapping cron runs can't send twice.
create or replace function public.claim_due_lucid_checks(max_rows int default 90)
returns table (user_id uuid)
language sql
security definer
set search_path = ''
as $$
  with due as (
    select p.user_id
    from public.profiles p
    where p.lucid_checks
      and public.member_tier(p.user_id) is not null
      and extract(hour from now() at time zone p.reminder_tz) in (10, 13, 16, 19)
      and (p.lucid_checks_last is null or p.lucid_checks_last < now() - interval '2 hours')
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.user_id)
    limit max_rows
    for update of p skip locked
  )
  update public.profiles p
  set lucid_checks_last = now()
  from due
  where p.user_id = due.user_id
  returning p.user_id;
$$;

revoke all on function public.claim_due_lucid_checks(int) from public, anon, authenticated;
grant execute on function public.claim_due_lucid_checks(int) to service_role;
