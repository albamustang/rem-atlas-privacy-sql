-- REM Atlas: message in a bottle (CLAUDE.md section 8n, safety plan stage 4). Run once in the SQL editor.
--
-- Switched off for the public by bottles_live until the Ofcom assessments are signed: only site
-- admins can use it while it's false. To launch: update site_settings set value = true where key = 'bottles_live';
--
-- A member sends one chosen public dream a day. It lands with one other member who has also sent
-- one recently, on their next log, one a day. No usernames, no replies, one fixed reaction. Sending
-- goes through the server (send_bottle has no public access) because the AI screen happens there.

insert into site_settings values ('bottles_live', false);

create function public.bottles_open_for(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'bottles_live'), false)
         or exists (select 1 from public.site_admins a where a.user_id = p_user);
$$;
revoke all on function public.bottles_open_for(uuid) from public, anon;
grant execute on function public.bottles_open_for(uuid) to authenticated, service_role;

create table bottles (
  id uuid primary key default gen_random_uuid(),
  dream_id uuid not null unique references dreams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  sent_on date not null default current_date,
  created_at timestamptz not null default now(),
  unique (user_id, sent_on)
);
alter table bottles enable row level security;
create policy "sender reads" on bottles for select using (auth.uid() = user_id);
grant select on bottles to authenticated;

create table bottle_deliveries (
  bottle_id uuid primary key references bottles(id) on delete cascade,
  recipient uuid not null references auth.users(id) on delete cascade,
  delivered_on date not null default current_date,
  delivered_at timestamptz not null default now(),
  reacted_at timestamptz,
  unique (recipient, delivered_on)
);
alter table bottle_deliveries enable row level security; -- no policies: functions only

-- Server key only, after the AI screen has passed this exact dream.
create function public.send_bottle(p_user uuid, p_dream uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.bottles_open_for(p_user) then raise exception 'Bottles are not open yet.' using errcode = 'P0001'; end if;
  if public.member_tier(p_user) is null then raise exception 'Bottles are for members.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.suspended_users s where s.user_id = p_user) then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if not exists (
    select 1 from public.dreams d
    where d.id = p_dream and d.user_id = p_user and not d.is_private and not d.is_explicit
      and not exists (select 1 from public.moderation_holds h where h.dream_id = d.id)
  ) then raise exception 'Only your own public dreams can be sent.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.bottles b where b.user_id = p_user and b.sent_on = current_date) then
    raise exception 'You have already sent a bottle today.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.bottles b where b.dream_id = p_dream) then
    raise exception 'This dream has already been sent.' using errcode = 'P0001';
  end if;
  insert into public.bottles (dream_id, user_id) values (p_dream, p_user);
end;
$$;
revoke all on function public.send_bottle(uuid, uuid) from public, anon, authenticated;
grant execute on function public.send_bottle(uuid, uuid) to service_role;

-- Delivers at most one bottle a day, once the person has logged since their last delivery and
-- has sent a bottle in the last 30 days. Oldest waiting bottle first.
create function public.claim_bottle()
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  since timestamptz;
  chosen uuid;
begin
  if me is null or not public.bottles_open_for(me) or public.member_tier(me) is null then return; end if;
  if exists (select 1 from public.suspended_users s where s.user_id = me) then return; end if;
  if not exists (select 1 from public.bottles b where b.user_id = me and b.sent_on > current_date - 30) then return; end if;
  if exists (select 1 from public.bottle_deliveries x where x.recipient = me and x.delivered_on = current_date) then return; end if;
  select coalesce(max(x.delivered_at), now() - interval '2 days') into since from public.bottle_deliveries x where x.recipient = me;
  since := greatest(since, now() - interval '2 days');
  if not exists (select 1 from public.dreams d where d.user_id = me and d.created_at > since)
     and not exists (select 1 from public.sleep_nights n where n.user_id = me and n.created_at > since) then return; end if;
  select b.id into chosen
  from public.bottles b
  join public.dreams d on d.id = b.dream_id
  where b.user_id <> me
    and not d.is_private and not d.is_explicit
    and not exists (select 1 from public.bottle_deliveries x where x.bottle_id = b.id)
    and not exists (select 1 from public.moderation_holds h where h.dream_id = d.id)
    and not exists (select 1 from public.suspended_users s where s.user_id = b.user_id)
  order by b.created_at
  limit 1
  for update of b skip locked;
  if chosen is not null then
    insert into public.bottle_deliveries (bottle_id, recipient) values (chosen, me) on conflict do nothing;
  end if;
end;
$$;
revoke all on function public.claim_bottle() from public, anon;
grant execute on function public.claim_bottle() to authenticated;

-- The newest bottle that reached me. The place appears only if 3+ people have logged dreams in that
-- city (the atlas floor). No sender details. A dream made private since then stops showing.
create function public.my_bottle()
returns table (bottle_id uuid, dream_id uuid, description text, night date, place text, lat double precision, lon double precision, my_lat double precision, my_lon double precision, reacted boolean)
language sql stable security definer set search_path = '' as $$
  select b.id, d.id, d.public_description, d.dream_date,
         case when f.ok then c.name end,
         case when f.ok then round(c.lat::numeric, 1)::double precision end,
         case when f.ok then round(c.lon::numeric, 1)::double precision end,
         mine.lat, mine.lon, x.reacted_at is not null
  from public.bottle_deliveries x
  join public.bottles b on b.id = x.bottle_id
  join public.dreams d on d.id = b.dream_id
  left join public.cities c on c.id = d.city_id
  left join lateral (select (select count(distinct o.user_id) from public.dreams o where o.city_id = d.city_id) >= 3 as ok) f on true
  left join lateral (
    select mc.lat, mc.lon from public.dreams md join public.cities mc on mc.id = md.city_id
    where md.user_id = auth.uid() order by md.dream_date desc limit 1
  ) mine on true
  where x.recipient = auth.uid()
    and not d.is_private and not d.is_explicit
    and not exists (select 1 from public.moderation_holds h where h.dream_id = d.id)
  order by x.delivered_at desc
  limit 1;
$$;
revoke all on function public.my_bottle() from public, anon;
grant execute on function public.my_bottle() to authenticated;

create function public.react_to_bottle(p_bottle uuid)
returns void language sql security definer set search_path = '' as $$
  update public.bottle_deliveries set reacted_at = coalesce(reacted_at, now())
  where bottle_id = p_bottle and recipient = auth.uid();
$$;
revoke all on function public.react_to_bottle(uuid) from public, anon;
grant execute on function public.react_to_bottle(uuid) to authenticated;

-- What a sender may know: whether each bottle landed and got the reaction. Never who or where.
create function public.my_sent_bottles()
returns table (sent_on date, delivered boolean, reacted boolean)
language sql stable security definer set search_path = '' as $$
  select b.sent_on, x.bottle_id is not null, x.reacted_at is not null
  from public.bottles b left join public.bottle_deliveries x on x.bottle_id = b.id
  where b.user_id = auth.uid() order by b.sent_on desc limit 30;
$$;
revoke all on function public.my_sent_bottles() from public, anon;
grant execute on function public.my_sent_bottles() to authenticated;
