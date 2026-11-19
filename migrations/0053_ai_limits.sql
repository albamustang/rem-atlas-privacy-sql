-- REM Atlas: AI limits balanced against cost (his decision, 9 November 2026).
-- Dream paintings per rolling 7 days: free 1, member 15, patron 40 (about 1.3p each).
-- AI avatars and avatar edits per rolling 7 days: free 3, member 15, patron 30 (about 0.5p each).
-- Dream profiles: free 1 per 7 days, members and patrons 10 per 24 hours.
-- The site-wide cap of 500 paintings a day (0049) stays.

create or replace function public.dream_picture_limit(uid uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select case public.member_tier(uid) when 'patron' then 40 when 'member' then 15 else 1 end;
$$;
revoke all on function public.dream_picture_limit(uuid) from public, anon, authenticated;

create or replace function public.avatar_generations_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  weekly int := case public.member_tier(new.user_id) when 'patron' then 30 when 'member' then 15 else 3 end;
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
  member boolean := public.member_tier(new.user_id) is not null;
  allowed int := case when member then 10 else 1 end;
  span interval := case when member then interval '24 hours' else interval '7 days' end;
begin
  if (select count(*) from public.dream_profiles
      where user_id = new.user_id and created_at > now() - span) >= allowed then
    raise exception 'dream profile limit reached' using errcode = 'P0429';
  end if;
  new.created_at := now();
  return new;
end;
$$;
