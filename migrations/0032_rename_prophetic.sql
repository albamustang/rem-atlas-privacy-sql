-- REM Atlas: rename the dream category "prophetic" to "seemed to come true" (CLAUDE.md section 6).
-- It describes what the dreamer experienced without claiming dreams can predict anything, in line
-- with the site's tone rule and Paddle's ban on fortune-telling services. Run once in the Supabase
-- SQL editor. No dream used the old value when this was written; if one has since, adding the new
-- rule fails and nothing changes, so check that dream first.

alter table dreams drop constraint dreams_category_check;
alter table dreams add constraint dreams_category_check check (category in (
  'lucid', 'nightmare', 'recurring', 'seemed to come true', 'mundane', 'fantastical', 'symbolic'
));
