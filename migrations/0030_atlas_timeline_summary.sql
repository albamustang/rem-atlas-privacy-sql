-- REM Atlas: counts for the atlas timeline strip and "at a glance" panel (2026-11-03).
-- Run once in the Supabase SQL editor.
--
-- Same rule as migration 0029: private dreams leave the database only as counts, and only in
-- groups big enough not to point to anyone (CLAUDE.md section 9, "small-group floor").

-- Dreams per night between two dates (at most 400 nights), for the timeline strip. Without a
-- keyword these are plain totals (they say someone logged a dream that night, nothing about
-- it). With a keyword, a night is listed only if at least 3 different people mentioned it, so a
-- quiet night looks the same as an empty one.
create or replace function public.atlas_nights(p_from date, p_to date, p_keyword text default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('night', n.night, 'dreams', n.dreams) order by n.night), '[]'::jsonb)
  from (
    select d.dream_date as night, count(*) as dreams
    from public.dreams d
    where p_from is not null and p_to is not null and p_to - p_from between 0 and 400
      and d.dream_date between p_from and p_to
      and (p_keyword is null or p_keyword = any (d.keywords))
    group by d.dream_date
    having p_keyword is null or count(distinct d.user_id) >= 3
  ) n;
$$;
revoke all on function public.atlas_nights(date, date, text) from public;
grant execute on function public.atlas_nights(date, date, text) to anon, authenticated;

-- Emotions, categories and clarity of the dreams in a window (p_from null = since the start),
-- optionally only those mentioning p_keyword, for the "at a glance" panel. Null unless the
-- window has at least 30 dreams from at least 5 people (the dream-profile comparison floor).
create or replace function public.atlas_summary(p_from date, p_to date, p_keyword text default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with hit as (
    select d.user_id, d.emotion, d.category, d.clarity
    from public.dreams d
    where d.dream_date <= coalesce(p_to, current_date)
      and (p_from is null or d.dream_date >= p_from)
      and (p_keyword is null or p_keyword = any (d.keywords))
  ),
  size as (
    select count(*) as dreams, count(distinct user_id) as people from hit
  )
  select case when s.dreams >= 30 and s.people >= 5 then jsonb_build_object(
    'dreams', s.dreams,
    'emotions', (select coalesce(jsonb_object_agg(x.emotion, x.n), '{}'::jsonb)
                 from (select h.emotion, count(*) as n from hit h group by h.emotion) x),
    'categories', (select coalesce(jsonb_object_agg(x.category, x.n), '{}'::jsonb)
                   from (select h.category, count(*) as n from hit h group by h.category) x),
    'clarity', (select coalesce(jsonb_object_agg(x.clarity, x.n), '{}'::jsonb)
                from (select h.clarity, count(*) as n from hit h group by h.clarity) x)
  ) end
  from size s;
$$;
revoke all on function public.atlas_summary(date, date, text) from public;
grant execute on function public.atlas_summary(date, date, text) to anon, authenticated;
