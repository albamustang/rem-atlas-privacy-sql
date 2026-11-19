-- 0062: friends (decided 2026-11-12). Paying members only, as the practical adults-only gate: a live
-- Stripe subscription (free trials and invite bonus time don't count), plus an 18+ tick when they
-- make themselves findable. Nobody can be found unless they switch "findable" on. No messages:
-- friends see each other's username and avatar, and a link to a public profile if they have one.
-- Everything goes through the functions below (no table policies). Locked by
-- site_settings.friends_live until the Ofcom record covers it (admins can use it meanwhile).

insert into public.site_settings values ('friends_live', false) on conflict (key) do nothing;

create function public.is_paying_member(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.memberships m where m.user_id = uid and m.status in ('active', 'past_due'))
      or exists (select 1 from public.site_admins a where a.user_id = uid);
$$;
revoke all on function public.is_paying_member(uuid) from public, anon, authenticated;

-- Whether the caller is a paying member (never anyone else: who pays is private).
create function public.i_am_paying()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_paying_member(auth.uid());
$$;
revoke all on function public.i_am_paying() from public, anon;
grant execute on function public.i_am_paying() to authenticated;

alter table public.profiles add column findable boolean not null default false;
alter table public.profiles add column findable_over_18_at timestamptz;

create table public.friend_requests (
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_user, to_user),
  check (from_user <> to_user)
);
create index friend_requests_to_idx on public.friend_requests (to_user);
create table public.friendships (
  a uuid not null references auth.users(id) on delete cascade,
  b uuid not null references auth.users(id) on delete cascade,
  since timestamptz not null default now(),
  primary key (a, b),
  check (a < b)
);
create index friendships_b_idx on public.friendships (b);
create table public.friend_blocks (
  owner uuid not null references auth.users(id) on delete cascade,
  blocked uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner, blocked)
);
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.friend_blocks enable row level security;

create function public.friends_open()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'friends_live'), false) or public.is_site_admin();
$$;
grant execute on function public.friends_open() to anon, authenticated;

-- Who may use friends right now (the caller).
create function public.friends_guard()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not public.friends_open() then raise exception 'friends are not open yet' using errcode = 'P0001'; end if;
  if not public.is_paying_member(me) then raise exception 'friends are for paying members' using errcode = 'P0001'; end if;
  if exists (select 1 from public.suspended_users s where s.user_id = me) then raise exception 'not allowed' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.profiles p where p.user_id = me and p.username is not null) then
    raise exception 'choose a username first' using errcode = 'P0001';
  end if;
  return me;
end $$;

-- A member others may add: findable, paying, has a username, not suspended.
create function public.friend_target(p_username text)
returns uuid language sql stable security definer set search_path = '' as $$
  select p.user_id from public.profiles p
  where p.username = lower(p_username) and p.findable
    and public.is_paying_member(p.user_id)
    and not exists (select 1 from public.suspended_users s where s.user_id = p.user_id);
$$;
revoke all on function public.friend_target(text) from public, anon, authenticated;

create function public.blocked_between(x uuid, y uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friend_blocks b where (b.owner = x and b.blocked = y) or (b.owner = y and b.blocked = x));
$$;
revoke all on function public.blocked_between(uuid, uuid) from public, anon, authenticated;

create function public.set_findable(p_on boolean, over_18 boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := public.friends_guard();
begin
  if p_on and over_18 is not true then raise exception 'friends are for adults' using errcode = 'P0001'; end if;
  update public.profiles set findable = p_on, findable_over_18_at = case when p_on then now() else findable_over_18_at end
  where user_id = me;
end $$;

-- Search by username (3+ characters, start of the name), findable members only, 10 at most.
create function public.find_members(q text)
returns table (username text, avatar_seed text, avatar_pixels text, relation text)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := public.friends_guard(); term text := lower(trim(coalesce(q, '')));
begin
  if char_length(term) < 3 or term !~ '^[a-z0-9_]+$' then return; end if;
  return query
  select p.username, p.avatar_seed::text, p.avatar_pixels,
    case
      when exists (select 1 from public.friendships f where (f.a = me and f.b = p.user_id) or (f.b = me and f.a = p.user_id)) then 'friend'
      when exists (select 1 from public.friend_requests r where r.from_user = me and r.to_user = p.user_id) then 'requested'
      when exists (select 1 from public.friend_requests r where r.from_user = p.user_id and r.to_user = me) then 'incoming'
      else 'none' end
  from public.profiles p
  where p.username like term || '%' and p.user_id <> me and p.findable
    and public.is_paying_member(p.user_id)
    and not exists (select 1 from public.suspended_users s where s.user_id = p.user_id)
    and not public.blocked_between(me, p.user_id)
  order by p.username = term desc, p.username
  limit 10;
end $$;

-- Ask to be friends. If they already asked you, this accepts. 20 requests a day, 50 waiting at most.
create function public.request_friend(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := public.friends_guard(); them uuid := public.friend_target(p_username); lo uuid; hi uuid;
begin
  if them is null or them = me or public.blocked_between(me, them) then raise exception 'that member can''t be added' using errcode = 'P0001'; end if;
  lo := least(me, them); hi := greatest(me, them);
  if exists (select 1 from public.friendships f where f.a = lo and f.b = hi) then return 'friends'; end if;
  if exists (select 1 from public.friend_requests r where r.from_user = them and r.to_user = me) then
    delete from public.friend_requests where from_user = them and to_user = me;
    insert into public.friendships (a, b) values (lo, hi) on conflict do nothing;
    return 'friends';
  end if;
  if (select count(*) from public.friend_requests r where r.from_user = me and r.created_at > now() - interval '1 day') >= 20 then
    raise exception 'you''ve sent 20 requests today; try again tomorrow' using errcode = 'P0001';
  end if;
  if (select count(*) from public.friend_requests r where r.from_user = me) >= 50 then
    raise exception 'you have 50 requests waiting; cancel some first' using errcode = 'P0001';
  end if;
  insert into public.friend_requests (from_user, to_user) values (me, them) on conflict do nothing;
  return 'requested';
end $$;

-- Accept or decline a request someone sent you (works even if they've since stopped being findable).
create function public.respond_friend(p_username text, accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := public.friends_guard(); them uuid;
begin
  select p.user_id into them from public.profiles p where p.username = lower(p_username);
  if them is null or not exists (select 1 from public.friend_requests r where r.from_user = them and r.to_user = me) then
    raise exception 'no such request' using errcode = 'P0001';
  end if;
  delete from public.friend_requests where from_user = them and to_user = me;
  if accept and not public.blocked_between(me, them) then
    insert into public.friendships (a, b) values (least(me, them), greatest(me, them)) on conflict do nothing;
  end if;
end $$;

create function public.cancel_friend_request(p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'log in first' using errcode = '42501'; end if;
  delete from public.friend_requests r using public.profiles p
  where r.from_user = me and r.to_user = p.user_id and p.username = lower(p_username);
end $$;

-- Unfriending and blocking always work, membership or not.
create function public.unfriend(p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); them uuid;
begin
  if me is null then raise exception 'log in first' using errcode = '42501'; end if;
  select p.user_id into them from public.profiles p where p.username = lower(p_username);
  delete from public.friendships where a = least(me, them) and b = greatest(me, them);
end $$;

create function public.block_member(p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); them uuid;
begin
  if me is null then raise exception 'log in first' using errcode = '42501'; end if;
  select p.user_id into them from public.profiles p where p.username = lower(p_username);
  if them is null or them = me then return; end if;
  insert into public.friend_blocks (owner, blocked) values (me, them) on conflict do nothing;
  delete from public.friendships where a = least(me, them) and b = greatest(me, them);
  delete from public.friend_requests where (from_user = me and to_user = them) or (from_user = them and to_user = me);
end $$;

-- Your friends, and requests both ways (usernames and avatars only).
create function public.my_friends()
returns table (username text, avatar_seed text, avatar_pixels text, profile_public boolean, since timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.username, p.avatar_seed::text, p.avatar_pixels, p.profile_public, f.since
  from public.friendships f
  join public.profiles p on p.user_id = case when f.a = auth.uid() then f.b else f.a end
  where auth.uid() in (f.a, f.b) and p.username is not null
    and not exists (select 1 from public.suspended_users s where s.user_id = p.user_id)
  order by p.username;
$$;

create function public.my_friend_requests()
returns table (direction text, username text, avatar_seed text, avatar_pixels text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select 'incoming', p.username, p.avatar_seed::text, p.avatar_pixels, r.created_at
  from public.friend_requests r join public.profiles p on p.user_id = r.from_user
  where r.to_user = auth.uid() and p.username is not null
    and not exists (select 1 from public.suspended_users s where s.user_id = p.user_id)
  union all
  select 'outgoing', p.username, p.avatar_seed::text, p.avatar_pixels, r.created_at
  from public.friend_requests r join public.profiles p on p.user_id = r.to_user
  where r.from_user = auth.uid() and p.username is not null
  order by 5 desc;
$$;

create function public.friend_request_count()
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.friend_requests r
  where r.to_user = auth.uid()
    and not exists (select 1 from public.suspended_users s where s.user_id = r.from_user);
$$;

do $$ declare f text; begin
  foreach f in array array['friends_guard()', 'set_findable(boolean, boolean)', 'find_members(text)', 'request_friend(text)',
    'respond_friend(text, boolean)', 'cancel_friend_request(text)', 'unfriend(text)', 'block_member(text)',
    'my_friends()', 'my_friend_requests()', 'friend_request_count()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
