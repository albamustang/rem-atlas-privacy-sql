-- REM Atlas: closing safety gaps before comments. Run once in the Supabase SQL editor.
--
-- 1. A dream can only go public with a clearance the server wrote after AI screening, so a direct
--    API write can't skip it. Dreams already public stay as they are until their text changes.
-- 2. Patron names can be reported.
-- 3. notified_at lets the hourly job email the admin once about new reports.

create table public_text_clearances (
  user_id uuid not null references auth.users(id) on delete cascade,
  text_md5 text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, text_md5)
);
alter table public_text_clearances enable row level security; -- no policies: server key only
grant select, insert, update on public_text_clearances to service_role;

create or replace function public.dreams_require_clearance()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Explicit dreams show no text publicly, so there's nothing to clear.
  if not new.is_private and not new.is_explicit
     and (tg_op = 'INSERT' or old.is_private or old.description is distinct from new.description or old.is_explicit)
     and not exists (
       select 1 from public.public_text_clearances c
       where c.user_id = new.user_id and c.text_md5 = md5(new.description)
     ) then
    new.is_private := true;
  end if;
  return new;
end;
$$;
create trigger dreams_require_clearance before insert or update on dreams
  for each row execute function public.dreams_require_clearance();

alter table content_reports add column notified_at timestamptz;
grant select, update on content_reports to service_role;
alter table content_reports drop constraint content_reports_kind_check;
alter table content_reports add constraint content_reports_kind_check check (kind in ('dream', 'profile', 'patron'));

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
  elsif p_kind = 'profile' then
    select p.user_id, concat('@', p.username, ': ', p.bio) into owner, shown
    from public.profiles p where p.username = lower(p_username) and p.profile_public;
  elsif p_kind = 'patron' then
    select p.user_id, p.founder_name into owner, shown
    from public.profiles p where p.founder_name = p_username and p.founder_listed limit 1;
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

-- Clearing a profile now also takes the name off the Patrons page.
create or replace function public.admin_resolve_report(p_report uuid, p_action text)
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
    update public.profiles set show_username_on_dreams = false, profile_public = false, bio = null, founder_listed = false where user_id = r.reported_user;
  elsif p_action = 'suspend' then
    insert into public.suspended_users (user_id) values (r.reported_user) on conflict do nothing;
    update public.dreams set is_private = true where user_id = r.reported_user and not is_private;
    update public.profiles set show_username_on_dreams = false, profile_public = false, founder_listed = false where user_id = r.reported_user;
  elsif p_action <> 'dismiss' then
    raise exception 'Unknown action.';
  end if;

  update public.content_reports
  set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end, resolved_at = now()
  where id = p_report;
end;
$$;
