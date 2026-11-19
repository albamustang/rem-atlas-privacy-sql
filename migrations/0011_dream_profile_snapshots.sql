-- REM Atlas: generated dream profiles (CLAUDE.md section 8e).
-- Run once in the Supabase SQL editor.
--
-- A dream profile is now generated on request ("Generate my dream profile") and saved as
-- a snapshot people can reopen for free. Generating is what runs the AI coding, so it is
-- limited to 3 in any 24 hours per person, enforced here so the website can't exceed it.
-- Raise the number for supporters later.

create table dream_profiles (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  days_logged int not null,
  accuracy text not null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index dream_profiles_user_idx on dream_profiles(user_id, created_at desc);

alter table dream_profiles enable row level security;
create policy "owner reads own dream profiles" on dream_profiles
  for select using (auth.uid() = user_id);
create policy "owner saves own dream profiles" on dream_profiles
  for insert with check (auth.uid() = user_id);
grant select, insert on dream_profiles to authenticated;

create or replace function public.dream_profiles_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select count(*) from public.dream_profiles
      where user_id = new.user_id and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'daily dream profile limit reached' using errcode = 'P0429';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create trigger dream_profiles_guard
  before insert on dream_profiles
  for each row execute function public.dream_profiles_guard();
