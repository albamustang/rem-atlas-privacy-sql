-- REM Atlas: Supporter tools, phase 1 (docs/membership-benefits-proposal.md: J2, J5, J6, A2).
-- Run once in the Supabase SQL editor.
--
-- Private titles and tags on dreams, and saved searches. All private to the owner: the public
-- views list their columns one by one, so these never appear on the atlas or profiles.
-- Adding a title or tags needs a membership (checked here, not just on the page); anyone can
-- remove them, so nothing is stuck if a membership ends.

alter table dreams
  add column title text check (title is null or char_length(title) between 1 and 80),
  add column tags text[] not null default '{}' check (cardinality(tags) <= 10);
create index dreams_tags_idx on dreams using gin (tags);

create or replace function public.dreams_member_extras_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  t text;
  adding boolean;
begin
  foreach t in array new.tags loop
    if t !~ '^[a-z0-9][a-z0-9-]{0,23}$' then
      raise exception 'tags are lowercase words or numbers joined by hyphens, up to 24 characters' using errcode = '22023';
    end if;
  end loop;

  if tg_op = 'INSERT' then
    adding := new.title is not null or cardinality(new.tags) > 0;
  else
    adding := (new.title is not null and new.title is distinct from old.title)
           or (cardinality(new.tags) > 0 and new.tags is distinct from old.tags
               and not (new.tags <@ old.tags)); -- removing tags is always allowed
  end if;
  if adding and public.member_tier(new.user_id) is null then
    raise exception 'titles and tags are a supporter feature' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger dreams_member_extras_guard
  before insert or update on dreams
  for each row execute function public.dreams_member_extras_guard();

-- Saved searches on My dreams: a name and the search, members only, up to 20 each.
create table saved_searches (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  query text not null check (char_length(query) <= 500),
  created_at timestamptz not null default now()
);
create index saved_searches_user_idx on saved_searches(user_id);

alter table saved_searches enable row level security;
create policy "owner reads own searches" on saved_searches for select using (auth.uid() = user_id);
create policy "members save searches" on saved_searches
  for insert with check (auth.uid() = user_id and public.member_tier(auth.uid()) is not null);
create policy "owner deletes own searches" on saved_searches for delete using (auth.uid() = user_id);
grant select, insert, delete on saved_searches to authenticated;

create or replace function public.saved_searches_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select count(*) from public.saved_searches where user_id = new.user_id) >= 20 then
    raise exception 'you can keep up to 20 saved searches' using errcode = 'P0429';
  end if;
  return new;
end;
$$;
create trigger saved_searches_limit
  before insert on saved_searches
  for each row execute function public.saved_searches_limit();
