-- A read-only login for the backup script (docs/backup-plan.md, stage 1).
--
-- There is no password in this file, so the role can't log in yet. He sets one himself with
-- psql's \password, never in the SQL editor, which keeps a history of what is run there.
--
-- BYPASSRLS: the backup must include everyone's rows, and row level security would otherwise
-- hide them or make pg_dump stop. So this role can read every dream: treat its password like
-- the database password.

create role backup_reader
  login
  noinherit
  nosuperuser
  nocreatedb
  nocreaterole
  noreplication
  bypassrls
  connection limit 3;

-- Every session starts read-only.
alter role backup_reader set default_transaction_read_only = on;

grant usage on schema public, auth to backup_reader;

grant select on all tables in schema public to backup_reader;
grant select on all sequences in schema public to backup_reader;

-- Only the 2 auth tables needed to bring accounts back. Sessions, tokens and audit logs stay out.
grant select on auth.users, auth.identities to backup_reader;

-- Tables added by later migrations are readable too, so a new table can't quietly break backups.
alter default privileges in schema public grant select on tables to backup_reader;
alter default privileges in schema public grant select on sequences to backup_reader;
