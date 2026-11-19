-- REM Atlas: reporting and takedowns (Online Safety Act groundwork; CLAUDE.md section 8n safety plan).
-- Run once in the Supabase SQL editor, then add yourself as an admin (separate statement, not in this file).
--
-- Anyone can report a public dream or profile. Only admins see reports. Reporters are never shown
-- to the person reported. Takedowns work by holds the owner can't see or lift: a held dream is
-- forced private, and a suspended person's dreams and profile are forced non-public.

create table site_admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table site_admins enable row level security; -- no policies: reachable only through the functions below

create function public.is_site_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.site_admins a where a.user_id = auth.uid());
$$;

create table content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references auth.users(id) on delete set null,
  kind text not null check (kind in ('dream', 'profile')),
  dream_id uuid references dreams(id) on delete set null,
  reported_user uuid references auth.users(id) on delete set null,
  snapshot text, -- the public text as reported, kept as evidence if it later changes
  reason text not null check (reason in ('child_safety', 'illegal', 'self_harm', 'sexual', 'harassment', 'personal_info', 'other')),
  note text check (char_length(note) <= 500),
  status text not null default 'new' check (status in ('new', 'dismissed', 'actioned')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index content_reports_status_idx on content_reports(status, created_at);
alter table content_reports enable row level security; -- no policies

create table moderation_holds (dream_id uuid primary key references dreams(id) on delete cascade, created_at timestamptz not null default now());
create table suspended_users (user_id uuid primary key references auth.users(id) on delete cascade, created_at timestamptz not null default now());
alter table moderation_holds enable row level security;
alter table suspended_users enable row level security;

-- Held or suspended: stays private whatever the owner sends.
create function public.dreams_apply_holds()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not new.is_private and (
    exists (select 1 from public.moderation_holds h where h.dream_id = new.id)
    or exists (select 1 from public.suspended_users s where s.user_id = new.user_id)
  ) then
    new.is_private := true;
  end if;
  return new;
end;
$$;
create trigger dreams_apply_holds before insert or update on dreams
  for each row execute function public.dreams_apply_holds();

create function public.profiles_apply_suspension()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.suspended_users s where s.user_id = new.user_id) then
    new.profile_public := false;
    new.show_username_on_dreams := false;
  end if;
  return new;
end;
$$;
create trigger profiles_apply_suspension before insert or update on profiles
  for each row execute function public.profiles_apply_suspension();

-- Filing a report. Targets must be public now, so private dreams can't be probed. Repeat reports of
-- the same thing by one person are ignored; signed-in people get 20 a day, everyone anonymous
-- shares 200 a day, so the inbox can't be flooded.
create function public.report_content(p_kind text, p_dream uuid, p_username text, p_reason text, p_note text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  owner uuid;
  shown text;
  me uuid := auth.uid();
begin
  if p_kind = 'dream' then
    select d.user_id, coalesce(d.public_description, '') into owner, shown
    from public.dreams d where d.id = p_dream and not d.is_private;
  elsif p_kind = 'profile' then
    select p.user_id, concat('@', p.username, ': ', p.bio) into owner, shown
    from public.profiles p where p.username = lower(p_username) and p.profile_public;
  end if;
  if owner is null then return false; end if;
  if (select count(*) from public.content_reports r
      where r.created_at > now() - interval '1 day' and r.reporter_id is not distinct from me) >= (case when me is null then 200 else 20 end) then
    return false;
  end if;
  if me is not null and exists (
    select 1 from public.content_reports r
    where r.reporter_id = me and r.status = 'new' and r.reported_user = owner and r.kind = p_kind and r.dream_id is not distinct from p_dream
  ) then
    return true;
  end if;
  insert into public.content_reports (reporter_id, kind, dream_id, reported_user, snapshot, reason, note)
  values (me, p_kind, case when p_kind = 'dream' then p_dream end, owner, shown, p_reason, nullif(left(trim(p_note), 500), ''));
  return true;
end;
$$;

-- The inbox. Never returns who reported.
create function public.admin_reports()
returns table (id uuid, kind text, dream_id uuid, reported_user uuid, snapshot text, reason text, note text, created_at timestamptz, prior_reports bigint)
language sql stable security definer set search_path = '' as $$
  select r.id, r.kind, r.dream_id, r.reported_user, r.snapshot, r.reason, r.note, r.created_at,
         (select count(*) from public.content_reports o where o.reported_user = r.reported_user and o.id <> r.id)
  from public.content_reports r
  where public.is_site_admin() and r.status = 'new'
  order by (r.reason = 'child_safety') desc, r.created_at;
$$;

-- p_action: dismiss, hide_dream, clear_profile or suspend.
create function public.admin_resolve_report(p_report uuid, p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.content_reports;
begin
  if not public.is_site_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  select * into r from public.content_reports where id = p_report;
  if r.id is null then raise exception 'Report not found.'; end if;

  if p_action = 'hide_dream' and r.dream_id is not null then
    insert into public.moderation_holds (dream_id) values (r.dream_id) on conflict do nothing;
    update public.dreams set is_private = true where id = r.dream_id;
  elsif p_action = 'clear_profile' then
    update public.profiles set show_username_on_dreams = false, profile_public = false, bio = null where user_id = r.reported_user;
  elsif p_action = 'suspend' then
    insert into public.suspended_users (user_id) values (r.reported_user) on conflict do nothing;
    update public.dreams set is_private = true where user_id = r.reported_user and not is_private;
    update public.profiles set show_username_on_dreams = false, profile_public = false where user_id = r.reported_user;
  elsif p_action <> 'dismiss' then
    raise exception 'Unknown action.';
  end if;

  update public.content_reports
  set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end, resolved_at = now()
  where id = p_report;
end;
$$;

revoke all on function public.report_content(text, uuid, text, text, text) from public;
grant execute on function public.report_content(text, uuid, text, text, text) to anon, authenticated;
revoke all on function public.admin_reports() from public, anon;
grant execute on function public.admin_reports() to authenticated;
revoke all on function public.admin_resolve_report(uuid, text) from public, anon;
grant execute on function public.admin_resolve_report(uuid, text) to authenticated;
revoke all on function public.is_site_admin() from public, anon;
grant execute on function public.is_site_admin() to authenticated;
