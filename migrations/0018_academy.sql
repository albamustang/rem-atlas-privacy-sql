-- REM Atlas: REM Academy tests, progress, and the Academy scholar tier (CLAUDE.md section 8h).
-- Run once in the Supabase SQL editor.
--
-- Tests are marked here, in the database, so the right answers never reach a browser and
-- nobody can record a pass without taking the test. One attempt per test per 24 hours.
-- Advanced courses (and their exams) need Academy access: the scholar or founder tier.

-- 1. A new membership tier: scholar (£7/month, £60/year), which includes supporter perks.
--    Member limits (10 avatars a week, 10 profiles a day) already apply to any tier.
alter table memberships drop constraint memberships_tier_check;
alter table memberships add constraint memberships_tier_check check (tier in ('supporter', 'scholar', 'founder'));

create or replace function public.has_academy(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.member_tier(uid) in ('scholar', 'founder'), false);
$$;
grant execute on function public.has_academy(uuid) to authenticated;

-- 2. Answer keys. No grants: only the marking function below can read them.
--    answers[i] is the position (counting from 0) of the right option for question i, in the
--    order of src/content/academy-quizzes.ts. Keep the two in step.
create table academy_quizzes (
  slug text primary key,
  advanced boolean not null default false,
  answers int[] not null
);
alter table academy_quizzes enable row level security;

insert into academy_quizzes (slug, advanced, answers) values
  ('sleeping-better', false, '{1,2,1,3,0}'),
  ('remembering-dreams', false, '{2,1,0,3,2}'),
  ('lucid-dreaming', false, '{1,2,0,3,1}'),
  ('what-dreams-are', false, '{1,0,2,3,1}'),
  ('coding-dream-content', true, '{0,2,1,3,0,2,1,2}');

-- 3. Attempts. People read their own; nobody writes directly.
create table academy_results (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  quiz text not null references academy_quizzes(slug),
  score int not null,
  total int not null,
  passed boolean not null,
  taken_at timestamptz not null default now()
);
create index academy_results_user_idx on academy_results(user_id, quiz, taken_at desc);

alter table academy_results enable row level security;
create policy "owner reads own results" on academy_results for select using (auth.uid() = user_id);
grant select on academy_results to authenticated;

-- 4. Mark an attempt. Pass = 80% or more. Returns which answers were right (not what the
--    right answers were), so a retake is still a test.
create or replace function public.submit_academy_quiz(quiz_slug text, picked int[])
returns table (score int, total int, passed boolean, correct boolean[], retry_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  answer_key public.academy_quizzes;
  last_try timestamptz;
  marks boolean[] := '{}';
  points int := 0;
  n int;
begin
  if uid is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  select * into answer_key from public.academy_quizzes where slug = quiz_slug;
  if not found then
    raise exception 'unknown test' using errcode = '22023';
  end if;
  if answer_key.advanced and not public.has_academy(uid) then
    raise exception 'academy access needed' using errcode = '42501';
  end if;
  select max(r.taken_at) into last_try from public.academy_results r where r.user_id = uid and r.quiz = quiz_slug;
  if last_try is not null and last_try > now() - interval '24 hours' then
    raise exception 'retake not open yet' using errcode = 'P0001', hint = 'cooldown';
  end if;

  n := array_length(answer_key.answers, 1);
  if picked is null or coalesce(array_length(picked, 1), 0) <> n then
    raise exception 'answer every question' using errcode = '22023';
  end if;
  for i in 1..n loop
    marks := marks || (picked[i] is not distinct from answer_key.answers[i]);
    if picked[i] is not distinct from answer_key.answers[i] then
      points := points + 1;
    end if;
  end loop;

  insert into public.academy_results (user_id, quiz, score, total, passed)
  values (uid, quiz_slug, points, n, points * 5 >= n * 4);

  return query select points, n, points * 5 >= n * 4, marks, now() + interval '24 hours';
end;
$$;
revoke all on function public.submit_academy_quiz(text, int[]) from public, anon;
grant execute on function public.submit_academy_quiz(text, int[]) to authenticated;

-- 5. Academy progress on public profiles: which tests a person has passed, by username.
--    Only for public profiles; never scores, attempts or failures.
create view public_academy_progress with (security_invoker = off) as
select p.username, array_agg(distinct r.quiz) as passed
from profiles p
join academy_results r on r.user_id = p.user_id and r.passed
where p.profile_public and p.username is not null
group by p.username;

revoke all on public_academy_progress from anon, authenticated;
grant select on public_academy_progress to anon, authenticated;
