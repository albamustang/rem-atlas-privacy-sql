-- REM Atlas: exams for the last Academy batch: dreams across the lifespan, dreams and emotion,
-- dreams in history and culture, and sleep and memory, levels 1-3 each (CLAUDE.md 8h). Run once
-- in the Supabase SQL editor. Positions count from 0, in the order of src/content/academy-quizzes.ts;
-- `requires` is the level before.

insert into academy_quizzes (slug, advanced, answers, requires) values
  ('children-dreams', true, '{1,2,0,3,1,2}', null),
  ('dreams-and-ageing', true, '{0,2,1,3,1,0}', 'children-dreams'),
  ('lifespan-research', true, '{0,1,2,3,0,3}', 'dreams-and-ageing'),
  ('dream-emotions', true, '{2,0,1,3,1,0}', null),
  ('stress-and-dreams', true, '{2,1,0,3,1,2}', 'dream-emotions'),
  ('dreams-mental-health', true, '{1,0,3,0,1,3}', 'stress-and-dreams'),
  ('dreams-in-history', true, '{0,1,2,0,3,1}', null),
  ('dreams-across-cultures', true, '{1,0,2,3,0,1}', 'dreams-in-history'),
  ('culture-evidence', true, '{2,0,1,3,0,2}', 'dreams-across-cultures'),
  ('sleep-memory-basics', true, '{0,1,2,3,0,2}', null),
  ('memory-consolidation', true, '{0,1,2,3,0,1}', 'sleep-memory-basics'),
  ('dreams-and-memory', true, '{2,0,1,3,0,1}', 'memory-consolidation');
