-- Home feed choices (2026-11-16; docs/home-feed-plan.md, session 2). Two kinds of row:
--   dismissed: one card instance you've closed, e.g. 'lesson:dreams-that-came-true/1'; it stays away.
--   fewer: a whole card type you'd rather not see, e.g. 'type:lesson'.
-- Owner only. Holds no dream text: just card keys made by the site.

create table public.feed_prefs (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  card_key text not null check (card_key ~ '^[a-z0-9:/_.-]{1,120}$'),
  kind text not null check (kind in ('dismissed', 'fewer')),
  at timestamptz not null default now(),
  primary key (user_id, card_key)
);
alter table public.feed_prefs enable row level security;
create policy "owner reads own feed prefs" on public.feed_prefs for select using (auth.uid() = user_id);
create policy "owner adds own feed prefs" on public.feed_prefs for insert with check (auth.uid() = user_id);
create policy "owner removes own feed prefs" on public.feed_prefs for delete using (auth.uid() = user_id);
grant select, insert, delete on public.feed_prefs to authenticated;

-- Keep it small: 500 rows per person, oldest dismissals dropped first.
create function public.feed_prefs_trim() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.feed_prefs where user_id = new.user_id and card_key in (
    select card_key from public.feed_prefs where user_id = new.user_id
    order by (kind = 'fewer') desc, at desc offset 500
  );
  return new;
end;
$$;
revoke all on function public.feed_prefs_trim() from public, anon, authenticated;
create trigger feed_prefs_trim after insert on public.feed_prefs for each row execute function public.feed_prefs_trim();
