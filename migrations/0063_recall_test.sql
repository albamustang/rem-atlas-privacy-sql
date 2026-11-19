-- 0063: "Remember more" (REM Labs experiment 2, decided 2026-11-12). Does setting an intention to
-- remember dreams at bedtime raise dream recall? Each person is their own control: every night they
-- open tonight's card, the database draws intention or plain sleep at random, before anything about
-- that night is known. Next morning's ordinary log is the outcome:
--   recalled     = a dream logged for that night, or a dawn fragment saved for it
--   not recalled = "no dream recalled" logged for that night
--   missing      = nothing logged (left out, and reported by arm)
-- A night logged less than 3 hours after its card was drawn is left out too (a card opened in the
-- morning could follow knowing the answer; the page only offers it in the evening).
-- A "night" is the morning date the dream is logged under (dreams.dream_date = sleep_nights.night).
-- Locked by site_settings.recall_test_live until it's preregistered (admins can pilot).

insert into public.site_settings values ('recall_test_live', false) on conflict (key) do nothing;

create table public.recall_consent (
  user_id uuid primary key references auth.users(id) on delete cascade,
  version text not null check (char_length(version) <= 20),
  consented_at timestamptz not null default now(),
  over_18_confirmed_at timestamptz not null
);
create table public.recall_trials (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  night date not null,
  arm text not null check (arm in ('intention', 'control')),
  assigned_at timestamptz not null default now(),
  unique (user_id, night)
);
alter table public.recall_consent enable row level security;
alter table public.recall_trials enable row level security;
create policy "owner reads own recall consent" on public.recall_consent for select using (auth.uid() = user_id);
create policy "owner reads own recall nights" on public.recall_trials for select using (auth.uid() = user_id);
grant select on public.recall_consent, public.recall_trials to authenticated;

create function public.recall_test_open()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'recall_test_live'), false) or public.is_site_admin();
$$;
grant execute on function public.recall_test_open() to anon, authenticated;

create function public.join_recall_test(over_18 boolean, consent_version text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not public.recall_test_open() then raise exception 'not open yet' using errcode = 'P0001'; end if;
  if over_18 is not true then raise exception 'this experiment is for adults' using errcode = 'P0001'; end if;
  if consent_version is null or char_length(consent_version) > 20 then raise exception 'bad consent version' using errcode = 'P0001'; end if;
  insert into public.recall_consent (user_id, version, over_18_confirmed_at) values (auth.uid(), consent_version, now())
  on conflict (user_id) do update set version = excluded.version, consented_at = now();
end $$;

-- Leave; optionally take your nights out of the results too.
create function public.leave_recall_test(delete_nights boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  delete from public.recall_consent where user_id = auth.uid();
  if delete_nights then delete from public.recall_trials where user_id = auth.uid(); end if;
end $$;

-- Tonight's card. p_night is the morning date the person will log under (worked out from their own
-- clock). Drawn once per night; asking again shows the same card. Refused once anything for that
-- night is logged, so the draw can never follow the outcome.
create function public.recall_tonight(p_night date)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); a text;
begin
  if uid is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not public.recall_test_open() then raise exception 'not open yet' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.recall_consent c where c.user_id = uid) then raise exception 'join first' using errcode = 'P0001'; end if;
  if exists (select 1 from public.suspended_users s where s.user_id = uid) then raise exception 'not allowed' using errcode = 'P0001'; end if;
  if p_night is null or p_night < current_date or p_night > current_date + 2 then raise exception 'that night is not tonight' using errcode = 'P0001'; end if;
  select arm into a from public.recall_trials where user_id = uid and night = p_night;
  if a is not null then return a; end if;
  if exists (select 1 from public.dreams d where d.user_id = uid and d.dream_date = p_night)
     or exists (select 1 from public.sleep_nights n where n.user_id = uid and n.night = p_night) then
    raise exception 'that night is already logged' using errcode = 'P0001';
  end if;
  a := case when get_byte(extensions.gen_random_bytes(1), 0) % 2 = 0 then 'intention' else 'control' end; -- 256 is even: no bias
  insert into public.recall_trials (user_id, night, arm) values (uid, p_night, a);
  return a;
end $$;

-- The outcome of one person's night (null = nothing logged yet, or logged under 3 hours after the draw).
create function public.recall_outcome(uid uuid, p_night date, drawn timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  with first_log as (
    select least(
      (select min(d.created_at) from public.dreams d where d.user_id = uid and d.dream_date = p_night),
      (select min(n.created_at) from public.sleep_nights n where n.user_id = uid and n.night = p_night)) as at
  )
  select case
    when (select at from first_log) is null or (select at from first_log) < drawn + interval '3 hours' then null
    when exists (select 1 from public.dreams d where d.user_id = uid and d.dream_date = p_night) then true
    when exists (select 1 from public.sleep_nights n where n.user_id = uid and n.night = p_night and n.fragment is not null) then true
    when exists (select 1 from public.sleep_nights n where n.user_id = uid and n.night = p_night and n.no_recall) then false
    else null end;
$$;
revoke all on function public.recall_outcome(uuid, date, timestamptz) from public, anon, authenticated;

-- Public totals per arm. Only nights at least 2 days old count (time to log), and recall rates
-- show only once 5 different people have taken part, so a rate can't point to one person.
create function public.recall_results()
returns table (arm text, nights int, logged int, recalled int, people int)
language sql stable security definer set search_path = '' as $$
  with t as (
    select r.user_id, r.arm, public.recall_outcome(r.user_id, r.night, r.assigned_at) as o
    from public.recall_trials r where r.night <= current_date - 2
  ), n as (select count(distinct user_id) as p from t)
  select a.arm, count(t.user_id)::int, count(t.o)::int,
         case when (select p from n) >= 5 then count(*) filter (where t.o)::int else null end,
         (select p from n)::int
  from (values ('intention'), ('control')) as a(arm)
  left join t on t.arm = a.arm
  group by a.arm order by a.arm desc;
$$;
grant execute on function public.recall_results() to anon, authenticated;

-- Your own nights, per arm.
create function public.my_recall_results()
returns table (arm text, nights int, logged int, recalled int)
language sql stable security definer set search_path = '' as $$
  select a.arm, count(r.id)::int,
         count(public.recall_outcome(r.user_id, r.night, r.assigned_at))::int,
         count(*) filter (where public.recall_outcome(r.user_id, r.night, r.assigned_at))::int
  from (values ('intention'), ('control')) as a(arm)
  left join public.recall_trials r on r.arm = a.arm and r.user_id = auth.uid()
  group by a.arm order by a.arm desc;
$$;

revoke all on function public.join_recall_test(boolean, text), public.leave_recall_test(boolean), public.recall_tonight(date), public.my_recall_results() from public, anon;
grant execute on function public.join_recall_test(boolean, text), public.leave_recall_test(boolean), public.recall_tonight(date), public.my_recall_results() to authenticated;
