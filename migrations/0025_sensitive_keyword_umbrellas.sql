-- REM Atlas: fold sensitive keywords already saved into umbrella terms (decided 2026-11-03).
-- Run once in the Supabase SQL editor.
--
-- While the site is small, a specific word like "punch" could point to one person's dream, so
-- acts of violence become "violence", verbal aggression "conflict", and self-harm "distress".
-- New dreams are handled in src/lib/keywords/clusters.ts (keep the lists in step); public pages
-- also re-map on the way out. This tidies the keywords already stored.

create or replace function public.keyword_umbrella(k text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when k = any (array[
      'fight', 'fought', 'battle', 'brawl', 'attack', 'hit', 'punch', 'kick', 'slap', 'smack', 'beat', 'beaten',
      'thump', 'strike', 'struck', 'stab', 'shoot', 'shot', 'strangle', 'choke', 'murder', 'kill', 'killer',
      'torture', 'abuse', 'abuser', 'kidnap', 'abduct', 'assaulted', 'violent'
    ]) then 'violence'
    when k = any (array[
      'shout', 'yell', 'argue', 'argument', 'quarrel', 'insult', 'threaten', 'threat', 'bully', 'bullying',
      'harass', 'harassment', 'humiliate', 'berate', 'aggression', 'aggressive'
    ]) then 'conflict'
    when k = any (array['suicide', 'suicidal', 'selfharm', 'overdose']) then 'distress'
    else k
  end;
$$;
revoke all on function public.keyword_umbrella(text) from public, anon, authenticated;

-- Replace sensitive keywords, keeping the original order and dropping duplicates. Keyword-only
-- changes don't create edit-history entries or "edited" marks (migration 0013).
update public.dreams d
set keywords = (
  select coalesce(array_agg(x.kw order by x.first_seen), '{}')
  from (
    select public.keyword_umbrella(u.k) as kw, min(u.ord) as first_seen
    from unnest(d.keywords) with ordinality as u(k, ord)
    group by 1
  ) x
)
where exists (select 1 from unnest(d.keywords) as k where public.keyword_umbrella(k) <> k);
