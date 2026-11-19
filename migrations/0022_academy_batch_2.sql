-- REM Atlas: exams for nightmares levels 2–3 and sleep science levels 1–3 (CLAUDE.md 8h).
-- Run once in the Supabase SQL editor. Positions count from 0, in the order of
-- src/content/academy-quizzes.ts; `requires` is the level before. Keep the two in step.

insert into academy_quizzes (slug, advanced, answers, requires) values
  ('nightmare-disorder', true, '{1,1,2,0,1,1}', 'nightmares'),
  ('nightmares-research', true, '{0,1,1,2,0,1}', 'nightmare-disorder'),
  ('sleep-stages', true, '{2,1,0,2,1,1}', null),
  ('sleep-regulation', true, '{1,0,3,1,0,1}', 'sleep-stages'),
  ('measuring-sleep', true, '{1,1,0,1,2,1}', 'sleep-regulation');
