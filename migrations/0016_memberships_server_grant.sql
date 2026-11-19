-- REM Atlas: let the server record memberships.
-- Run once in the Supabase SQL editor.
--
-- This project doesn't expose new tables automatically, and that includes the server's own
-- secret-key role (service_role). 0014 forgot to grant it, so the Paddle webhook got
-- "permission denied for table memberships" and couldn't record anyone's membership.
grant select, insert, update on memberships to service_role;
