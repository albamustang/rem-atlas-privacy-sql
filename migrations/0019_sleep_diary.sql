-- REM Atlas: sleep diary questions and "no dream recalled" nights (CLAUDE.md section 8i).
-- Run once in the Supabase SQL editor.
--
-- One row per person per night, kept apart from dreams: sleep details are health data, so
-- they are only ever visible to their owner, never public, never sent to AI.
-- The questions are five of the core items of the Consensus Sleep Diary (Carney et al., 2012),
-- all optional. A night logged as "no dream recalled" counts towards consistency awards just
-- like a dream, so nobody feels pushed to invent a dream to keep a streak.

create table sleep_nights (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  night date not null check (night <= current_date + 1),
  no_recall boolean not null default false, -- logged as "no dream recalled"
  tried_to_sleep time,                      -- what time did you try to go to sleep?
  minutes_to_sleep int check (minutes_to_sleep between 0 and 720), -- how long to fall asleep?
  awakenings int check (awakenings between 0 and 50), -- times woken, not counting the final time
  final_wake time,                          -- time of final awakening
  quality smallint check (quality between 1 and 5), -- 1 very poor ... 5 very good
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, night)
);

alter table sleep_nights enable row level security;
create policy "owner reads own nights" on sleep_nights for select using (auth.uid() = user_id);
create policy "owner logs own nights" on sleep_nights for insert with check (auth.uid() = user_id);
create policy "owner edits own nights" on sleep_nights for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner deletes own nights" on sleep_nights for delete using (auth.uid() = user_id);
grant select, insert, update, delete on sleep_nights to authenticated;

-- The "logged at" time always comes from the database clock, never from the request, so
-- nights can't be backdated to earn awards. (Dreams get the same rule below.)
create or replace function public.stamp_created_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
  end if;
  if tg_table_name = 'sleep_nights' then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger sleep_nights_stamp
  before insert or update on sleep_nights
  for each row execute function public.stamp_created_at();

create trigger dreams_stamp_created_at
  before insert on dreams
  for each row execute function public.stamp_created_at();

-- Awards now count nights with a dream OR a sleep_nights row, logged on time (by midnight UTC
-- at the end of the day after the night). Same codes and numbers as migration 0007 (and
-- src/lib/achievements.ts).
create or replace function public.counted_nights(uid uuid)
returns setof date
language sql
stable
security definer
set search_path = ''
as $$
  select dream_date from public.dreams
  where user_id = uid and created_at < ((dream_date + 2)::timestamp at time zone 'UTC')
  union
  select night from public.sleep_nights
  where user_id = uid and created_at < ((night + 2)::timestamp at time zone 'UTC');
$$;
revoke all on function public.counted_nights(uuid) from public, anon, authenticated;

create or replace function public.award_achievements(uid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tier record;
  nights date[];
begin
  select coalesce(array_agg(n), '{}') into nights from public.counted_nights(uid) as n;

  -- Consistency: at least `need` counted nights within some run of `days` consecutive nights.
  for tier in select * from (values ('steady_7', 5, 7), ('steady_14', 10, 14), ('steady_28', 20, 28)) as t(code, need, days)
  loop
    if exists (
      select 1 from unnest(nights) as e(night)
      where (select count(*) from unnest(nights) as n(night)
             where n.night between e.night - (tier.days - 1) and e.night) >= tier.need
    ) then
      insert into public.user_achievements (user_id, code) values (uid, tier.code) on conflict do nothing;
    end if;
  end loop;

  -- Milestones: total counted nights.
  for tier in select * from (values ('nights_1', 1), ('nights_30', 30), ('nights_100', 100), ('nights_365', 365)) as t(code, need)
  loop
    if cardinality(nights) >= tier.need then
      insert into public.user_achievements (user_id, code) values (uid, tier.code) on conflict do nothing;
    end if;
  end loop;
end;
$$;
revoke all on function public.award_achievements(uuid) from public, anon, authenticated;

-- The existing dreams trigger function (0007) works for this table too: it only uses user_id.
create trigger sleep_nights_award_achievements
  after insert or update on sleep_nights
  for each row execute function public.dreams_award_achievements();
