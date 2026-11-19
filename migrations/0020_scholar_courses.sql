-- REM Atlas: answer keys for three more Scholar course exams (CLAUDE.md section 8h).
-- Run once in the Supabase SQL editor. Positions count from 0, in the order of
-- src/content/academy-quizzes.ts. Keep the two in step.

insert into academy_quizzes (slug, advanced, answers) values
  ('reading-dream-statistics', true, '{1,0,2,2,1,1}'),
  ('lucid-dreaming-programme', true, '{1,1,3,1,0,2}'),
  ('nightmares', true, '{2,1,0,1,0,1}');
