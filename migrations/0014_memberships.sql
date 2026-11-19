-- REM Atlas: paid memberships (Supporter now, Founder later). CLAUDE.md section 8f.
-- Run once in the Supabase SQL editor.
--
-- Paddle tells our server about subscriptions (webhook); the server records them here with
-- the Supabase secret key. People can read their own membership but never write it.
-- Members get higher limits (enforced here) and a badge on their public profile.

create table memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tier text not null check (tier in ('supporter', 'founder')),
  status text not null, -- Paddle: active, trialing, past_due, paused, canceled
  paddle_subscription_id text unique,
  paddle_customer_id text,
  current_period_end timestamptz,
  cancel_at timestamptz, -- set when they've cancelled but the paid period hasn't ended
  founding_number int unique, -- the first 100 supporters keep a "founding" number
  event_at timestamptz, -- time of the last Paddle event applied (they can arrive out of order)
  updated_at timestamptz not null default now()
);

alter table memberships enable row level security;
create policy "owner reads own membership" on memberships for select using (auth.uid() = user_id);
grant select on memberships to authenticated;

-- A person's current tier, or null. Past-due members keep their perks while Paddle retries.
create or replace function public.member_tier(uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select tier from public.memberships
  where user_id = uid and status in ('active', 'trialing', 'past_due');
$$;
-- Everyone may call it: the public views below use it for badges, and functions inside a
-- view run with the visitor's permissions. It only reveals a tier, which badges show anyway.
grant execute on function public.member_tier(uuid) to anon, authenticated;

-- The first 100 people to become members get a founding number, kept for good.
create or replace function public.memberships_founding_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if new.founding_number is null and new.status in ('active', 'trialing')
     and (select count(*) from public.memberships where founding_number is not null) < 100 then
    new.founding_number := coalesce((select max(founding_number) from public.memberships), 0) + 1;
  end if;
  return new;
end;
$$;
create trigger memberships_founding_number
  before insert or update on memberships
  for each row execute function public.memberships_founding_number();

-- ---------------------------------------------------------------------------
-- Higher limits for members: 10 AI avatars a week and 10 dream profiles a day (else 3).
-- ---------------------------------------------------------------------------
create or replace function public.avatar_generations_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  weekly int := case when public.member_tier(new.user_id) is not null then 10 else 3 end;
begin
  if public.is_unsuitable_text(new.prompt) then
    raise exception 'avatar prompt contains unsuitable words';
  end if;
  if (select count(*) from public.avatar_generations
      where user_id = new.user_id
        and created_at > now() - interval '7 days'
        and (pixels is not null or created_at > now() - interval '5 minutes')) >= weekly then
    raise exception 'weekly AI avatar limit reached' using errcode = 'P0429';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create or replace function public.dream_profiles_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  daily int := case when public.member_tier(new.user_id) is not null then 10 else 3 end;
begin
  if (select count(*) from public.dream_profiles
      where user_id = new.user_id and created_at > now() - interval '24 hours') >= daily then
    raise exception 'daily dream profile limit reached' using errcode = 'P0429';
  end if;
  new.created_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Badges: public profiles (and named public dreams) show the member tier.
-- ---------------------------------------------------------------------------
create or replace view public_profiles with (security_invoker = off) as
select p.username, p.bio, p.avatar_seed, p.show_username_on_dreams, p.updated_at, p.avatar_pixels,
       public.member_tier(p.user_id) as member_tier,
       m.founding_number
from profiles p
left join memberships m on m.user_id = p.user_id
where p.profile_public and p.username is not null;

create or replace view public_dreams with (security_invoker = off) as
select d.id,
       case when d.is_private or d.is_explicit then null else d.public_description end as description,
       d.emotion, d.category, d.clarity, d.city_id, d.dream_date, d.keywords,
       (d.is_explicit and not d.is_private) as is_explicit,
       d.edited_at,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.username end as username,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.avatar_seed end as avatar_seed,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then p.avatar_pixels end as avatar_pixels,
       case when p.show_username_on_dreams and not d.is_private and not d.is_explicit then public.member_tier(d.user_id) end as member_tier
from dreams d
left join profiles p on p.user_id = d.user_id;
