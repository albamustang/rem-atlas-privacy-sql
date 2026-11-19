-- REM Atlas: AI keyword suggestions (CLAUDE.md section 8).
-- Run once in the Supabase SQL editor.
--
-- When a dream's keywords last came from AI. Editing a dream only asks the AI again if
-- this is more than 24 hours old, so repeated edits can't run up the API bill.
alter table dreams add column keywords_ai_at timestamptz;

-- The edit history (0006) shouldn't record a new version when only the keywords change
-- (AI keywords arrive a moment after saving). Same function as before, with keywords left
-- out of the "did anything change?" comparison.
create or replace function public.dreams_record_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.id := old.id;
  new.user_id := old.user_id;
  new.created_at := old.created_at;

  if (new.description, new.is_private, new.is_explicit, new.emotion, new.category, new.clarity,
      new.city_id, new.dream_date, new.public_description)
     is not distinct from
     (old.description, old.is_private, old.is_explicit, old.emotion, old.category, old.clarity,
      old.city_id, old.dream_date, old.public_description) then
    new.edited_at := old.edited_at;
    return new; -- nothing a person would call an edit
  end if;

  insert into public.dream_revisions (
    dream_id, user_id, description, public_description, is_private, is_explicit,
    emotion, category, clarity, city_id, dream_date, keywords
  ) values (
    old.id, old.user_id, old.description, old.public_description, old.is_private, old.is_explicit,
    old.emotion, old.category, old.clarity, old.city_id, old.dream_date, old.keywords
  );

  if (new.description, new.emotion, new.category, new.clarity, new.city_id, new.dream_date)
     is distinct from
     (old.description, old.emotion, old.category, old.clarity, old.city_id, old.dream_date) then
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;

  return new;
end;
$$;
