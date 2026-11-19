-- REM Atlas: fix the avatar pixel checks from 0009.
-- Run once in the Supabase SQL editor.
--
-- 0009 checked pixels with the pattern '^[0-9a-c]{256}$', but Postgres patterns can't count
-- above 255, so every save failed with "invalid repetition count". Check the length and the
-- allowed characters separately instead: same rule, written so Postgres accepts it.

alter table avatar_generations drop constraint if exists avatar_generations_pixels_check;
alter table avatar_generations add constraint avatar_generations_pixels_check
  check (length(pixels) = 256 and pixels ~ '^[0-9a-c]+$');

alter table profiles drop constraint if exists profiles_avatar_pixels_check;
alter table profiles add constraint profiles_avatar_pixels_check
  check (length(avatar_pixels) = 256 and avatar_pixels ~ '^[0-9a-c]+$');
