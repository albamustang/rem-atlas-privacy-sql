-- 0069: invite a friend to a dream circle (16 Nov 2026).
-- The circle's owner picks someone from their friends list; that friend gets a notification with
-- a join link. Nobody is ever added without saying yes: the friend still opens the link and
-- confirms they are an adult, exactly as with a pasted invite link. One invitation per friend per
-- circle per week. The notification carries no names, only the link.

-- A new kind of notification. The old checks are found by what they say, not by name.
do $$
declare r record;
begin
  for r in
    select conrelid::regclass as tbl, conname from pg_constraint
    where contype = 'c' and conrelid in ('public.notifications'::regclass, 'public.profiles'::regclass)
      and pg_get_constraintdef(oid) like '%circle_join%'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
end $$;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('comment', 'bottle_reaction', 'friend_request', 'friend_accepted', 'circle_join', 'circle_invite'));
alter table public.profiles add constraint profiles_push_kinds_check
  check (push_kinds <@ array['comment', 'bottle_reaction', 'friend_request', 'friend_accepted', 'circle_join', 'circle_invite']);

-- Has this person been invited to this circle in the last week?
create or replace function public.circle_invited(c uuid, uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.notifications n
    join public.circle_invites i on n.link = '/circles/join/' || i.code
    where n.user_id = uid and n.kind = 'circle_invite' and i.circle_id = c and n.created_at > now() - interval '7 days'
  );
$$;
revoke all on function public.circle_invited(uuid, uuid) from public, anon, authenticated;

-- The owner's friends who aren't in the circle yet, and whether each has a recent invitation.
create or replace function public.circle_friends(c uuid)
returns table (username text, invited boolean)
language sql stable security definer set search_path = '' as $$
  select p.username, public.circle_invited(c, p.user_id)
  from public.friendships f
  join public.profiles p on p.user_id = case when f.a = auth.uid() then f.b else f.a end
  where auth.uid() in (f.a, f.b) and p.username is not null
    and exists (select 1 from public.circles x where x.id = c and x.owner = auth.uid())
    and not exists (select 1 from public.circle_members m where m.circle_id = c and m.user_id = p.user_id)
    and not exists (select 1 from public.suspended_users s where s.user_id = p.user_id)
    and not public.blocked_between(auth.uid(), p.user_id)
  order by p.username;
$$;

create or replace function public.invite_friend_to_circle(c uuid, p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  them uuid;
  code text := encode(extensions.gen_random_bytes(9), 'hex');
begin
  perform public.circle_guard();
  if not exists (select 1 from public.circles where id = c and owner = me) then raise exception 'only the owner can invite'; end if;
  select p.user_id into them from public.profiles p where p.username = lower(p_username);
  if them is null
     or not exists (select 1 from public.friendships f where f.a = least(me, them) and f.b = greatest(me, them))
     or public.blocked_between(me, them)
     or exists (select 1 from public.suspended_users s where s.user_id = them) then
    raise exception 'you can only invite your friends';
  end if;
  if exists (select 1 from public.circle_members m where m.circle_id = c and m.user_id = them) then raise exception 'they are already in this circle'; end if;
  if (select count(*) from public.circle_members where circle_id = c) >= 8 then raise exception 'this circle is full'; end if;
  if public.circle_invited(c, them) then raise exception 'you have already invited them this week'; end if;
  delete from public.circle_invites where circle_id = c and expires_at < now();
  insert into public.circle_invites (code, circle_id) values (code, c);
  perform public.notify(them, 'circle_invite', null, '/circles/join/' || code);
end $$;

revoke all on function public.circle_friends(uuid), public.invite_friend_to_circle(uuid, text) from public, anon;
grant execute on function public.circle_friends(uuid), public.invite_friend_to_circle(uuid, text) to authenticated;
