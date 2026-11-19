-- REM Academy spaced review (16 Nov 2026). A few questions from courses you've already passed come
-- back days later, so the learning sticks. Answer keys stay in the database: this only says whether
-- one answer is right, and only for a test you have already passed, so it can't be used to learn
-- the answers to a test you haven't. Nothing is stored.

create function public.review_answer(p_quiz text, p_index int, p_choice int)
returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare key int[];
begin
  if auth.uid() is null then raise exception 'log in first' using errcode = '42501'; end if;
  if not exists (select 1 from public.academy_results r where r.user_id = auth.uid() and r.quiz = p_quiz and r.passed) then
    raise exception 'review is for tests you have passed' using errcode = '42501';
  end if;
  select q.answers into key from public.academy_quizzes q where q.slug = p_quiz;
  if key is null or p_index < 0 or p_index >= array_length(key, 1) then return null; end if;
  return key[p_index + 1] = p_choice;
end;
$$;
revoke all on function public.review_answer(text, int, int) from public, anon;
grant execute on function public.review_answer(text, int, int) to authenticated;
