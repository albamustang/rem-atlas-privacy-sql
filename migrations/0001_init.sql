-- REM Atlas: initial database setup (CLAUDE.md section 7).
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.

-- ---------------------------------------------------------------------------
-- Cities: reference table the location autocomplete reads from.
-- ---------------------------------------------------------------------------
create table cities (
  id serial primary key,
  name text not null,
  country text not null,
  lat double precision not null,
  lon double precision not null
);
create index cities_name_idx on cities using gin (to_tsvector('simple', name));

-- Anyone may read cities; nobody can change them through the website.
-- (Supabase exposes every table to the browser, so a table without RLS is writable by anyone.)
alter table cities enable row level security;
create policy "anyone reads cities" on cities
  for select using (true);

-- ---------------------------------------------------------------------------
-- Dreams
-- ---------------------------------------------------------------------------
create table dreams (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  description text not null check (char_length(description) between 1 and 5000),
  is_private boolean not null default false,
  emotion text not null check (emotion in (
    'peaceful', 'happy', 'excited', 'euphoric', 'loved', 'curious', 'neutral',
    'confused', 'anxious', 'fearful', 'terrified', 'sad', 'melancholic', 'angry'
  )),
  category text not null check (category in (
    'lucid', 'nightmare', 'recurring', 'prophetic', 'mundane', 'fantastical', 'symbolic'
  )),
  clarity text not null check (clarity in ('vivid', 'clear', 'moderate', 'hazy', 'fragmented')),
  city_id int references cities(id),
  -- The database clock is UTC, so allow one day of slack for dreamers in time zones ahead of it.
  dream_date date not null check (dream_date <= current_date + 1),
  keywords text[] not null default '{}' check (cardinality(keywords) <= 8),
  created_at timestamptz not null default now()
);
create index dreams_user_idx on dreams(user_id);
create index dreams_date_idx on dreams(dream_date);
create index dreams_keywords_idx on dreams using gin (keywords);

-- One submission per user per dream date, to stop people skewing the data.
create unique index one_dream_per_user_per_day on dreams(user_id, dream_date);

-- ---------------------------------------------------------------------------
-- Row Level Security: people can only see, add and delete their own dreams.
-- ---------------------------------------------------------------------------
alter table dreams enable row level security;

create policy "owner reads own dreams" on dreams
  for select using (auth.uid() = user_id);

create policy "owner inserts own dreams" on dreams
  for insert with check (auth.uid() = user_id);

create policy "owner deletes own dreams" on dreams
  for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Table access. New tables are not exposed to the website automatically
-- (project setting), so grant exactly what each role needs. RLS above still
-- decides which rows each signed-in person can touch.
-- ---------------------------------------------------------------------------
grant select on cities to anon, authenticated;
grant select, insert, delete on dreams to authenticated;

-- ---------------------------------------------------------------------------
-- Public view: what the map and public feed read.
-- Private dreams still count (emotion, city, date, keywords) but their text is blanked,
-- and user_id is never exposed. The view deliberately runs with its owner's rights so it
-- can see every row; that is safe only because of the columns it chooses to show.
-- ---------------------------------------------------------------------------
create view public_dreams as
select id,
       case when is_private then null else description end as description,
       emotion, category, clarity, city_id, dream_date, keywords
from dreams;

-- Read-only for everyone.
revoke all on public_dreams from anon, authenticated;
grant select on public_dreams to anon, authenticated;
