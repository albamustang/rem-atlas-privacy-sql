-- REM Atlas: private dreams leave the database only as counts, in groups big enough not to
-- point to anyone (decided 2026-11-03). Run once in the Supabase SQL editor.
--
-- Until now public_dreams listed every dream, private ones included (without their text): city,
-- night, emotion, category and keywords, one row each. While most places have one dreamer, that
-- could point to a person. From now on:
--   * public_dreams lists public dreams only (the dreamer chose to share those);
--   * the map, keyword list and site totals come from atlas_counts(), which counts every dream
--     but shows a place or keyword only once at least 3 different people are in it. Quieter
--     cities are grouped into their country (if that group has 3+ people) or left off the map;
--   * dream-profile comparisons come from profile_comparison(): each group needs 30+ dreams from
--     5+ other people, and a smaller group inside a bigger one (your city inside your country)
--     is shown only if what's left over is empty or also 5+ people, so one can't be subtracted
--     from the other to single someone out;
--   * founders' research downloads come from research_counts(): groups of 10+ dreams from 3+
--     people.
-- Keep the numbers in step with src/lib/atlas-options.ts (MIN_DREAMERS), src/lib/dream-profile.ts
-- (MIN_COMPARISON_DREAMS, MIN_COMPARISON_PEOPLE) and src/lib/research-data.ts (MIN_GROUP,
-- MIN_GROUP_PEOPLE).

-- Public dreams only. Same columns as before (migration 0014), so nothing else changes.
create or replace view public.public_dreams with (security_invoker = off) as
select d.id,
       case when d.is_explicit then null else d.public_description end as description,
       d.emotion, d.category, d.clarity, d.city_id, d.dream_date, d.keywords,
       d.is_explicit,
       d.edited_at,
       case when p.show_username_on_dreams and not d.is_explicit then p.username end as username,
       case when p.show_username_on_dreams and not d.is_explicit then p.avatar_seed end as avatar_seed,
       case when p.show_username_on_dreams and not d.is_explicit then p.avatar_pixels end as avatar_pixels,
       case when p.show_username_on_dreams and not d.is_explicit then public.member_tier(d.user_id) end as member_tier
from public.dreams d
left join public.profiles p on p.user_id = d.user_id
where not d.is_private;

-- The atlas: totals for a window of nights (p_from null = since the start), the keyword list,
-- and dreams per place, optionally only those mentioning p_keyword.
create or replace function public.atlas_counts(p_from date, p_to date, p_keyword text default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with win as (
    select d.user_id, d.dream_date, d.keywords, d.city_id, c.country
    from public.dreams d
    left join public.cities c on c.id = d.city_id
    where d.dream_date <= coalesce(p_to, current_date)
      and (p_from is null or d.dream_date >= p_from)
  ),
  -- Keywords mentioned by at least 3 people in the window.
  kw as (
    select u.k as keyword, count(*) as dreams
    from win w
    cross join lateral (select distinct k from unnest(w.keywords) as k) u
    group by u.k
    having count(distinct w.user_id) >= 3
  ),
  allowed as (
    select p_keyword is null or exists (select 1 from kw where kw.keyword = p_keyword) as ok
  ),
  hit as (
    select w.* from win w, allowed a
    where a.ok and (p_keyword is null or p_keyword = any (w.keywords))
  ),
  -- Cities with dreams from at least 3 people...
  city_groups as (
    select h.city_id, count(*) as dreams
    from hit h
    where h.city_id is not null
    group by h.city_id
    having count(distinct h.user_id) >= 3
  ),
  -- ...and the rest grouped by country, again only with at least 3 people.
  country_groups as (
    select h.country, count(*) as dreams
    from hit h
    where h.country is not null and h.city_id not in (select g.city_id from city_groups g)
    group by h.country
    having count(distinct h.user_id) >= 3
  ),
  places as (
    select 'city' as level, c.name, c.region, c.country, c.lat, c.lon, g.dreams
    from city_groups g
    join public.cities c on c.id = g.city_id
    union all
    -- A country group sits at the population-weighted middle of the country's cities, so its
    -- position says nothing about where in the country the dreamers are.
    select 'country', null, null, g.country, ctr.lat, ctr.lon, g.dreams
    from country_groups g
    cross join lateral (
      select sum(c.lat * greatest(c.population, 1)) / sum(greatest(c.population, 1)) as lat,
             sum(c.lon * greatest(c.population, 1)) / sum(greatest(c.population, 1)) as lon
      from public.cities c
      where c.country = g.country
    ) ctr
  )
  select jsonb_build_object(
    'dreams', (select count(*) from win),
    'cities', (select count(distinct city_id) from win),
    'nights', (select count(distinct dream_date) from win),
    'keyword_shown', (select ok from allowed),
    'matching', (select count(*) from hit),
    'keywords', coalesce(
      (select jsonb_agg(jsonb_build_object('keyword', keyword, 'dreams', dreams) order by dreams desc, keyword) from kw),
      '[]'::jsonb),
    'places', coalesce(
      (select jsonb_agg(jsonb_build_object(
         'level', level, 'name', name, 'region', region, 'country', country, 'lat', lat, 'lon', lon, 'dreams', dreams
       ) order by dreams desc, country, name) from places),
      '[]'::jsonb)
  );
$$;
revoke all on function public.atlas_counts(date, date, text) from public;
grant execute on function public.atlas_counts(date, date, text) to anon, authenticated;

-- Dream profile comparisons: other people's emotions, categories and (for p_keywords) keywords
-- over the profile's window (p_days 90 or 365, or null for all time), for everyone, the
-- signed-in person's country and city. Groups too small to show are left out.
create or replace function public.profile_comparison(p_days int, p_country text, p_city_id int, p_keywords text[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with others as (
    select d.user_id, d.emotion, d.category, d.keywords, d.city_id, c.country
    from public.dreams d
    left join public.cities c on c.id = d.city_id
    where auth.uid() is not null
      and (p_days is null or p_days in (90, 365))
      and d.user_id <> auth.uid()
      and d.dream_date <= current_date
      and (p_days is null or d.dream_date > current_date - p_days)
  ),
  scoped as (
    select 'everyone' as scope, o.* from others o
    union all
    select 'region', o.* from others o where o.country = p_country
    union all
    select 'city', o.* from others o where o.country = p_country and o.city_id = p_city_id
  ),
  sizes as (
    select s.scope, count(*) as dreams, count(distinct s.user_id) as people
    from scoped s
    group by s.scope
  ),
  -- People left over when the smaller group is taken out of the bigger one.
  leftover as (
    select
      (select count(distinct o.user_id) from others o where o.country is distinct from p_country) as outside_region,
      (select count(distinct o.user_id) from others o
        where o.country = p_country and o.city_id is distinct from p_city_id) as outside_city
  ),
  flags as (
    select
      coalesce(e.dreams >= 30 and e.people >= 5, false) as everyone_ok,
      coalesce(r.dreams >= 30 and r.people >= 5, false)
        and (l.outside_region = 0 or l.outside_region >= 5) as region_ok,
      coalesce(c.dreams >= 30 and c.people >= 5, false)
        and (l.outside_city = 0 or l.outside_city >= 5) as city_ok
    from leftover l
    left join sizes e on e.scope = 'everyone'
    left join sizes r on r.scope = 'region'
    left join sizes c on c.scope = 'city'
  ),
  shown as (
    select 'everyone' as scope from flags where everyone_ok
    union all
    select 'region' from flags where everyone_ok and region_ok
    union all
    select 'city' from flags where everyone_ok and region_ok and city_ok
  )
  select jsonb_build_object(
    'others_dreams', coalesce((select z.dreams from sizes z where z.scope = 'everyone'), 0),
    'groups', coalesce((
      select jsonb_object_agg(sh.scope, jsonb_build_object(
        'dreams', (select z.dreams from sizes z where z.scope = sh.scope),
        'emotions', (
          select coalesce(jsonb_object_agg(x.emotion, x.n), '{}'::jsonb)
          from (select s.emotion, count(*) as n from scoped s where s.scope = sh.scope group by s.emotion) x),
        'categories', (
          select coalesce(jsonb_object_agg(x.category, x.n), '{}'::jsonb)
          from (select s.category, count(*) as n from scoped s where s.scope = sh.scope group by s.category) x),
        'keywords', (
          select coalesce(jsonb_object_agg(x.k, x.n), '{}'::jsonb)
          from (
            select u.k, count(*) as n
            from scoped s
            cross join lateral (select distinct k from unnest(s.keywords) as k) u
            where s.scope = sh.scope and u.k = any (coalesce(p_keywords[1:20], '{}'))
            group by u.k
          ) x)
      ))
      from shown sh
    ), '{}'::jsonb)
  );
$$;
revoke all on function public.profile_comparison(int, text, int, text[]) from public, anon;
grant execute on function public.profile_comparison(int, text, int, text[]) to authenticated;

-- Founders' research downloads (CLAUDE.md 8f): counts per group, only groups of 10+ dreams from
-- 3+ people. Nothing for anyone who isn't a founder.
create or replace function public.research_counts(p_dataset text)
returns table (key text[], dreams bigint)
language sql
stable
security definer
set search_path = ''
as $$
  with base as (
    select d.user_id, to_char(d.dream_date, 'YYYY-MM') as month, coalesce(c.country, 'unknown') as country,
           d.emotion, d.category, d.keywords
    from public.dreams d
    left join public.cities c on c.id = d.city_id
    where public.member_tier(auth.uid()) = 'founder'
  ),
  grouped as (
    select array[b.country, b.month] as k, b.user_id from base b where p_dataset = 'dreams-by-country'
    union all
    select array[u.kw, b.country, b.month], b.user_id
    from base b
    cross join lateral (select distinct kw from unnest(b.keywords) as kw) u
    where p_dataset = 'keywords-by-country'
    union all
    select array[b.emotion, b.country, b.month], b.user_id from base b where p_dataset = 'emotions-by-country'
    union all
    select array[b.category, b.month], b.user_id from base b where p_dataset = 'categories-by-month'
  )
  select g.k, count(*)
  from grouped g
  group by g.k
  having count(*) >= 10 and count(distinct g.user_id) >= 3;
$$;
revoke all on function public.research_counts(text) from public, anon;
grant execute on function public.research_counts(text) to authenticated;
