-- REM Atlas: AI pixel avatars (CLAUDE.md section 8b).
-- Run once in the Supabase SQL editor.
--
-- Each AI generation is saved (prompt + 16x16 pixels) so people can look back at them.
-- Limits, enforced here so the website can't be talked out of them:
--   - 3 AI generations per rolling 7 days. A generation that failed (no pixels) stops
--     counting after 5 minutes, which refunds the credit without anyone deleting anything.
--   - Your profile can only use an AI avatar from your own 3 most recent generations.
-- The automatic pattern (avatar_seed) stays available at all times.

create table avatar_generations (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  prompt text not null check (char_length(prompt) between 3 and 120),
  pixels text check (pixels ~ '^[0-9a-c]{256}$'), -- null while generating, or if it failed
  created_at timestamptz not null default now()
);
create index avatar_generations_user_idx on avatar_generations(user_id, created_at desc);

alter table avatar_generations enable row level security;
create policy "owner reads own generations" on avatar_generations
  for select using (auth.uid() = user_id);
create policy "owner starts a generation" on avatar_generations
  for insert with check (auth.uid() = user_id and pixels is null);
create policy "owner completes a generation" on avatar_generations
  for update using (auth.uid() = user_id and pixels is null) with check (auth.uid() = user_id);
grant select, insert on avatar_generations to authenticated;
grant update (pixels) on avatar_generations to authenticated;

create or replace function public.avatar_generations_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_unsuitable_text(new.prompt) then
    raise exception 'avatar prompt contains unsuitable words';
  end if;
  if (select count(*) from public.avatar_generations
      where user_id = new.user_id
        and created_at > now() - interval '7 days'
        and (pixels is not null or created_at > now() - interval '5 minutes')) >= 3 then
    raise exception 'weekly AI avatar limit reached' using errcode = 'P0429';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create trigger avatar_generations_guard
  before insert on avatar_generations
  for each row execute function public.avatar_generations_guard();

-- ---------------------------------------------------------------------------
-- Profiles can show an AI avatar. Null means "use the automatic pattern".
-- ---------------------------------------------------------------------------
alter table profiles add column avatar_pixels text check (avatar_pixels ~ '^[0-9a-c]{256}$');

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
  -- A newly chosen AI avatar must be one of the person's own 3 most recent generations.
  if new.avatar_pixels is not null and new.avatar_pixels is distinct from old.avatar_pixels
     and not exists (
       select 1 from (
         select pixels from public.avatar_generations
         where user_id = new.user_id and pixels is not null
         order by created_at desc limit 3
       ) as recent
       where recent.pixels = new.avatar_pixels
     ) then
    raise exception 'avatar must be one of your 3 most recent AI avatars';
  end if;
  return new;
end;
$$;

-- Public views gain the AI avatar (same visibility rules as before).
create or replace view public_profiles with (security_invoker = off) as
select username, bio, avatar_seed, show_username_on_dreams, updated_at, avatar_pixels
from profiles
where profile_public and username is not null;

create or replace view public_dreams with (security_invoker = off) as
select d.id,
       case when d.is_private or d.is_explicit then null else d.public_description end as description,
       d.emotion, d.category, d.clarity, d.city_id, d.dream_date, d.keywords,
       (d.is_explicit and not d.is_private) as is_explicit,
       d.edited_at,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.username end as username,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.avatar_seed end as avatar_seed,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.avatar_pixels end as avatar_pixels
from dreams d
left join profiles p on p.user_id = d.user_id;
