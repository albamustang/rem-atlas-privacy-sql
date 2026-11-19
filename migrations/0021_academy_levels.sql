-- REM Atlas: Academy topics in levels, lesson progress, and two new lucid dreaming exams
-- (CLAUDE.md section 8h). Run once in the Supabase SQL editor.
--
-- Each Scholar topic has up to three levels; a level's exam opens once the exam of the level
-- before it has been passed (the database checks this, not just the page). Lessons marked done
-- are saved so people can pick a course up again over several sittings.

-- 1. Levels: which exam must be passed first.
alter table academy_quizzes add column requires text references academy_quizzes(slug);

insert into academy_quizzes (slug, advanced, answers) values
  ('lucid-dreaming-basics', true, '{1,2,1,1,2,1}'),
  ('lucid-dreaming-research', true, '{1,1,2,0,1,1}');

update academy_quizzes set requires = 'lucid-dreaming-basics' where slug = 'lucid-dreaming-programme';
update academy_quizzes set requires = 'lucid-dreaming-programme' where slug = 'lucid-dreaming-research';

-- 2. Marking now also checks the level before has been passed.
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
  if answer_key.requires is not null and not exists (
    select 1 from public.academy_results r
    where r.user_id = uid and r.quiz = answer_key.requires and r.passed
  ) then
    raise exception 'pass the level before first' using errcode = '42501', hint = 'level';
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

-- 3. Lessons marked done, per person. Private to the owner.
create table academy_progress (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  course text not null,
  lesson int not null check (lesson between 1 and 100),
  done_at timestamptz not null default now(),
  primary key (user_id, course, lesson)
);
alter table academy_progress enable row level security;
create policy "owner reads own progress" on academy_progress for select using (auth.uid() = user_id);
create policy "owner marks own progress" on academy_progress for insert with check (auth.uid() = user_id);
create policy "owner updates own progress" on academy_progress for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner clears own progress" on academy_progress for delete using (auth.uid() = user_id);
grant select, insert, update, delete on academy_progress to authenticated;
