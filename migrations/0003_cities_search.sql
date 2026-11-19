-- REM Atlas: extra city columns for the location autocomplete.
-- Run once in the Supabase SQL editor, before supabase/seed/cities.sql.

-- ascii_name lets "Sao Paulo" find "São Paulo"; region tells the three Springfields apart;
-- population puts the most likely match first.
alter table cities
  add column ascii_name text,
  add column region text,
  add column population int not null default 0;
