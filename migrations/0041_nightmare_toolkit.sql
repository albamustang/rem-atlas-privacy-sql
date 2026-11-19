-- REM Atlas: nightmare toolkit (CLAUDE.md section 8n, step 6). Run once in the Supabase SQL editor.
--
-- A saved imagery rehearsal script (the rewritten version of a nightmare) and the days it was
-- rehearsed. Health-related, so owner only: never public, never on the map, never sent to AI.
-- Writing a new script needs a membership. Someone whose membership lapses keeps reading,
-- rehearsing and deleting what they already have, because stopping that could leave them worse off.

create table nightmare_scripts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  dream_id uuid references dreams(id) on delete set null,
  new_version text not null check (char_length(new_version) between 1 and 5000),
  created_at timestamptz not null default now()
);
create index nightmare_scripts_user_idx on nightmare_scripts(user_id);

create table nightmare_rehearsals (
  script_id uuid not null references nightmare_scripts(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day date not null default current_date,
  primary key (script_id, day)
);

alter table nightmare_scripts enable row level security;
create policy "owner reads own scripts" on nightmare_scripts for select using (auth.uid() = user_id);
create policy "owner writes own scripts" on nightmare_scripts for insert with check (auth.uid() = user_id);
create policy "owner edits own scripts" on nightmare_scripts for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner deletes own scripts" on nightmare_scripts for delete using (auth.uid() = user_id);
grant select, insert, update, delete on nightmare_scripts to authenticated;

alter table nightmare_rehearsals enable row level security;
create policy "owner reads own rehearsals" on nightmare_rehearsals for select using (auth.uid() = user_id);
create policy "owner logs own rehearsals" on nightmare_rehearsals for insert with check (
  auth.uid() = user_id
  and day between current_date - 1 and current_date + 1
  and exists (select 1 from nightmare_scripts s where s.id = script_id and s.user_id = auth.uid())
);
create policy "owner deletes own rehearsals" on nightmare_rehearsals for delete using (auth.uid() = user_id);
grant select, insert, delete on nightmare_rehearsals to authenticated;

-- New scripts: members only, at most 10 kept, linked only to the person's own dream.
create or replace function public.nightmare_scripts_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is distinct from auth.uid() then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  new.created_at := now();
  if public.member_tier(new.user_id) is null then
    raise exception 'Saving a rehearsal script needs a membership.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.nightmare_scripts where user_id = new.user_id) >= 10 then
    raise exception 'Delete a script before adding another.' using errcode = 'P0001';
  end if;
  if new.dream_id is not null and not exists (
    select 1 from public.dreams d where d.id = new.dream_id and d.user_id = new.user_id
  ) then
    raise exception 'That dream was not found.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger nightmare_scripts_guard
  before insert on nightmare_scripts
  for each row execute function public.nightmare_scripts_guard();

-- Edits can't move a script to another person or dream.
create or replace function public.nightmare_scripts_pin()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.user_id := old.user_id;
  new.dream_id := case when new.dream_id is null then null else old.dream_id end;
  new.created_at := old.created_at;
  return new;
end;
$$;

create trigger nightmare_scripts_pin
  before update on nightmare_scripts
  for each row execute function public.nightmare_scripts_pin();
