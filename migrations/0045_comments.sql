-- REM Atlas: comments and blocking (CLAUDE.md section 8g, safety plan stage 3). Run once in the SQL editor.
--
-- Switched off for the public by comments_live until the Ofcom assessments are signed: only site
-- admins can comment while it's false. To launch: update site_settings set value = true where key = 'comments_live';
--
-- Off by default per dream. Commenters must be paying members with a public username. Text needs a
-- server-written clearance (AI screen). The owner can delete and block. Three different signed-in
-- reporters hide a comment automatically.

create table site_settings (key text primary key, value boolean not null);
alter table site_settings enable row level security;
insert into site_settings values ('comments_live', false);

create function public.comments_open()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.site_settings where key = 'comments_live'), false)
         or exists (select 1 from public.site_admins a where a.user_id = auth.uid());
$$;
grant execute on function public.comments_open() to anon, authenticated;

create table comment_enabled (
  dream_id uuid primary key references dreams(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade
);
alter table comment_enabled enable row level security;
create policy "owner reads switch" on comment_enabled for select using (auth.uid() = user_id);
create policy "owner sets switch" on comment_enabled for insert with check (
  auth.uid() = user_id and exists (select 1 from public.dreams d where d.id = dream_id and d.user_id = auth.uid())
);
create policy "owner clears switch" on comment_enabled for delete using (auth.uid() = user_id);
grant select, insert, delete on comment_enabled to authenticated;

create table comment_blocks (
  owner_id uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  primary key (owner_id, blocked_id)
);
alter table comment_blocks enable row level security; -- written through block_commenter() only
create policy "owner clears blocks" on comment_blocks for delete using (auth.uid() = owner_id);
grant delete on comment_blocks to authenticated;

create table dream_comments (
  id uuid primary key default gen_random_uuid(),
  dream_id uuid not null references dreams(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  hidden_at timestamptz,
  created_at timestamptz not null default now()
);
create index dream_comments_dream_idx on dream_comments(dream_id, created_at);
alter table dream_comments enable row level security;
create policy "writer or dream owner reads" on dream_comments for select using (
  auth.uid() = user_id or exists (select 1 from public.dreams d where d.id = dream_id and d.user_id = auth.uid())
);
create policy "writer or dream owner deletes" on dream_comments for delete using (
  auth.uid() = user_id or exists (select 1 from public.dreams d where d.id = dream_id and d.user_id = auth.uid())
);
create policy "writes own" on dream_comments for insert with check (auth.uid() = user_id);
grant select, insert, delete on dream_comments to authenticated;

create function public.dream_comments_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  owner uuid;
begin
  new.created_at := now();
  new.hidden_at := null;
  if new.user_id is distinct from auth.uid() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if not public.comments_open() then raise exception 'Comments are not open yet.' using errcode = 'P0001'; end if;
  if public.member_tier(new.user_id) is null then raise exception 'Comments are for members.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.profiles p where p.user_id = new.user_id and p.profile_public and p.username is not null) then
    raise exception 'Comments need a public username.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.suspended_users s where s.user_id = new.user_id) then raise exception 'Not allowed.' using errcode = '42501'; end if;
  select d.user_id into owner from public.dreams d
    join public.comment_enabled e on e.dream_id = d.id
    where d.id = new.dream_id and not d.is_private and not d.is_explicit;
  if owner is null then raise exception 'Comments are off for this dream.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.comment_blocks b where b.owner_id = owner and b.blocked_id = new.user_id) then
    raise exception 'Comments are off for this dream.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.dream_comments c where c.user_id = new.user_id and c.created_at > now() - interval '1 day') >= 20 then
    raise exception 'That is enough comments for today.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.public_text_clearances c where c.user_id = new.user_id and c.text_md5 = md5(new.body)) then
    raise exception 'That comment was not cleared.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger dream_comments_guard before insert on dream_comments
  for each row execute function public.dream_comments_guard();

-- What the public sees. Never a user id.
create view public_dream_comments with (security_invoker = off) as
select c.id, c.dream_id, c.body, c.created_at, p.username, p.avatar_seed, p.avatar_pixels
from dream_comments c
join dreams d on d.id = c.dream_id and not d.is_private and not d.is_explicit
join comment_enabled e on e.dream_id = d.id
join profiles p on p.user_id = c.user_id and p.profile_public and p.username is not null
where c.hidden_at is null
  and coalesce((select value from site_settings where key = 'comments_live'), false)
  and not exists (select 1 from suspended_users s where s.user_id = c.user_id);
grant select on public_dream_comments to anon, authenticated;

-- The dream's owner blocks whoever wrote a comment on their dream, without learning who they are
-- beyond the public username, and the comment goes.
create function public.block_commenter(p_comment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  writer uuid;
begin
  select c.user_id into writer from public.dream_comments c
    join public.dreams d on d.id = c.dream_id and d.user_id = auth.uid()
    where c.id = p_comment;
  if writer is null then raise exception 'Not allowed.' using errcode = '42501'; end if;
  insert into public.comment_blocks values (auth.uid(), writer) on conflict do nothing;
  delete from public.dream_comments c where c.user_id = writer
    and c.dream_id in (select id from public.dreams where user_id = auth.uid());
end;
$$;
revoke all on function public.block_commenter(uuid) from public, anon;
grant execute on function public.block_commenter(uuid) to authenticated;

-- Reports on comments.
alter table content_reports add column comment_id uuid references dream_comments(id) on delete set null;
alter table content_reports drop constraint content_reports_kind_check;
alter table content_reports add constraint content_reports_kind_check check (kind in ('dream', 'profile', 'patron', 'comment'));

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

-- Admins: hide_comment acts on a comment report. p_action otherwise as in 0044.
create or replace function public.admin_resolve_report(p_report uuid, p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.content_reports;
begin
  if not public.is_site_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  select * into r from public.content_reports where id = p_report;
  if r.id is null then raise exception 'Report not found.'; end if;

  if p_action = 'hide_comment' and r.comment_id is not null then
    update public.dream_comments set hidden_at = now() where id = r.comment_id;
  elsif p_action = 'hide_dream' and r.dream_id is not null then
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
