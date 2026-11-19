-- REM Atlas: exams for coding dream content levels 2-3, research methods levels 2-3 and sleep
-- disorders levels 1-3 (CLAUDE.md 8h). Run once in the Supabase SQL editor. Positions count from
-- 0, in the order of src/content/academy-quizzes.ts; `requires` is the level before.

insert into academy_quizzes (slug, advanced, answers, requires) values
  ('coding-characters', true, '{0,2,0,1,2,2}', 'coding-dream-content'),
  ('coding-research', true, '{1,0,2,1,1,2}', 'coding-characters'),
  ('research-designs', true, '{0,2,1,1,2,0}', 'reading-dream-statistics'),
  ('research-replication', true, '{1,2,1,0,2,1}', 'research-designs'),
  ('sleep-disorders-overview', true, '{2,1,0,1,2,0}', null),
  ('sleep-paralysis', true, '{0,1,1,2,0,2}', 'sleep-disorders-overview'),
  ('rem-behaviour-disorder', true, '{0,1,2,1,3,0}', 'sleep-paralysis');
