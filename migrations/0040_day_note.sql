-- REM Atlas: "what happened today" (CLAUDE.md section 8n, step 3). Run once in the Supabase SQL editor.
--
-- One short line about the day before the night, kept on the owner-only sleep_nights row like the
-- sleep diary answers: never public, never on the map, never sent to AI. Collected now; any
-- analysis (dream-lag, "why did I dream that?") comes later and only ever as description.
alter table public.sleep_nights
  add column if not exists day_note text;

alter table public.sleep_nights
  drop constraint if exists sleep_nights_day_note_check;

alter table public.sleep_nights
  add constraint sleep_nights_day_note_check
  check (day_note is null or char_length(day_note) between 1 and 280);
