-- REM Atlas: referrals (decided 2026-11-09). Each person can share a link. A friend who signs up
-- through it can start the 14-day free trial straight away (no 7-night wait). When that friend
-- first becomes a paying member, the person who invited them gets 14 days of membership, at most
-- 3 times in any 12 months. Membership is 18+, so sharing a link asks the same question.
-- Nobody writes these tables directly: the functions below do.

create table if not exists public.referral_codes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique check (code ~ '^[a-z2-9]{8}$'),
  over_18_confirmed_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists public.referrals (
  referred_id uuid primary key references auth.users(id) on delete cascade,
  referrer_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  rewarded_at timestamptz, -- set once, when the friend first pays
  check (referred_id <> referrer_id)
);
create index if not exists referrals_referrer_idx on public.referrals (referrer_id);

-- Membership time earned by inviting friends. Banked: each reward starts after any paid period,
-- trial or earlier reward, so nothing overlaps.
create table if not exists public.member_bonus (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bonus_until timestamptz not null
);

alter table public.referral_codes enable row level security;
alter table public.referrals enable row level security;
alter table public.member_bonus enable row level security;
create policy "owner reads own code" on public.referral_codes for select using (auth.uid() = user_id);
create policy "owner reads own bonus" on public.member_bonus for select using (auth.uid() = user_id);
-- referrals: no policies. People see only their own counts, through my_referrals().
grant select on public.referral_codes, public.member_bonus to authenticated;
revoke insert, update, delete on public.referral_codes, public.referrals, public.member_bonus from anon, authenticated;
grant select on public.referral_codes, public.referrals, public.member_bonus to service_role;

-- member_tier() now also counts earned bonus time.
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
     where user_id = uid and now() < ends_at),
    (select 'member' from public.member_bonus
     where user_id = uid and now() < bonus_until)
  );
$$;
grant execute on function public.member_tier(uuid) to anon, authenticated;

-- Your share code, made on first ask (after the 18+ tick).
create or replace function public.my_referral_code(over_18 boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  c text;
  alphabet text := 'abcdefghijkmnpqrstuvwxyz23456789';
begin
  if uid is null then
    raise exception 'log in first' using errcode = '42501';
  end if;
  select code into c from public.referral_codes where user_id = uid;
  if c is not null then
    return c;
  end if;
  if over_18 is not true then
    raise exception 'membership is 18+' using errcode = 'P0001';
  end if;
  loop
    c := '';
    for i in 1..8 loop
      c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    begin
      insert into public.referral_codes (user_id, code, over_18_confirmed_at) values (uid, c, now());
      return c;
    exception when unique_violation then
      -- try another code
    end;
  end loop;
end;
$$;
revoke all on function public.my_referral_code(boolean) from public, anon;
grant execute on function public.my_referral_code(boolean) to authenticated;

-- Link a new account to whoever invited it. The code comes from the account's own sign-up
-- metadata (referral_code), so it survives opening the email link on another device.
-- Only for accounts under 7 days old that have never been members; once only; never yourself.
create or replace function public.claim_referral()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  c text;
  made timestamptz;
  ref uuid;
begin
  if uid is null then
    return false;
  end if;
  select lower(raw_user_meta_data ->> 'referral_code'), created_at into c, made from auth.users where id = uid;
  if c is null or made < now() - interval '7 days' then
    return false;
  end if;
  if exists (select 1 from public.referrals where referred_id = uid)
     or exists (select 1 from public.memberships where user_id = uid) then
    return false;
  end if;
  select user_id into ref from public.referral_codes where code = c;
  if ref is null or ref = uid then
    return false;
  end if;
  insert into public.referrals (referred_id, referrer_id) values (uid, ref) on conflict do nothing;
  return true;
end;
$$;
revoke all on function public.claim_referral() from public, anon;
grant execute on function public.claim_referral() to authenticated;

-- Counts for your own share panel: friends who joined, rewards earned, bonus time left.
create or replace function public.my_referrals()
returns table (joined bigint, rewarded bigint, rewards_this_year bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*),
         count(rewarded_at),
         count(*) filter (where rewarded_at > now() - interval '365 days')
  from public.referrals where referrer_id = auth.uid();
$$;
revoke all on function public.my_referrals() from public, anon;
grant execute on function public.my_referrals() to authenticated;

-- Whether you joined through a friend's link (shows the trial offer without the 7-night wait).
create or replace function public.i_was_referred()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.referrals where referred_id = auth.uid());
$$;
revoke all on function public.i_was_referred() from public, anon;
grant execute on function public.i_was_referred() to authenticated;

-- The free trial: a referred friend skips the 7-night wait. Everything else as in 0048.
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
  perform public.claim_referral();
  if public.nights_logged(uid) < 7 and not exists (select 1 from public.referrals where referred_id = uid) then
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

-- Reward the inviter when a referred friend first becomes a paying member (the Stripe webhook
-- writes memberships with the server key; this runs inside that write).
create or replace function public.referral_reward()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  start_at timestamptz;
begin
  if new.status not in ('active', 'trialing') then
    return new;
  end if;
  select * into r from public.referrals where referred_id = new.user_id and rewarded_at is null for update;
  if not found then
    return new;
  end if;
  if (select count(*) from public.referrals
      where referrer_id = r.referrer_id and rewarded_at > now() - interval '365 days') >= 3 then
    return new; -- yearly cap reached: this friend stays unrewarded
  end if;
  update public.referrals set rewarded_at = now() where referred_id = r.referred_id;
  -- Start after whatever already covers them: a paid period, a trial, earlier bonus time.
  select greatest(
    now(),
    coalesce((select current_period_end from public.memberships
              where user_id = r.referrer_id and status in ('active', 'trialing', 'past_due')), now()),
    coalesce((select ends_at from public.member_trials where user_id = r.referrer_id), now()),
    coalesce((select bonus_until from public.member_bonus where user_id = r.referrer_id), now())
  ) into start_at;
  insert into public.member_bonus (user_id, bonus_until) values (r.referrer_id, start_at + interval '14 days')
  on conflict (user_id) do update set bonus_until = excluded.bonus_until;
  return new;
end;
$$;
revoke all on function public.referral_reward() from public, anon, authenticated;

drop trigger if exists memberships_referral_reward on public.memberships;
create trigger memberships_referral_reward
  after insert or update of status on public.memberships
  for each row execute function public.referral_reward();
