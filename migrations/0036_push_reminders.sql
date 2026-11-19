-- REM Atlas: morning reminders as push notifications (CLAUDE.md section 8m). Run once in the
-- Supabase SQL editor, BEFORE pushing the code that uses it.
--
-- Each device someone switches on gets a row. The endpoint is a private address issued by the
-- browser's push service. Nothing about dreams is stored here or sent in a notification.

create table public.push_subscriptions (
  endpoint text primary key check (length(endpoint) between 20 and 1000 and endpoint like 'https://%'),
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null check (length(p256dh) between 20 and 200),
  auth text not null check (length(auth) between 10 and 100),
  created_at timestamptz not null default now()
);
create index push_subscriptions_user_idx on public.push_subscriptions(user_id);

alter table public.push_subscriptions enable row level security;

create policy "owner reads own push subscriptions" on public.push_subscriptions
  for select to authenticated using (auth.uid() = user_id);
create policy "owner deletes own push subscriptions" on public.push_subscriptions
  for delete to authenticated using (auth.uid() = user_id);

-- Auto-expose is off, so everything is granted by hand. Writes go through the function below.
grant select, delete on public.push_subscriptions to authenticated;
grant select, delete on public.push_subscriptions to service_role;

-- Saves this device for the signed-in person. Whoever holds an endpoint controls that browser,
-- so a shared device moves to whoever switched it on last. Keeps the newest 10 per person.
create or replace function public.save_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text, p_tz text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, uid, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();

  delete from public.push_subscriptions s
  where s.user_id = uid
    and s.endpoint not in (
      select k.endpoint from public.push_subscriptions k
      where k.user_id = uid order by k.created_at desc limit 10
    );

  insert into public.profiles (user_id) values (uid) on conflict (user_id) do nothing;
  if p_tz is not null and exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz) then
    update public.profiles set reminder_tz = p_tz where user_id = uid;
  end if;
end;
$$;
revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;

-- Who is due a reminder now, by email or push. Same rules as claim_due_reminders (0023), and
-- the same once-a-day mark, so nobody can get a second reminder that morning. email is null
-- when the person hasn't switched on email reminders.
create or replace function public.claim_due_checkins(max_rows int default 90)
returns table (user_id uuid, email text)
language sql
security definer
set search_path = ''
as $$
  with due as (
    select p.user_id,
           case when p.reminder_enabled then u.email end as email,
           (now() at time zone p.reminder_tz)::date as local_today
    from public.profiles p
    join auth.users u on u.id = p.user_id
    where u.email_confirmed_at is not null
      and (
        (p.reminder_enabled and u.email is not null)
        or exists (select 1 from public.push_subscriptions s where s.user_id = p.user_id)
      )
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
revoke all on function public.claim_due_checkins(int) from public, anon, authenticated;
grant execute on function public.claim_due_checkins(int) to service_role;
