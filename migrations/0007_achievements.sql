-- REM Atlas: achievements (consistency milestones, CLAUDE.md section 8c).
-- Run once in the Supabase SQL editor.
--
-- Awards are worked out by the database whenever a dream is saved, and nobody can
-- write them directly, so they can't be faked. Once earned, an award is kept.
--
-- Only "counted nights" earn awards: dreams logged by the end of the day after the
-- night they happened. Dreams logged later still count fully as data; this just stops
-- someone backfilling a month of nights in one sitting.
-- Keep the codes and numbers in step with src/lib/achievements.ts.

create table user_achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  code text not null,
  earned_at timestamptz not null default now(),
  primary key (user_id, code)
);

alter table user_achievements enable row level security;
create policy "owner reads own achievements" on user_achievements
  for select using (auth.uid() = user_id);
grant select on user_achievements to authenticated;

create or replace function public.award_achievements(uid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tier record;
  total int;
begin
  -- Counted nights: logged before midnight UTC at the end of the day after the night.
  select count(distinct dream_date) into total from public.dreams
  where user_id = uid and created_at < ((dream_date + 2)::timestamp at time zone 'UTC');

  -- Consistency: at least `need` counted nights within some run of `days` consecutive nights.
  for tier in select * from (values ('steady_7', 5, 7), ('steady_14', 10, 14), ('steady_28', 20, 28)) as t(code, need, days)
  loop
    if exists (
      with nights as (
        select distinct dream_date as night from public.dreams
        where user_id = uid and created_at < ((dream_date + 2)::timestamp at time zone 'UTC')
      )
      select 1 from nights e
      where (select count(*) from nights n
             where n.night between e.night - (tier.days - 1) and e.night) >= tier.need
    ) then
      insert into public.user_achievements (user_id, code) values (uid, tier.code) on conflict do nothing;
    end if;
  end loop;

  -- Milestones: total counted nights.
  for tier in select * from (values ('nights_1', 1), ('nights_30', 30), ('nights_100', 100), ('nights_365', 365)) as t(code, need)
  loop
    if total >= tier.need then
      insert into public.user_achievements (user_id, code) values (uid, tier.code) on conflict do nothing;
    end if;
  end loop;
end;
$$;

-- Nobody calls this directly; only the trigger below does.
revoke all on function public.award_achievements(uuid) from public, anon, authenticated;

create or replace function public.dreams_award_achievements()
returns trigger
language plpgsql
security definer -- runs as the owner, so it may call award_achievements
set search_path = ''
as $$
begin
  perform public.award_achievements(new.user_id);
  return null;
end;
$$;

create trigger dreams_award_achievements
  after insert or update on dreams
  for each row execute function public.dreams_award_achievements();

-- Award anything already earned by dreams logged before this migration.
select public.award_achievements(user_id) from (select distinct user_id from dreams) as u;
