-- REM Atlas: editing dreams, with an edit history (CLAUDE.md section 8b).
-- Run once in the Supabase SQL editor.
--
-- Every change to a dream saves a copy of the previous version in dream_revisions.
-- The database does this itself, so no edit can skip it. Only the owner can read the
-- history; the public only sees an "edited" date, and only when the content changed
-- (making a dream private or public is recorded, but isn't shown as an edit).

alter table dreams add column edited_at timestamptz;

create table dream_revisions (
  id bigint generated always as identity primary key,
  dream_id uuid not null references dreams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  replaced_at timestamptz not null default now(), -- when this version stopped being current
  description text not null,
  public_description text,
  is_private boolean not null,
  is_explicit boolean not null,
  emotion text not null,
  category text not null,
  clarity text not null,
  city_id int references cities(id),
  dream_date date not null,
  keywords text[] not null
);
create index dream_revisions_dream_idx on dream_revisions(dream_id, replaced_at desc);

-- Owners can read their own history. Nobody can write, change or delete it directly:
-- it is only ever added to by the trigger below, and goes when the dream is deleted.
alter table dream_revisions enable row level security;
create policy "owner reads own dream history" on dream_revisions
  for select using (auth.uid() = user_id);
grant select on dream_revisions to authenticated;

-- Owners can now update their own dreams.
create policy "owner updates own dreams" on dreams
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant update on dreams to authenticated;

create or replace function public.dreams_record_history()
returns trigger
language plpgsql
security definer -- so it can write to dream_revisions, which users cannot
set search_path = ''
as $$
begin
  -- A dream always stays with its owner and keeps its original logging time.
  new.id := old.id;
  new.user_id := old.user_id;
  new.created_at := old.created_at;

  if (new.description, new.is_private, new.is_explicit, new.emotion, new.category, new.clarity,
      new.city_id, new.dream_date, new.keywords, new.public_description)
     is not distinct from
     (old.description, old.is_private, old.is_explicit, old.emotion, old.category, old.clarity,
      old.city_id, old.dream_date, old.keywords, old.public_description) then
    new.edited_at := old.edited_at;
    return new; -- nothing actually changed
  end if;

  insert into public.dream_revisions (
    dream_id, user_id, description, public_description, is_private, is_explicit,
    emotion, category, clarity, city_id, dream_date, keywords
  ) values (
    old.id, old.user_id, old.description, old.public_description, old.is_private, old.is_explicit,
    old.emotion, old.category, old.clarity, old.city_id, old.dream_date, old.keywords
  );

  -- Only content changes count as an edit; privacy changes alone don't.
  if (new.description, new.emotion, new.category, new.clarity, new.city_id, new.dream_date)
     is distinct from
     (old.description, old.emotion, old.category, old.clarity, old.city_id, old.dream_date) then
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;

  return new;
end;
$$;

-- Runs after dreams_moderation_guard (triggers run in name order), so the history
-- records versions that already passed the explicit-content checks.
create trigger dreams_record_history
  before update on dreams
  for each row execute function public.dreams_record_history();

-- Public view gains the "edited" date.
create or replace view public_dreams with (security_invoker = off) as
select id,
       case when is_private or is_explicit then null else public_description end as description,
       emotion, category, clarity, city_id, dream_date, keywords,
       (is_explicit and not is_private) as is_explicit,
       edited_at
from dreams;
