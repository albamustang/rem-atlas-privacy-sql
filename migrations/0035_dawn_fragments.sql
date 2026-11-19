-- Dawn mode: a half-asleep note saved against a night, finished as a full dream later. It lives on
-- the night's owner-only row, so it's never public, never on the map and never sent to AI until it
-- becomes a dream. The row counts towards consistency awards, like a no-recall night.
alter table public.sleep_nights
  add column if not exists fragment text;

alter table public.sleep_nights
  drop constraint if exists sleep_nights_fragment_check;

alter table public.sleep_nights
  add constraint sleep_nights_fragment_check
  check (fragment is null or (char_length(fragment) between 1 and 5000 and not no_recall));
