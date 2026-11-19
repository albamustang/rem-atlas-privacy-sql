-- REM Atlas: let the public view read every dream, showing only its safe columns.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- New Supabase projects create views that check the *visitor's* rights on the
-- underlying table, so visitors were refused. public_dreams is meant to run with its
-- owner's rights instead: that is how private dreams still count on the map while
-- their text (and every user_id) stays hidden. Supabase's advisor will flag this as a
-- "security definer view"; here it is deliberate.
alter view public_dreams set (security_invoker = off);
