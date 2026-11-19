-- Notifications (2026-11-15): one feed of what happened to you, with read/unread kept on the
-- account so it clears on every device. Rows are written only by the database itself (triggers),
-- never by the API, so nobody can send anyone a fake notification. They hold no dream text and no
-- comment text: only the kind, a date or circle name, and where to look.
--
-- Optional pushes, off by default, one switch per kind (profiles.push_kinds). They are sent by the
-- server every 20 minutes, only between 08:00 and 21:59 in the person's own time zone, and never
-- for anything older than 12 hours.

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('comment', 'bottle_reaction', 'friend_request', 'friend_accepted', 'circle_join')),
  detail text check (char_length(detail) <= 60), -- the dream's date, or the circle's name
  link text not null check (link ~ '^/[a-z0-9/_-]*$'),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  pushed_at timestamptz
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_push_idx on public.notifications (created_at) where pushed_at is null;
alter table public.notifications enable row level security;
create policy "owner reads own notifications" on public.notifications for select using (auth.uid() = user_id);
grant select on public.notifications to authenticated;
grant select, update on public.notifications to service_role;

alter table public.profiles add column push_kinds text[] not null default '{}'
  check (push_kinds <@ array['comment', 'bottle_reaction', 'friend_request', 'friend_accepted', 'circle_join']);

-- Keep the feed short: 200 per person, oldest dropped.
create function public.notify(p_user uuid, p_kind text, p_detail text, p_link text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null then return; end if;
  insert into public.notifications (user_id, kind, detail, link) values (p_user, p_kind, left(p_detail, 60), p_link);
  delete from public.notifications where user_id = p_user and id in (
    select id from public.notifications where user_id = p_user order by created_at desc offset 200
  );
end;
$$;
revoke all on function public.notify(uuid, text, text, text) from public, anon, authenticated;

-- Someone else commented on your dream.
create function public.notify_comment() returns trigger language plpgsql security definer set search_path = '' as $$
declare owner uuid; night date;
begin
  select d.user_id, d.dream_date into owner, night from public.dreams d where d.id = new.dream_id;
  if owner is not null and owner <> new.user_id and new.hidden_at is null then
    perform public.notify(owner, 'comment', to_char(night, 'FMDD Mon'), '/activity');
  end if;
  return new;
end;
$$;
create trigger dream_comments_notify after insert on public.dream_comments for each row execute function public.notify_comment();

-- Someone reacted to a bottle you sent.
create function public.notify_bottle_reaction() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.reacted_at is null and new.reacted_at is not null then
    perform public.notify((select b.user_id from public.bottles b where b.id = new.bottle_id), 'bottle_reaction', null, '/bottle');
  end if;
  return new;
end;
$$;
create trigger bottle_deliveries_notify after update on public.bottle_deliveries for each row execute function public.notify_bottle_reaction();

-- Someone asked to be your friend.
create function public.notify_friend_request() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.notify(new.to_user, 'friend_request', null, '/friends');
  return new;
end;
$$;
create trigger friend_requests_notify after insert on public.friend_requests for each row execute function public.notify_friend_request();

-- Your friend request was accepted (the one who accepted is the signed-in person).
create function public.notify_friend_accepted() returns trigger language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is not null and me in (new.a, new.b) then
    perform public.notify(case when me = new.a then new.b else new.a end, 'friend_accepted', null, '/friends');
  end if;
  return new;
end;
$$;
create trigger friendships_notify after insert on public.friendships for each row execute function public.notify_friend_accepted();

-- Someone joined a circle you made.
create function public.notify_circle_join() returns trigger language plpgsql security definer set search_path = '' as $$
declare owner uuid; title text;
begin
  select c.owner, c.name into owner, title from public.circles c where c.id = new.circle_id;
  if owner is not null and owner <> new.user_id then
    perform public.notify(owner, 'circle_join', title, '/circles/' || new.circle_id::text);
  end if;
  return new;
end;
$$;
create trigger circle_members_notify after insert on public.circle_members for each row execute function public.notify_circle_join();

-- Mark read: everything (opening the notifications page), or some kinds (opening the page they
-- point to, such as /activity for comments).
create function public.mark_notifications_read(p_kinds text[] default null)
returns void language sql security definer set search_path = '' as $$
  update public.notifications set read_at = now()
  where user_id = auth.uid() and read_at is null and (p_kinds is null or kind = any (p_kinds));
$$;
revoke all on function public.mark_notifications_read(text[]) from public, anon;
grant execute on function public.mark_notifications_read(text[]) to authenticated;

-- Choose which kinds may reach your phone. Unknown kinds are refused by the column's check.
create function public.set_push_kinds(p_kinds text[])
returns void language sql security definer set search_path = '' as $$
  update public.profiles set push_kinds = coalesce(p_kinds, '{}') where user_id = auth.uid();
$$;
revoke all on function public.set_push_kinds(text[]) from public, anon;
grant execute on function public.set_push_kinds(text[]) to authenticated;

-- The server's pick of social pushes to send now (service role only): unread, not yet pushed,
-- under 12 hours old, a kind the person switched on, with a device, and 08:00-21:59 their time.
-- Anything that won't be pushed is marked so it isn't looked at again.
create function public.claim_social_pushes(max_rows int default 90)
returns table (user_id uuid, kind text, detail text, link text)
language plpgsql security definer set search_path = '' as $$
begin
  update public.notifications n set pushed_at = now()
  where n.pushed_at is null and (n.read_at is not null or n.created_at < now() - interval '12 hours');

  return query
  with due as (
    select n.id
    from public.notifications n
    join public.profiles p on p.user_id = n.user_id
    where n.pushed_at is null and n.read_at is null
      and n.kind = any (p.push_kinds)
      and extract(hour from now() at time zone coalesce(p.reminder_tz, 'Europe/London')) between 8 and 21
      and exists (select 1 from public.push_subscriptions s where s.user_id = n.user_id)
    order by n.created_at
    limit max_rows
    for update of n skip locked
  )
  update public.notifications n set pushed_at = now()
  from due where n.id = due.id
  returning n.user_id, n.kind, n.detail, n.link;
end;
$$;
revoke all on function public.claim_social_pushes(int) from public, anon, authenticated;
grant execute on function public.claim_social_pushes(int) to service_role;
