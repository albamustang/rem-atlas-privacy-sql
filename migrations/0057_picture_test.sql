-- REM Atlas: "Tomorrow's picture", a precognitive dream test (plan: docs/parapsychology-plan.md part 2;
-- his decisions 2026-11-09/10: house-style pictures, free for everyone, one entry per night).
--
-- How a trial runs, in this order, enforced here:
--   1. The person has logged a dream (its text is saved and dated).
--   2. They enter it: the dream's text is locked (no more edits) and fingerprinted, and a random set of
--      four pictures is chosen and shown in a random order.
--   3. They rank the four from most to least like their dream.
--   4. Only then does the database draw the target, one of the four, with a cryptographic random
--      number. A "hit" is the target ranked first (chance: 1 in 4).
-- The target does not exist until the ranking is saved, so nothing about it can leak or be gamed.
-- Results are published as totals only (research_results()). Off for the public until
-- site_settings 'picture_test_live' is true; admins can always take part (for the pilot).

create extension if not exists pgcrypto with schema extensions;

insert into public.site_settings (key, value) values ('picture_test_live', false)
on conflict (key) do nothing;

create table if not exists public.research_consent (
  user_id uuid primary key references auth.users(id) on delete cascade,
  version text not null, -- which consent text they agreed to
  over_18_confirmed_at timestamptz not null,
  consented_at timestamptz not null default now()
);

-- The picture sets: four very different scenes each, painted once (research/<id>-<n>.webp in the
-- private pictures bucket). Only sets with all four paintings are used.
create table if not exists public.research_sets (
  id int primary key,
  ready boolean not null default false
);
insert into public.research_sets (id) select generate_series(1, 40) on conflict (id) do nothing;

create table if not exists public.research_trials (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  dream_id uuid references public.dreams(id) on delete set null, -- the trial outlives a deleted dream; no text is kept
  night date not null,
  dream_hash text not null, -- sha256 of the dream text at entry
  set_id int not null references public.research_sets(id),
  shown smallint[] not null, -- picture numbers (0-3) in the order they were shown
  ranks smallint[], -- rank (1-4) given to picture 0, 1, 2, 3
  target smallint, -- picture number drawn after ranking
  hit boolean,
  started_at timestamptz not null default now(),
  ranked_at timestamptz,
  unique (user_id, night)
);
create index if not exists research_trials_ranked_idx on public.research_trials (ranked_at) where ranked_at is not null;

alter table public.research_consent enable row level security;
alter table public.research_sets enable row level security;
alter table public.research_trials enable row level security;
create policy "owner reads own consent" on public.research_consent for select using (auth.uid() = user_id);
create policy "owner reads own trials" on public.research_trials for select using (auth.uid() = user_id);
grant select on public.research_consent, public.research_trials to authenticated;
revoke insert, update, delete on public.research_consent, public.research_trials, public.research_sets from anon, authenticated;
grant select, update on public.research_sets to service_role; -- the admin painting page marks sets ready
grant select on public.research_trials, public.research_consent to service_role;

create or replace function public.picture_test_open()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'picture_test_live'), false)
         or exists (select 1 from public.site_admins a where a.user_id = auth.uid());
$$;
grant execute on function public.picture_test_open() to anon, authenticated;

create or replace function public.join_picture_test(over_18 boolean, consent_version text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  if over_18 is not true then raise exception 'the picture test is 18+' using errcode = 'P0001'; end if;
  if consent_version is null or length(consent_version) > 20 then raise exception 'bad consent version' using errcode = 'P0001'; end if;
  insert into public.research_consent (user_id, version, over_18_confirmed_at)
  values (auth.uid(), consent_version, now())
  on conflict (user_id) do update set version = excluded.version, consented_at = now();
end;
$$;
revoke all on function public.join_picture_test(boolean, text) from public, anon;
grant execute on function public.join_picture_test(boolean, text) to authenticated;

-- Leave the test; optionally delete every trial too (otherwise finished trials stay in the totals).
create or replace function public.leave_picture_test(delete_trials boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  delete from public.research_consent where user_id = auth.uid();
  if delete_trials then delete from public.research_trials where user_id = auth.uid(); end if;
end;
$$;
revoke all on function public.leave_picture_test(boolean) from public, anon;
grant execute on function public.leave_picture_test(boolean) to authenticated;

-- Steps 2: enter a dream. Fresh dreams only (logged in the last 36 hours), one per night.
create or replace function public.start_picture_trial(p_dream uuid)
returns table (trial_id uuid, set_id int, shown smallint[])
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  d record;
  s int;
  order_ smallint[];
  t uuid;
begin
  if uid is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not public.picture_test_open() then raise exception 'the picture test is not open yet' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.research_consent where user_id = uid) then raise exception 'join the picture test first' using errcode = 'P0001'; end if;
  select id, dream_date, description, created_at into d from public.dreams where id = p_dream and user_id = uid;
  if not found then raise exception 'dream not found' using errcode = 'P0001'; end if;
  if d.created_at < now() - interval '36 hours' then raise exception 'only dreams logged in the last 36 hours' using errcode = 'P0001'; end if;
  if exists (select 1 from public.research_trials where user_id = uid and night = d.dream_date) then
    raise exception 'one entry per night' using errcode = 'P0001';
  end if;
  select r.id into s from public.research_sets r where r.ready order by random() limit 1;
  if s is null then raise exception 'no picture sets are ready' using errcode = 'P0001'; end if;
  select array_agg(n order by random())::smallint[] into order_ from generate_series(0, 3) n;
  insert into public.research_trials (user_id, dream_id, night, dream_hash, set_id, shown)
  values (uid, d.id, d.dream_date, encode(extensions.digest(d.description, 'sha256'), 'hex'), s, order_)
  returning id into t;
  return query select t, s, order_;
end;
$$;
revoke all on function public.start_picture_trial(uuid) from public, anon;
grant execute on function public.start_picture_trial(uuid) to authenticated;

-- Steps 3 and 4: save the ranking, then draw the target. Ranks are given per picture number (0-3).
create or replace function public.rank_picture_trial(p_trial uuid, p_ranks smallint[])
returns table (target smallint, hit boolean)
language plpgsql security definer set search_path = '' as $$
declare
  tr record;
  tg smallint;
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  select * into tr from public.research_trials where id = p_trial and user_id = auth.uid() for update;
  if not found then raise exception 'trial not found' using errcode = 'P0001'; end if;
  if tr.ranks is not null then raise exception 'already ranked' using errcode = 'P0001'; end if;
  if p_ranks is null or array_length(p_ranks, 1) <> 4
     or (select array_agg(x order by x) from unnest(p_ranks) x) <> '{1,2,3,4}'::smallint[] then
    raise exception 'rank each picture 1 to 4 once' using errcode = 'P0001';
  end if;
  tg := get_byte(extensions.gen_random_bytes(1), 0) % 4; -- 256 is a multiple of 4: no bias
  update public.research_trials
  set ranks = p_ranks, target = tg, hit = (p_ranks[tg + 1] = 1), ranked_at = now()
  where id = p_trial;
  return query select tg, p_ranks[tg + 1] = 1;
end;
$$;
revoke all on function public.rank_picture_trial(uuid, smallint[]) from public, anon;
grant execute on function public.rank_picture_trial(uuid, smallint[]) to authenticated;

-- An entered dream's text is locked: the fingerprint must keep matching what was entered.
create or replace function public.dreams_picture_lock()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.description is distinct from old.description
     and exists (select 1 from public.research_trials where dream_id = old.id) then
    raise exception 'this dream is in the picture test, so its words are locked' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.dreams_picture_lock() from public, anon, authenticated;
drop trigger if exists dreams_picture_lock on public.dreams;
create trigger dreams_picture_lock before update of description on public.dreams
  for each row execute function public.dreams_picture_lock();

-- The public running total: finished trials, hits, people. Never anything per person.
create or replace function public.research_results()
returns table (trials bigint, hits bigint, people bigint, started bigint)
language sql stable security definer set search_path = '' as $$
  select count(*) filter (where ranked_at is not null),
         count(*) filter (where hit),
         count(distinct user_id) filter (where ranked_at is not null),
         count(*)
  from public.research_trials;
$$;
grant execute on function public.research_results() to anon, authenticated;
