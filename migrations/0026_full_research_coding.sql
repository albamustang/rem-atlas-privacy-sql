-- REM Atlas: fuller Hall and Van de Castle coding for Scholars (docs/membership-benefits-proposal.md I6).
-- Run once in the Supabase SQL editor.
--
-- Alongside the simple yes/no codes (dreams.codes), Scholar dream profiles code characters,
-- interactions and emotions in more detail (dreams.codes_full), so more of the published
-- indicators can be compared. Private like the simple codes: never in any public view.
-- Turning AI analysis off clears both.

alter table dreams
  add column codes_full jsonb,
  add column coded_full_at timestamptz;

create or replace function public.profiles_clear_codes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ai_analysis and not new.ai_analysis then
    update public.dreams
    set codes = null, coded_at = null, codes_full = null, coded_full_at = null
    where user_id = new.user_id;
  end if;
  return new;
end;
$$;
