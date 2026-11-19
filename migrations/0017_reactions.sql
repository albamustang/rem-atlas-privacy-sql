-- REM Atlas: reactions on public dreams (CLAUDE.md section 8g).
-- Run once in the Supabase SQL editor.
--
-- A small fixed set, no free text. Only public, non-explicit dreams can be reacted to, never
-- your own, one of each kind per person. The public only ever sees counts, never who reacted.

create table dream_reactions (
  dream_id uuid not null references dreams(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null check (kind in ('dreamt_too', 'vivid', 'unsettling', 'beautiful', 'curious')),
  created_at timestamptz not null default now(),
  primary key (dream_id, user_id, kind)
);
create index dream_reactions_dream_idx on dream_reactions(dream_id);

-- Can the signed-in person react to this dream? (They can't read other people's dreams
-- directly, so this checks on their behalf.)
create or replace function public.can_react_to(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.dreams
    where id = target and not is_private and not is_explicit and user_id <> auth.uid()
  );
$$;
grant execute on function public.can_react_to(uuid) to authenticated;

alter table dream_reactions enable row level security;
create policy "people read their own reactions" on dream_reactions
  for select using (auth.uid() = user_id);
create policy "people react to public dreams" on dream_reactions
  for insert with check (auth.uid() = user_id and public.can_react_to(dream_id));
create policy "people remove their own reactions" on dream_reactions
  for delete using (auth.uid() = user_id);
grant select, insert, delete on dream_reactions to authenticated;

-- Counts for everyone. If a dream later becomes private or explicit, its counts disappear
-- from view (the rows stay, and come back if it is made public again).
create view public_reaction_counts with (security_invoker = off) as
select r.dream_id, r.kind, count(*)::int as count
from dream_reactions r
join dreams d on d.id = r.dream_id
where not d.is_private and not d.is_explicit
group by r.dream_id, r.kind;

revoke all on public_reaction_counts from anon, authenticated;
grant select on public_reaction_counts to anon, authenticated;
