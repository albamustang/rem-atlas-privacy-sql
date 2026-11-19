-- Keyword views of the atlas: colour by over-representation, not by where most users live.
-- Same counts and same 3-person floors as 0029; each place gains `lift`. Keep the numbers in step
-- with src/lib/atlas-options.ts.
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
    select 'city' as level, c.name, c.region, c.country, c.lat, c.lon, g.dreams,
      (select count(*) from win w where w.city_id = g.city_id) as place_total
    from city_groups g
    join public.cities c on c.id = g.city_id
    union all
    -- A country group sits at the population-weighted middle of the country's cities, so its
    -- position says nothing about where in the country the dreamers are.
    select 'country', null, null, g.country, ctr.lat, ctr.lon, g.dreams,
      (select count(*) from win w where w.country = g.country and w.city_id not in (select cg.city_id from city_groups cg))
    from country_groups g
    cross join lateral (
      select sum(c.lat * greatest(c.population, 1)) / sum(greatest(c.population, 1)) as lat,
             sum(c.lon * greatest(c.population, 1)) / sum(greatest(c.population, 1)) as lon
      from public.cities c
      where c.country = g.country
    ) ctr
  ),
  -- The keyword's share of all dreams in the window.
  overall as (
    select (select count(*) from hit)::numeric / nullif((select count(*) from win), 0) as share
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
         'level', level, 'name', name, 'region', region, 'country', country, 'lat', lat, 'lon', lon, 'dreams', dreams,
         -- Lift: 1 = as common here as everywhere. Pulled towards 1 by 20 imaginary average dreams,
         -- and left out for small samples. Rounded, and the place's total isn't returned.
         'lift', case when p_keyword is not null and dreams >= 5 and place_total >= 30 then
           (select round(((dreams + 20 * o.share) / (place_total + 20)) / nullif(o.share, 0), 1) from overall o)
         end
       ) order by dreams desc, country, name) from places),
      '[]'::jsonb)
  );
$$;
revoke all on function public.atlas_counts(date, date, text) from public;
grant execute on function public.atlas_counts(date, date, text) to anon, authenticated;
