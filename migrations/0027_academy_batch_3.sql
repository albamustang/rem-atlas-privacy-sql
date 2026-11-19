-- REM Atlas: exams for dream recall, theories of dreaming and the neuroscience of dreaming,
-- levels 1-3 each (CLAUDE.md 8h). Run once in the Supabase SQL editor. Positions count from 0,
-- in the order of src/content/academy-quizzes.ts; `requires` is the level before.

insert into academy_quizzes (slug, advanced, answers, requires) values
  ('recall-basics', true, '{1,1,0,1,0,1}', null),
  ('recall-variation', true, '{1,0,2,0,2,1}', 'recall-basics'),
  ('recall-research', true, '{0,1,2,1,3,1}', 'recall-variation'),
  ('theories-overview', true, '{1,0,2,1,2,0}', null),
  ('theories-evidence', true, '{0,1,2,0,3,1}', 'theories-overview'),
  ('theories-debates', true, '{0,1,1,2,1,0}', 'theories-evidence'),
  ('brain-basics', true, '{0,1,0,2,1,0}', null),
  ('brain-methods', true, '{0,1,3,0,1,2}', 'brain-basics'),
  ('brain-frontiers', true, '{0,1,2,0,1,3}', 'brain-methods');
