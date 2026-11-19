-- 0060: dream circles. Private groups of up to 8 people (partners, families, friends) who choose,
-- dream by dream, to share with each other. Nothing is shared by joining: each dream is shared
-- by its owner, to one circle, and can be taken back at any time.
--
-- Locked: site_settings.circles_live = false until the Online Safety record covers circles (only
-- admins can use them meanwhile). To launch: update site_settings set value = true where key = 'circles_live';
--
-- Rules: creating a circle needs a membership (paid, trial or bonus); joining is free but needs an
-- 18+ confirmation; explicit dreams can't be shared; suspended people can't create, join or share.
-- The tables have no policies at all: everything goes through the functions below, which check
-- that the caller is in the circle.

insert into public.site_settings values ('circles_live', false) on conflict (key) do nothing;

create table public.circles (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  owner uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table public.circle_members (
  circle_id uuid not null references public.circles(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (circle_id, user_id)
);
create index circle_members_user_idx on public.circle_members(user_id);
create table public.circle_invites (
  code text primary key,
  circle_id uuid not null references public.circles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create table public.circle_shares (
  circle_id uuid not null references public.circles(id) on delete cascade,
  dream_id uuid not null references public.dreams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  shared_at timestamptz not null default now(),
  primary key (circle_id, dream_id)
);
alter table public.circles enable row level security;
alter table public.circle_members enable row level security;
alter table public.circle_invites enable row level security;
alter table public.circle_shares enable row level security;
revoke all on public.circles, public.circle_members, public.circle_invites, public.circle_shares from anon, authenticated;

create function public.circles_open()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'circles_live'), false)
         or exists (select 1 from public.site_admins a where a.user_id = auth.uid());
$$;
grant execute on function public.circles_open() to authenticated;

create function public.in_circle(c uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.circle_members m where m.circle_id = c and m.user_id = auth.uid());
$$;

create function public.circle_guard()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'log in first'; end if;
  if not public.circles_open() then raise exception 'circles are not open yet'; end if;
  if exists (select 1 from public.suspended_users s where s.user_id = auth.uid()) then raise exception 'not allowed'; end if;
end $$;

-- Make a circle (members only; up to 5 of your own).
create function public.create_circle(p_name text, over_18 boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  perform public.circle_guard();
  if not over_18 then raise exception 'circles are for adults'; end if;
  if public.member_tier(auth.uid()) is null then raise exception 'creating a circle needs a membership'; end if;
  if (select count(*) from public.circles where owner = auth.uid()) >= 5 then raise exception 'you already have 5 circles'; end if;
  insert into public.circles (name, owner) values (btrim(p_name), auth.uid()) returning id into cid;
  insert into public.circle_members (circle_id, user_id) values (cid, auth.uid());
  return cid;
end $$;

-- A fresh invite code (owner only), valid for 7 days, any number of uses until the circle is full.
create function public.circle_invite(c uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare code text := encode(extensions.gen_random_bytes(9), 'hex');
begin
  perform public.circle_guard();
  if not exists (select 1 from public.circles where id = c and owner = auth.uid()) then raise exception 'only the owner can invite'; end if;
  delete from public.circle_invites where circle_id = c and expires_at < now();
  insert into public.circle_invites (code, circle_id) values (code, c);
  return code;
end $$;

-- What an invite is for, before joining (name and size only).
create function public.circle_invite_info(p_code text)
returns table (circle_id uuid, name text, members int, already boolean)
language sql stable security definer set search_path = '' as $$
  select c.id, c.name, (select count(*)::int from public.circle_members m where m.circle_id = c.id), public.in_circle(c.id)
  from public.circle_invites i join public.circles c on c.id = i.circle_id
  where i.code = p_code and i.expires_at > now() and auth.uid() is not null;
$$;

create function public.join_circle(p_code text, over_18 boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  perform public.circle_guard();
  if not over_18 then raise exception 'circles are for adults'; end if;
  select i.circle_id into cid from public.circle_invites i where i.code = p_code and i.expires_at > now();
  if cid is null then raise exception 'this invite has expired'; end if;
  if public.in_circle(cid) then return cid; end if;
  if (select count(*) from public.circle_members where circle_id = cid) >= 8 then raise exception 'this circle is full'; end if;
  insert into public.circle_members (circle_id, user_id) values (cid, auth.uid());
  return cid;
end $$;

-- Leave a circle: your shares in it go with you. If the owner leaves, the circle is deleted.
create function public.leave_circle(c uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.circles where id = c and owner = auth.uid()) then
    delete from public.circles where id = c;
  else
    delete from public.circle_shares where circle_id = c and user_id = auth.uid();
    delete from public.circle_members where circle_id = c and user_id = auth.uid();
  end if;
end $$;

-- The owner removes someone (and their shares).
create function public.remove_circle_member(c uuid, uid uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.circles where id = c and owner = auth.uid()) or uid = auth.uid() then raise exception 'not allowed'; end if;
  delete from public.circle_shares where circle_id = c and user_id = uid;
  delete from public.circle_members where circle_id = c and user_id = uid;
end $$;

-- Share one of your own dreams with one of your circles (never an explicit one).
create function public.share_to_circle(c uuid, d uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.circle_guard();
  if not public.in_circle(c) then raise exception 'not in this circle'; end if;
  if not exists (select 1 from public.dreams where id = d and user_id = auth.uid() and not is_explicit) then raise exception 'that dream cannot be shared'; end if;
  insert into public.circle_shares (circle_id, dream_id, user_id) values (c, d, auth.uid()) on conflict do nothing;
end $$;

create function public.unshare_from_circle(c uuid, d uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.circle_shares where circle_id = c and dream_id = d and user_id = auth.uid();
$$;

-- Your circles.
create function public.my_circles()
returns table (id uuid, name text, members int, is_owner boolean)
language sql stable security definer set search_path = '' as $$
  select c.id, c.name, (select count(*)::int from public.circle_members x where x.circle_id = c.id), c.owner = auth.uid()
  from public.circles c join public.circle_members m on m.circle_id = c.id and m.user_id = auth.uid()
  order by c.created_at;
$$;

-- Who's in a circle (members only see it). Names are usernames where set, else "a member".
create function public.circle_people(c uuid)
returns table (user_id uuid, name text, is_owner boolean, is_me boolean)
language sql stable security definer set search_path = '' as $$
  select m.user_id, coalesce(p.username, 'a member'), m.user_id = c2.owner, m.user_id = auth.uid()
  from public.circle_members m
  join public.circles c2 on c2.id = m.circle_id
  left join public.profiles p on p.user_id = m.user_id
  where m.circle_id = c and public.in_circle(c)
  order by m.joined_at;
$$;

-- The dreams shared in a circle, newest night first (members only). The owner's own words, as
-- shared; held or suspended dreams drop out.
create function public.circle_feed(c uuid)
returns table (dream_id uuid, name text, mine boolean, dream_date date, emotion text, clarity text, description text, shared_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select d.id, coalesce(p.username, 'a member'), s.user_id = auth.uid(), d.dream_date, d.emotion, d.clarity, d.description, s.shared_at
  from public.circle_shares s
  join public.dreams d on d.id = s.dream_id
  left join public.profiles p on p.user_id = s.user_id
  where s.circle_id = c and public.in_circle(c) and not d.is_explicit
    and not exists (select 1 from public.suspended_users u where u.user_id = s.user_id)
    and not exists (select 1 from public.moderation_holds h where h.dream_id = d.id)
  order by d.dream_date desc, s.shared_at desc
  limit 200;
$$;

-- Which of your circles a dream is shared with (for the share buttons on the dream card).
create function public.dream_circles(d uuid)
returns table (circle_id uuid) language sql stable security definer set search_path = '' as $$
  select s.circle_id from public.circle_shares s where s.dream_id = d and s.user_id = auth.uid();
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'circle_guard()', 'in_circle(uuid)', 'create_circle(text, boolean)', 'circle_invite(uuid)', 'circle_invite_info(text)',
    'join_circle(text, boolean)', 'leave_circle(uuid)', 'remove_circle_member(uuid, uuid)', 'share_to_circle(uuid, uuid)',
    'unshare_from_circle(uuid, uuid)', 'my_circles()', 'circle_people(uuid)', 'circle_feed(uuid)', 'dream_circles(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    if f not in ('circle_guard()', 'in_circle(uuid)') then execute format('grant execute on function public.%s to authenticated', f); end if;
  end loop;
end $$;

-- Reporting: members can report a dream shared in their circle (it goes to the same inbox).
-- Same as 0045's version, plus the circle branch.
create or replace function public.report_content(p_kind text, p_dream uuid, p_username text, p_reason text, p_note text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  owner uuid;
  shown text;
  me uuid := auth.uid();
begin
  if p_kind = 'dream' then
    select d.user_id, coalesce(d.public_description, '') into owner, shown
    from public.dreams d where d.id = p_dream and not d.is_private;
    -- 0060: or a dream shared in one of the reporter's circles (private dreams included).
    if owner is null then
      select d.user_id, d.description into owner, shown
      from public.dreams d
      where d.id = p_dream
        and exists (select 1 from public.circle_shares s join public.circle_members m on m.circle_id = s.circle_id
                    where s.dream_id = p_dream and m.user_id = me);
    end if;
  elsif p_kind = 'profile' then
    select p.user_id, concat('@', p.username, ': ', p.bio) into owner, shown
    from public.profiles p where p.username = lower(p_username) and p.profile_public;
  elsif p_kind = 'patron' then
    select p.user_id, p.founder_name into owner, shown
    from public.profiles p where p.founder_name = p_username and p.founder_listed limit 1;
  elsif p_kind = 'comment' then -- p_dream carries the comment's id
    select c.user_id, c.body into owner, shown from public.dream_comments c where c.id = p_dream;
  end if;
  if owner is null then return false; end if;
  if (select count(*) from public.content_reports r
      where r.created_at > now() - interval '1 day' and r.reporter_id is not distinct from me) >= (case when me is null then 200 else 20 end) then
    return false;
  end if;
  if me is not null and exists (
    select 1 from public.content_reports r
    where r.reporter_id = me and r.status = 'new' and r.reported_user = owner and r.kind = p_kind
      and r.dream_id is not distinct from (case when p_kind = 'dream' then p_dream end)
      and r.comment_id is not distinct from (case when p_kind = 'comment' then p_dream end)
  ) then
    return true;
  end if;
  insert into public.content_reports (reporter_id, kind, dream_id, comment_id, reported_user, snapshot, reason, note)
  values (me, p_kind, case when p_kind = 'dream' then p_dream end, case when p_kind = 'comment' then p_dream end, owner, shown, p_reason, nullif(left(trim(p_note), 500), ''));
  if p_kind = 'comment' and (select count(distinct r.reporter_id) from public.content_reports r where r.comment_id = p_dream) >= 3 then
    update public.dream_comments set hidden_at = now() where id = p_dream;
  end if;
  return true;
end;
$$;
