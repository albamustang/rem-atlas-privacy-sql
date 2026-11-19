-- REM Atlas: one paid plan (CLAUDE.md section 8n, step 1). Run once in the Supabase SQL editor.
--
-- Supporter, Scholar and Founder become two tiers:
--   member  (£6 a month or £48 a year): everything, including the Academy courses
--   patron  (£25 a month or £250 a year): everything, plus suggestions, research downloads,
--           the quarterly briefing and the optional public listing
-- Nobody has a live membership (the table was cleared in 0033 and his purchase was refunded), so
-- the update below is a formality. Founding numbers are unchanged: the first 100 members keep one.

-- The old check must go before any row is renamed, or the rename is refused.
alter table memberships drop constraint memberships_tier_check;
update memberships set tier = 'member' where tier in ('supporter', 'scholar');
update memberships set tier = 'patron' where tier = 'founder';
alter table memberships add constraint memberships_tier_check check (tier in ('member', 'patron'));

-- Academy courses and exams are part of every membership now.
create or replace function public.has_academy(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.member_tier(uid) is not null;
$$;

-- The public listing (still at /founders) is for patrons.
create or replace view public_founders with (security_invoker = off) as
select p.founder_name, m.founding_number, m.updated_at as since
from profiles p
join memberships m on m.user_id = p.user_id
where m.tier = 'patron' and public.member_tier(p.user_id) = 'patron'
  and p.founder_listed and p.founder_name is not null;

-- Suggestions are for patrons.
drop policy "founders send suggestions" on suggestions;
create policy "patrons send suggestions" on suggestions
  for insert with check (auth.uid() = user_id and public.member_tier(auth.uid()) = 'patron');

-- Research downloads are for patrons. Same counting and small-group rules as 0029.
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
    where public.member_tier(auth.uid()) = 'patron'
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
