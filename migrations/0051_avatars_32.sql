-- REM Atlas: AI avatars become 32x32 (9 November 2026). Pixels are stored the same way (one
-- palette character per pixel), so a 32x32 avatar is 1024 characters. Older AI avatars and the
-- free pattern stay 16x16 (256), and both sizes remain valid.

alter table avatar_generations drop constraint if exists avatar_generations_pixels_check;
alter table avatar_generations add constraint avatar_generations_pixels_check
  check (length(pixels) in (256, 1024) and pixels ~ '^[0-9a-c]+$');

alter table profiles drop constraint if exists profiles_avatar_pixels_check;
alter table profiles add constraint profiles_avatar_pixels_check
  check (length(avatar_pixels) in (256, 1024) and avatar_pixels ~ '^[0-9a-c]+$');
