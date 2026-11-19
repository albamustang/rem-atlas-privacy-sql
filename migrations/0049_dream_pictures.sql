-- Dream pictures (CLAUDE.md 8n pipeline "better dream images", approved 2026-11-09): an image model
-- (OpenAI GPT Image mini) paints one picture of a dream. The dream text never goes to OpenAI: Haiku
-- first writes a short visual scene with no names or identifying places, and only that is sent.
-- Explicit dreams are never painted. Images live in a private Storage bucket with no policies,
-- so only the server (secret key) can upload, sign links or delete.
--
-- Caps, rolling 7 days: free 2, member 10, patron 20. Site-wide: 500 a day.
-- A request that is still pending after 5 minutes, or failed, stops counting (refund).

create table if not exists public.dream_pictures (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  dream_id uuid not null references public.dreams(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'done', 'failed')),
  path text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists dream_pictures_user_idx on public.dream_pictures (user_id, created_at desc);
create index if not exists dream_pictures_dream_idx on public.dream_pictures (dream_id, created_at desc);
create index if not exists dream_pictures_created_idx on public.dream_pictures (created_at);

alter table public.dream_pictures enable row level security;
create policy "owner reads own pictures" on public.dream_pictures
  for select using (auth.uid() = user_id);
grant select on public.dream_pictures to authenticated;
revoke insert, update, delete on public.dream_pictures from anon, authenticated;
grant select, update on public.dream_pictures to service_role;

create or replace function public.dream_picture_limit(uid uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select case public.member_tier(uid) when 'patron' then 20 when 'member' then 10 else 2 end;
$$;
revoke all on function public.dream_picture_limit(uuid) from public, anon, authenticated;

-- Pictures left this week for the signed-in person.
create or replace function public.dream_pictures_left()
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(0, public.dream_picture_limit(auth.uid()) - (
    select count(*)::int from public.dream_pictures
    where user_id = auth.uid()
      and created_at > now() - interval '7 days'
      and (status = 'done' or (status = 'pending' and created_at > now() - interval '5 minutes'))
  ));
$$;
revoke all on function public.dream_pictures_left() from public, anon;
grant execute on function public.dream_pictures_left() to authenticated;

-- Reserve one picture for one of your own dreams. Returns the new row's id.
create or replace function public.start_dream_picture(p_dream uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
begin
  if uid is null then
    raise exception 'log in first' using errcode = '42501';
  end if;
  if not exists (select 1 from public.dreams where id = p_dream and user_id = uid) then
    raise exception 'not your dream' using errcode = '42501';
  end if;
  if exists (select 1 from public.dreams where id = p_dream and is_explicit) then
    raise exception 'explicit dreams are not painted' using errcode = 'P0001';
  end if;
  -- One at a time per person.
  perform pg_advisory_xact_lock(hashtext('dream_picture:' || uid::text));
  if exists (select 1 from public.dream_pictures where user_id = uid and status = 'pending' and created_at > now() - interval '5 minutes') then
    raise exception 'already painting' using errcode = 'P0001';
  end if;
  if public.dream_pictures_left() < 1 then
    raise exception 'weekly limit reached' using errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtext('dream_picture:site'));
  if (select count(*) from public.dream_pictures
      where created_at > now() - interval '1 day'
        and (status = 'done' or (status = 'pending' and created_at > now() - interval '5 minutes'))) >= 500 then
    raise exception 'site limit reached' using errcode = 'P0001';
  end if;
  insert into public.dream_pictures (user_id, dream_id) values (uid, p_dream) returning id into new_id;
  return new_id;
end;
$$;
revoke all on function public.start_dream_picture(uuid) from public, anon;
grant execute on function public.start_dream_picture(uuid) to authenticated;

-- Private bucket, no policies: reachable only with the server's secret key.
insert into storage.buckets (id, name, public)
values ('dream-pictures', 'dream-pictures', false)
on conflict (id) do nothing;
