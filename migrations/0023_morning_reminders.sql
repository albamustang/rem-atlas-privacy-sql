-- REM Atlas: morning reminder emails (CLAUDE.md section 8j). Run once in the Supabase SQL editor.
--
-- Off unless the person switches them on. They choose an hour; their time zone comes from
-- their browser. Once an hour, the server asks which reminders are due and sends them. Nobody
-- is reminded twice in a day, and nobody who has already logged something since midnight
-- (their time) is reminded at all.

alter table profiles
  add column reminder_enabled boolean not null default false,
  add column reminder_hour smallint not null default 7 check (reminder_hour between 0 and 23),
  add column reminder_tz text not null default 'Europe/London',
  add column reminder_last_sent date;

-- A time zone Postgres doesn't know would break the hourly check for everyone, so refuse it.
create or replace function public.profiles_reminder_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.reminder_tz is distinct from old.reminder_tz
     and not exists (select 1 from pg_catalog.pg_timezone_names where name = new.reminder_tz) then
    raise exception 'unknown time zone' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger profiles_reminder_guard
  before update on profiles
  for each row execute function public.profiles_reminder_guard();

-- Who is due a reminder right now: switched on, email confirmed, it's their chosen hour, not
-- already reminded today, and nothing logged since their midnight. Marks them as reminded in
-- the same step, so two runs can't send twice. Only the server (secret key) may call it.
create or replace function public.claim_due_reminders(max_rows int default 90)
returns table (user_id uuid, email text)
language sql
security definer
set search_path = ''
as $$
  with due as (
    select p.user_id, u.email, (now() at time zone p.reminder_tz)::date as local_today
    from public.profiles p
    join auth.users u on u.id = p.user_id
    where p.reminder_enabled
      and u.email is not null
      and u.email_confirmed_at is not null
      and extract(hour from now() at time zone p.reminder_tz) = p.reminder_hour
      and (p.reminder_last_sent is null or p.reminder_last_sent < (now() at time zone p.reminder_tz)::date)
      and not exists (
        select 1 from public.dreams d
        where d.user_id = p.user_id
          and d.created_at >= ((now() at time zone p.reminder_tz)::date)::timestamp at time zone p.reminder_tz
      )
      and not exists (
        select 1 from public.sleep_nights s
        where s.user_id = p.user_id
          and s.created_at >= ((now() at time zone p.reminder_tz)::date)::timestamp at time zone p.reminder_tz
      )
    limit max_rows
    for update of p skip locked
  )
  update public.profiles p
  set reminder_last_sent = due.local_today
  from due
  where p.user_id = due.user_id
  returning p.user_id, due.email;
$$;
revoke all on function public.claim_due_reminders(int) from public, anon, authenticated;
grant execute on function public.claim_due_reminders(int) to service_role;

-- The one-click "stop reminders" link in each email switches them off (server only; the link
-- is signed, so it can only switch off the reminders of the person it was sent to).
create or replace function public.stop_reminders(uid uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles set reminder_enabled = false where user_id = uid;
$$;
revoke all on function public.stop_reminders(uuid) from public, anon, authenticated;
grant execute on function public.stop_reminders(uuid) to service_role;
