-- REM Atlas: typical dreams checklist (CLAUDE.md section 8n, step 2). Run once in the Supabase SQL editor.
--
-- One row per person: which of the 55 typical dream themes they have ever dreamed. Owner only:
-- never public, never on the map, never sent to AI. Comparisons with the published sample are
-- worked out in the app from this row alone. Theme keys are defined in src/lib/tdq.ts.

create table tdq_answers (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  themes text[] not null default '{}',
  version smallint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tdq_answers_themes_check check (
    cardinality(themes) <= 55
    and themes <@ array[
      'chased','attacked','trying-again','frozen','delicious','late','swimming','locked-in','snakes','money',
      'flying','falling','wrong-clothes','naked','tied','genius','hybrids','teeth','mirror','magic',
      'flood','tornado','earthquake','insects','opposite-sex','object','killed','self-dead','presence','toilet',
      'school','sex','vehicle','fire','dead-alive','alive-dead','about-to-fall','exam','suffocating','beasts',
      'cinema','killing','deranged','paralysed','close-face','ufo','aliens','other-planet','animal','child-again',
      'angel','god','new-room','crash','abortion'
    ]::text[]
  )
);

alter table tdq_answers enable row level security;
create policy "owner reads own answers" on tdq_answers for select using (auth.uid() = user_id);
create policy "owner saves own answers" on tdq_answers for insert with check (auth.uid() = user_id);
create policy "owner changes own answers" on tdq_answers for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner deletes own answers" on tdq_answers for delete using (auth.uid() = user_id);
grant select, insert, update, delete on tdq_answers to authenticated;

-- Timestamps come from the database clock.
create or replace function public.tdq_answers_stamp()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger tdq_answers_stamp
  before insert or update on tdq_answers
  for each row execute function public.tdq_answers_stamp();
