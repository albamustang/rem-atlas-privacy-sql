-- REM Atlas: profiles (CLAUDE.md section 8b).
-- Run once in the Supabase SQL editor.
--
-- Everything is off by default: dreams stay anonymous and profiles stay hidden until
-- the person switches them on. A username is never shown next to a private or explicit dream.

create table profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text unique check (
    username ~ '^[a-z0-9_]{3,20}$'
    and username not in ('admin', 'administrator', 'rematlas', 'rem_atlas', 'promethean', 'prometheanventures',
                         'support', 'privacy', 'help', 'moderator', 'mod', 'staff', 'official', 'system', 'null')
  ),
  bio text check (char_length(bio) <= 160),
  -- Random, so the avatar pattern reveals nothing about the account; changed to get a new pattern.
  avatar_seed uuid not null default gen_random_uuid(),
  profile_public boolean not null default false,
  show_username_on_dreams boolean not null default false,
  updated_at timestamptz not null default now(),
  -- Names on dreams link to the profile, so the profile must be public too.
  check (not show_username_on_dreams or (profile_public and username is not null))
);

alter table profiles enable row level security;
create policy "owner reads own profile" on profiles for select using (auth.uid() = user_id);
create policy "owner creates own profile" on profiles for insert with check (auth.uid() = user_id);
create policy "owner updates own profile" on profiles for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update on profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Backstop for public text. The website rejects unsuitable usernames and bios with a much
-- better filter; this only catches the obvious cases if someone writes to the database
-- directly. Keep the explicit list in step with src/lib/moderation/explicit-terms.ts.
-- ---------------------------------------------------------------------------
create or replace function public.is_unsuitable_text(t text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- Whole words only (underscores count as spaces), so "peacock" or "Scunthorpe" pass.
  select coalesce(
    regexp_replace(t, '_', ' ', 'g') ~* '\m(withheld)\M' /* the explicit-content word list is withheld from this public copy: published, it would be a guide to getting round it. The rule itself is unchanged. */,
    false);
$$;

create or replace function public.profiles_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.user_id := coalesce(old.user_id, new.user_id);
  new.updated_at := now();
  if public.is_unsuitable_text(new.username) or public.is_unsuitable_text(new.bio) then
    raise exception 'username or bio contains unsuitable words';
  end if;
  return new;
end;
$$;

create trigger profiles_guard
  before insert or update on profiles
  for each row execute function public.profiles_guard();

-- ---------------------------------------------------------------------------
-- What the public can see.
-- ---------------------------------------------------------------------------

-- Public profiles only. No user_id, no email.
create view public_profiles with (security_invoker = off) as
select username, bio, avatar_seed, show_username_on_dreams, updated_at
from profiles
where profile_public and username is not null;

revoke all on public_profiles from anon, authenticated;
grant select on public_profiles to anon, authenticated;

-- Achievements of public profiles, for their profile page.
create view public_achievements with (security_invoker = off) as
select p.username, a.code, a.earned_at
from user_achievements a
join profiles p on p.user_id = a.user_id
where p.profile_public and p.username is not null;

revoke all on public_achievements from anon, authenticated;
grant select on public_achievements to anon, authenticated;

-- Public dreams gain the dreamer's username and avatar, only when they opted in, and
-- never on private or explicit dreams.
create or replace view public_dreams with (security_invoker = off) as
select d.id,
       case when d.is_private or d.is_explicit then null else d.public_description end as description,
       d.emotion, d.category, d.clarity, d.city_id, d.dream_date, d.keywords,
       (d.is_explicit and not d.is_private) as is_explicit,
       d.edited_at,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.username end as username,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.avatar_seed end as avatar_seed
from dreams d
left join profiles p on p.user_id = d.user_id;
