-- Free trial (CLAUDE.md 8o, decided 2026-11-09): 14 days of full membership, no card,
-- offered once a person has logged 7 nights, one per account for good.
-- A trial is its own table, not a fake Stripe membership, so it never gets a founding number
-- and Stripe's webhook never touches it. member_tier() treats an active trial as 'member',
-- so every existing limit, lock and guard in SQL includes it with no other change.

create table if not exists public.member_trials (
  user_id uuid primary key references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  -- Membership is 18+ (comments and bottles rely on it), so a trial asks the same question.
  over_18_confirmed_at timestamptz not null
);

alter table public.member_trials enable row level security;

-- Owners can see their own trial. Nobody writes it directly: start_member_trial() does, once.
create policy "owner reads own trial" on public.member_trials
  for select using (auth.uid() = user_id);
grant select on public.member_trials to authenticated;
revoke insert, update, delete on public.member_trials from anon, authenticated;
grant select on public.member_trials to service_role;

create or replace function public.member_tier(uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select tier from public.memberships
     where user_id = uid and status in ('active', 'trialing', 'past_due')),
    (select 'member' from public.member_trials
     where user_id = uid and now() < ends_at)
  );
$$;
grant execute on function public.member_tier(uuid) to anon, authenticated;

-- The signed-in person's own tier, for the app (membership or trial).
create or replace function public.my_tier()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select public.member_tier(auth.uid());
$$;
revoke all on function public.my_tier() from public, anon;
grant execute on function public.my_tier() to authenticated;

-- Nights logged at all (a dream or a sleep-diary night), whenever they were logged.
create or replace function public.nights_logged(uid uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) from (
    select dream_date as night from public.dreams where user_id = uid
    union
    select night from public.sleep_nights where user_id = uid
  ) n;
$$;
revoke all on function public.nights_logged(uuid) from public, anon, authenticated;

create or replace function public.start_member_trial(over_18 boolean)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  ends timestamptz;
begin
  if uid is null then
    raise exception 'log in first' using errcode = '42501';
  end if;
  if over_18 is not true then
    raise exception 'membership is 18+' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.member_trials where user_id = uid) then
    raise exception 'trial already used' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.memberships where user_id = uid) then
    raise exception 'already a member' using errcode = 'P0001';
  end if;
  if public.nights_logged(uid) < 7 then
    raise exception 'log 7 nights first' using errcode = 'P0001';
  end if;
  insert into public.member_trials (user_id, ends_at, over_18_confirmed_at)
  values (uid, now() + interval '14 days', now())
  returning ends_at into ends;
  return ends;
end;
$$;
revoke all on function public.start_member_trial(boolean) from public, anon;
grant execute on function public.start_member_trial(boolean) to authenticated;
