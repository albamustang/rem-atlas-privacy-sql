-- REM Atlas: AI history kept for members (his rule, 9 November 2026).
-- AI avatars: members keep every avatar they've made and can switch to any of them; everyone else
-- keeps their 3 most recent (older ones are deleted when a new one is made, and once now).
-- Dream pictures: members keep every painting of each dream; everyone else keeps the 3 most recent
-- of each dream. Picture files are removed by the server (it holds the storage key), so the
-- database only allows the server to delete those rows.

-- Avatar edits: a new avatar can record which of your avatars it was edited from.
alter table avatar_generations add column if not exists edited_from bigint references avatar_generations(id) on delete set null;

-- Choosing an avatar: any of your own for members, your 3 most recent otherwise.
create or replace function public.profiles_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.user_id := coalesce(old.user_id, new.user_id);
  new.updated_at := now();
  if public.is_unsuitable_text(new.username) or public.is_unsuitable_text(new.bio) then
    raise exception 'username or bio contains unsuitable words';
  end if;
  if new.avatar_pixels is not null and new.avatar_pixels is distinct from old.avatar_pixels then
    if public.member_tier(new.user_id) is not null then
      if not exists (select 1 from public.avatar_generations
                     where user_id = new.user_id and pixels = new.avatar_pixels) then
        raise exception 'avatar must be one of your own AI avatars';
      end if;
    elsif not exists (
      select 1 from (
        select pixels from public.avatar_generations
        where user_id = new.user_id and pixels is not null
        order by created_at desc limit 3
      ) as recent
      where recent.pixels = new.avatar_pixels
    ) then
      raise exception 'avatar must be one of your 3 most recent AI avatars';
    end if;
  end if;
  return new;
end;
$$;

-- When an avatar finishes, non-members' older finished avatars beyond the newest 3 are deleted.
-- Unfinished or failed attempts are left alone (they matter for the weekly limit).
create or replace function public.avatar_generations_trim()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.pixels is not null and old.pixels is null and public.member_tier(new.user_id) is null then
    delete from public.avatar_generations g
    where g.user_id = new.user_id and g.pixels is not null
      and g.id not in (
        select id from public.avatar_generations
        where user_id = new.user_id and pixels is not null
        order by created_at desc limit 3
      );
  end if;
  return null;
end;
$$;
revoke all on function public.avatar_generations_trim() from public, anon, authenticated;
drop trigger if exists avatar_generations_trim on avatar_generations;
create trigger avatar_generations_trim after update of pixels on avatar_generations
  for each row execute function public.avatar_generations_trim();

-- Once now: non-members keep only their 3 most recent finished avatars.
delete from avatar_generations g
where g.pixels is not null
  and public.member_tier(g.user_id) is null
  and g.id not in (
    select id from (
      select id, row_number() over (partition by user_id order by created_at desc) as n
      from avatar_generations where pixels is not null
    ) ranked where n <= 3
  );

-- Dream pictures: the server deletes older paintings (and their files) for non-members.
grant delete on public.dream_pictures to service_role;
