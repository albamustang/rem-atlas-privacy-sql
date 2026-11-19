-- REM Atlas: Founder tier extras (CLAUDE.md section 8f).
-- Run once in the Supabase SQL editor, after 0014.
--
-- Founders can: be listed on a public Founders page (opt-in, with a name or organisation),
-- and send suggestions for the roadmap, which he reviews in the Supabase table editor
-- (set `status` and, optionally, `response`).

alter table profiles
  add column founder_name text check (char_length(founder_name) <= 60),
  add column founder_listed boolean not null default false;

-- Founder names are public, so they get the same unsuitable-words backstop as usernames.
create or replace function public.profiles_founder_name_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_unsuitable_text(new.founder_name) then
    raise exception 'founder name contains unsuitable words';
  end if;
  return new;
end;
$$;
create trigger profiles_founder_name_guard
  before insert or update of founder_name on profiles
  for each row execute function public.profiles_founder_name_guard();

-- Public Founders page: active founders who chose to be listed. No ids, no emails.
create view public_founders with (security_invoker = off) as
select p.founder_name, m.founding_number, m.updated_at as since
from profiles p
join memberships m on m.user_id = p.user_id
where m.tier = 'founder' and public.member_tier(p.user_id) = 'founder'
  and p.founder_listed and p.founder_name is not null;

revoke all on public_founders from anon, authenticated;
grant select on public_founders to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Suggestions from founders
-- ---------------------------------------------------------------------------
create table suggestions (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 10 and 2000),
  status text not null default 'new' check (status in ('new', 'reviewing', 'planned', 'done', 'declined')),
  response text check (char_length(response) <= 2000), -- his reply, shown to the founder
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index suggestions_user_idx on suggestions(user_id, created_at desc);

alter table suggestions enable row level security;
create policy "founders read own suggestions" on suggestions
  for select using (auth.uid() = user_id);
create policy "founders send suggestions" on suggestions
  for insert with check (auth.uid() = user_id and public.member_tier(auth.uid()) = 'founder');
grant select, insert (title, body) on suggestions to authenticated;

-- At most 5 suggestions per 30 days each, and only new ones from the founder themself.
create or replace function public.suggestions_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select count(*) from public.suggestions
      where user_id = new.user_id and created_at > now() - interval '30 days') >= 5 then
    raise exception 'suggestion limit reached' using errcode = 'P0429';
  end if;
  new.status := 'new';
  new.response := null;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;
create trigger suggestions_guard
  before insert on suggestions
  for each row execute function public.suggestions_guard();
