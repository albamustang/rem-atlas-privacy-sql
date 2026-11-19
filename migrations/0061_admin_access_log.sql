-- 0061: a record of every time someone running REM Atlas opens a person's dream, comment or profile
-- text, which that person can read (decided 2026-11-12). Append-only: no one can edit or delete a
-- row, admins included (rows go only when the person deletes their account).
--
-- Rows are written two ways:
--   1. Automatically, by admin_reports(), the first time each admin is shown a reported item.
--   2. By hand, whenever we read someone's text directly in the database (SQL editor or table
--      editor), with: insert into admin_access_log (subject_user, dream_id, what, reason, told)
--      values ('<user id>', '<dream id or null>', 'dream', '<why>', true);
-- told = false only where the law forbids telling the person (a child-safety report to the NCA),
-- and those rows are hidden from them.

create table public.admin_access_log (
  id bigint generated always as identity primary key,
  subject_user uuid not null references auth.users(id) on delete cascade,
  what text not null check (what in ('dream', 'comment', 'profile', 'other')),
  dream_id uuid, -- no foreign key: the record outlives a deleted dream
  report_id uuid,
  reason text not null check (char_length(reason) between 3 and 200),
  admin_id uuid references auth.users(id) on delete set null,
  told boolean not null default true,
  at timestamptz not null default now()
);
create index admin_access_log_subject_idx on public.admin_access_log (subject_user, at desc);
create unique index admin_access_log_once_per_report on public.admin_access_log (report_id, admin_id) where report_id is not null;
alter table public.admin_access_log enable row level security;

create policy "you see when your text was opened" on public.admin_access_log
  for select using (auth.uid() = subject_user and told);
grant select on public.admin_access_log to authenticated;
-- No insert, update or delete for anyone through the API.

-- The reports inbox now records what it shows: each admin, each report, once.
create or replace function public.admin_reports()
returns table (id uuid, kind text, dream_id uuid, reported_user uuid, snapshot text, reason text, note text, created_at timestamptz, prior_reports bigint)
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.is_site_admin() then return; end if;
  insert into public.admin_access_log (subject_user, what, dream_id, report_id, reason, admin_id, told)
  select r.reported_user,
         case r.kind when 'dream' then 'dream' when 'profile' then 'profile' when 'comment' then 'comment' else 'other' end,
         r.dream_id, r.id, 'reviewing a report', auth.uid(), r.reason <> 'child_safety'
  from public.content_reports r
  where r.status = 'new' and r.reported_user is not null
  on conflict do nothing;
  return query
  select r.id, r.kind, r.dream_id, r.reported_user, r.snapshot, r.reason, r.note, r.created_at,
         (select count(*) from public.content_reports o where o.reported_user = r.reported_user and o.id <> r.id)
  from public.content_reports r
  where r.status = 'new'
  order by (r.reason = 'child_safety') desc, r.created_at;
end;
$$;
revoke all on function public.admin_reports() from public, anon;
grant execute on function public.admin_reports() to authenticated;
