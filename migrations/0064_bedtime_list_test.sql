-- 0064: REM Labs housekeeping + "Lists before bed" (REM Labs experiment 3, sleep, decided 2026-11-15).
--
-- (1) Tomorrow's picture: the public hit count now waits for 5 different people, as Remember more
--     does, so a total can never be one person's score.
--
-- (2) "Lists before bed": does writing tomorrow's to-do list at bedtime help you fall asleep faster
--     than writing what you already did? A home, many-nights version of Scullin et al. 2018 (J Exp
--     Psychol Gen 147(1):139-146; PMID 29058942: 57 adults, 5 minutes of writing, between-person, in a
--     sleep lab). Here each person is their own control: each evening the database draws
--       todo = write a specific to-do list for the next few days, 5 minutes, on paper
--       done = write what you've done in the last few days, 5 minutes, on paper
--     The writing stays on paper: nothing written reaches us.
--   Outcome: "how long did it take to fall asleep" (sleep_nights.minutes_to_sleep, Consensus Sleep
--   Diary item) for that night. Night not logged or that question skipped = missing (reported by arm).
--   A night first logged less than 3 hours after its card was drawn is left out, as in 0063.
--   A "night" is the morning date the person logs under (sleep_nights.night = dreams.dream_date).
--   Locked by site_settings.list_test_live until it's preregistered (admins can pilot).

-- (1) ----------------------------------------------------------------------------------------------
create or replace function public.research_results()
returns table (trials bigint, hits bigint, people bigint, started bigint)
language sql stable security definer set search_path = '' as $$
  with t as (
    select count(*) filter (where ranked_at is not null) as trials,
           count(*) filter (where hit) as hits,
           count(distinct user_id) filter (where ranked_at is not null) as people,
           count(*) as started
    from public.research_trials
  )
  select trials, case when people >= 5 then hits else null end, people, started from t;
$$;
grant execute on function public.research_results() to anon, authenticated;

-- (2) ----------------------------------------------------------------------------------------------
insert into public.site_settings values ('list_test_live', false) on conflict (key) do nothing;

create table public.list_consent (
  user_id uuid primary key references auth.users(id) on delete cascade,
  version text not null check (char_length(version) <= 20),
  consented_at timestamptz not null default now(),
  over_18_confirmed_at timestamptz not null
);
create table public.list_trials (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  night date not null,
  arm text not null check (arm in ('todo', 'done')),
  assigned_at timestamptz not null default now(),
  unique (user_id, night)
);
alter table public.list_consent enable row level security;
alter table public.list_trials enable row level security;
create policy "owner reads own list consent" on public.list_consent for select using (auth.uid() = user_id);
create policy "owner reads own list nights" on public.list_trials for select using (auth.uid() = user_id);
grant select on public.list_consent, public.list_trials to authenticated;

create function public.list_test_open()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'list_test_live'), false) or public.is_site_admin();
$$;
grant execute on function public.list_test_open() to anon, authenticated;

create function public.join_list_test(over_18 boolean, consent_version text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not public.list_test_open() then raise exception 'not open yet' using errcode = 'P0001'; end if;
  if over_18 is not true then raise exception 'this experiment is for adults' using errcode = 'P0001'; end if;
  if consent_version is null or char_length(consent_version) > 20 then raise exception 'bad consent version' using errcode = 'P0001'; end if;
  insert into public.list_consent (user_id, version, over_18_confirmed_at) values (auth.uid(), consent_version, now())
  on conflict (user_id) do update set version = excluded.version, consented_at = now();
end $$;

create function public.leave_list_test(delete_nights boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  delete from public.list_consent where user_id = auth.uid();
  if delete_nights then delete from public.list_trials where user_id = auth.uid(); end if;
end $$;

-- Tonight's card: drawn once per night, refused once anything for that night is logged.
create function public.list_tonight(p_night date)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); a text;
begin
  if uid is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not public.list_test_open() then raise exception 'not open yet' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.list_consent c where c.user_id = uid) then raise exception 'join first' using errcode = 'P0001'; end if;
  if exists (select 1 from public.suspended_users s where s.user_id = uid) then raise exception 'not allowed' using errcode = 'P0001'; end if;
  if p_night is null or p_night < current_date or p_night > current_date + 2 then raise exception 'that night is not tonight' using errcode = 'P0001'; end if;
  select arm into a from public.list_trials where user_id = uid and night = p_night;
  if a is not null then return a; end if;
  if exists (select 1 from public.dreams d where d.user_id = uid and d.dream_date = p_night)
     or exists (select 1 from public.sleep_nights n where n.user_id = uid and n.night = p_night) then
    raise exception 'that night is already logged' using errcode = 'P0001';
  end if;
  a := case when get_byte(extensions.gen_random_bytes(1), 0) % 2 = 0 then 'todo' else 'done' end; -- 256 is even: no bias
  insert into public.list_trials (user_id, night, arm) values (uid, p_night, a);
  return a;
end $$;

-- Minutes to fall asleep for one person's night (null = not answered, not logged yet, or first
-- logged under 3 hours after the draw).
create function public.list_outcome(uid uuid, p_night date, drawn timestamptz)
returns int language sql stable security definer set search_path = '' as $$
  with first_log as (
    select least(
      (select min(d.created_at) from public.dreams d where d.user_id = uid and d.dream_date = p_night),
      (select min(n.created_at) from public.sleep_nights n where n.user_id = uid and n.night = p_night)) as at
  )
  select case
    when (select at from first_log) is null or (select at from first_log) < drawn + interval '3 hours' then null
    else (select n.minutes_to_sleep from public.sleep_nights n where n.user_id = uid and n.night = p_night) end;
$$;
revoke all on function public.list_outcome(uuid, date, timestamptz) from public, anon, authenticated;

-- Public totals per arm. Nights count once 2 days old; averages show only once 5 people have taken part.
create function public.list_results()
returns table (arm text, nights int, answered int, mean_minutes numeric, sd_minutes numeric, people int)
language sql stable security definer set search_path = '' as $$
  with t as (
    select r.user_id, r.arm, public.list_outcome(r.user_id, r.night, r.assigned_at) as m
    from public.list_trials r where r.night <= current_date - 2
  ), n as (select count(distinct user_id) as p from t)
  select a.arm, count(t.user_id)::int, count(t.m)::int,
         case when (select p from n) >= 5 then round(avg(t.m), 1) else null end,
         case when (select p from n) >= 5 then round(stddev_samp(t.m), 1) else null end,
         (select p from n)::int
  from (values ('todo'), ('done')) as a(arm)
  left join t on t.arm = a.arm
  group by a.arm order by a.arm desc;
$$;
grant execute on function public.list_results() to anon, authenticated;

-- Your own nights, per arm.
create function public.my_list_results()
returns table (arm text, nights int, answered int, mean_minutes numeric)
language sql stable security definer set search_path = '' as $$
  with t as (
    select r.arm, public.list_outcome(r.user_id, r.night, r.assigned_at) as m
    from public.list_trials r where r.user_id = auth.uid()
  )
  select a.arm, count(t.arm)::int, count(t.m)::int, round(avg(t.m), 1)
  from (values ('todo'), ('done')) as a(arm)
  left join t on t.arm = a.arm
  group by a.arm order by a.arm desc;
$$;

revoke all on function public.join_list_test(boolean, text), public.leave_list_test(boolean), public.list_tonight(date), public.my_list_results() from public, anon;
grant execute on function public.join_list_test(boolean, text), public.leave_list_test(boolean), public.list_tonight(date), public.my_list_results() to authenticated;
