-- REM Atlas: exams for the Academy topic "Dreams and the paranormal", levels 1 (free), 2 and 3
-- (members); plan in docs/parapsychology-plan.md. Run once in the Supabase SQL editor. Positions
-- count from 0, in the order of src/content/academy-quizzes.ts; `requires` is the level before.

insert into academy_quizzes (slug, advanced, answers, requires) values
  ('dreams-that-came-true', false, '{1,2,0,3,0,2}', null),
  ('dream-telepathy-experiments', true, '{1,2,0,3,0,1}', 'dreams-that-came-true'),
  ('reading-the-evidence', true, '{1,0,2,3,0,1}', 'dream-telepathy-experiments');
