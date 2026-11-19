-- REM Atlas: explicit-content filter.
-- Run once in the Supabase SQL editor.
--
-- The owner always keeps their original description. The public now sees:
--   - public_description: the original with swear words masked ("f***"), made by the website;
--   - nothing at all if the dream is explicit (is_explicit) or private.
-- Explicit dreams still count on the map and in statistics.

alter table dreams
  add column public_description text,
  add column is_explicit boolean not null default false;

-- Existing dreams: copy the text across (the only dream so far was checked by hand: clean).
update dreams set public_description = description;

-- ---------------------------------------------------------------------------
-- Backstop. The website does the real filtering, but anyone signed in could write to the
-- database directly with the site's public key. These checks make sure that, even then,
-- the public copy can only ever be the original with some letters starred out, and that
-- obviously explicit dreams are always flagged.
-- ---------------------------------------------------------------------------

-- Is `masked` the same text as `original`, with only some characters replaced by '*'?
create or replace function public.is_masked_copy(original text, masked text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select length(original) = length(masked) and not exists (
    select 1 from generate_series(1, length(original)) as i
    where substr(masked, i, 1) <> substr(original, i, 1) and substr(masked, i, 1) <> '*'
  );
$$;

-- Keep this word list in step with src/lib/moderation/explicit-terms.ts.
create or replace function public.dreams_moderation_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.public_description is not null
     and not public.is_masked_copy(new.description, new.public_description) then
    raise exception 'public_description must be the description with only characters masked';
  end if;

  if new.description ~* '\m(withheld)\M' /* the explicit-content word list is withheld from this public copy: published, it would be a guide to getting round it. The rule itself is unchanged. */ then
    new.is_explicit := true;
  end if;

  return new;
end;
$$;

create trigger dreams_moderation_guard
  before insert or update on dreams
  for each row execute function public.dreams_moderation_guard();

-- ---------------------------------------------------------------------------
-- Public view, now reading the masked copy. Private and explicit descriptions are blank.
-- is_explicit here is only true for public dreams, so the feed can say "hidden: explicit
-- content" without revealing anything about private dreams.
-- ---------------------------------------------------------------------------
create or replace view public_dreams with (security_invoker = off) as
select id,
       case when is_private or is_explicit then null else public_description end as description,
       emotion, category, clarity, city_id, dream_date, keywords,
       (is_explicit and not is_private) as is_explicit
from dreams;
