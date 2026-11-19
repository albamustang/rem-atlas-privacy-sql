-- REM Atlas: exams for the Academy topic "Body clocks, naps and chronotypes" (16 Nov 2026), level 1
-- (free), 2 and 3 (members). Run once in the Supabase SQL editor. Positions count from 0, in the
-- order of src/content/academy-quizzes.ts; `requires` is the level before.

insert into academy_quizzes (slug, advanced, answers, requires) values
  ('body-clock-basics', false, '{1,2,0,3,1,2}', null),
  ('larks-owls-social-jetlag', true, '{2,0,3,1,0,2}', 'body-clock-basics'),
  ('naps-and-measuring-clocks', true, '{1,3,0,2,1,0}', 'larks-owls-social-jetlag');
