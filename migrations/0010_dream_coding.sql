-- REM Atlas: AI coding of dreams into Hall & Van de Castle-style categories (CLAUDE.md 8d).
-- Run once in the Supabase SQL editor.
--
-- `codes` holds yes/no answers (aggression, friendliness, sexuality, misfortune, success,
-- failure, indoor and familiar setting) worked out from the description after saving.
-- They feed only the owner's own dream profile: the public view never shows them.
-- People can turn analysis off; their codes are then cleared.

alter table dreams
  add column codes jsonb,
  add column coded_at timestamptz;

alter table profiles add column ai_analysis boolean not null default true;

-- Turning analysis off removes codes already worked out, so the choice really sticks.
create or replace function public.profiles_clear_codes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ai_analysis and not new.ai_analysis then
    update public.dreams set codes = null, coded_at = null where user_id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger profiles_clear_codes
  after update of ai_analysis on profiles
  for each row execute function public.profiles_clear_codes();
