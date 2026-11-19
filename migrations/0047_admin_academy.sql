-- Admins can open every Academy course and exam, and skip the level order, so they can review them.
-- Being an admin doesn't change the 24-hour retake wait or the 80% pass mark.
create or replace function public.has_academy(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.member_tier(uid) is not null
    or exists (select 1 from public.site_admins a where a.user_id = uid);
$$;

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
  if answer_key.requires is not null
    and not exists (select 1 from public.site_admins a where a.user_id = uid)
    and not exists (
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
