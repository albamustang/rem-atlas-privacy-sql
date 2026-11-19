-- 0059: the weekly dream letter, a member perk (sent on Sunday mornings).
-- On by default for members; anyone can switch it off in profile settings or from the email.
-- The letter is built by the server from the person's own logs; it never contains dream text.

alter table public.profiles
  add column if not exists weekly_letter boolean not null default true,
  add column if not exists letter_last_sent date;

-- Members (paid, trial or bonus time) whose local time is Sunday 09:00 or later, who haven't had a
-- letter in the last 6 days and have logged something in the last 28 days. Marks them sent in the
-- same statement, so overlapping runs can't send twice.
create or replace function public.claim_due_letters(max_rows int default 90)
returns table (user_id uuid, email text, tz text)
language sql
security definer
set search_path = ''
as $$
  with due as (
    select p.user_id, u.email, p.reminder_tz as tz,
           (now() at time zone p.reminder_tz)::date as local_today
    from public.profiles p
    join auth.users u on u.id = p.user_id
    where p.weekly_letter
      and u.email is not null
      and u.email_confirmed_at is not null
      and public.member_tier(p.user_id) is not null
      and extract(dow from now() at time zone p.reminder_tz) = 0
      and extract(hour from now() at time zone p.reminder_tz) >= 9
      and (p.letter_last_sent is null or p.letter_last_sent <= (now() at time zone p.reminder_tz)::date - 6)
      and (
        exists (select 1 from public.dreams d where d.user_id = p.user_id and d.created_at > now() - interval '28 days')
        or exists (select 1 from public.sleep_nights s where s.user_id = p.user_id and s.created_at > now() - interval '28 days')
      )
    limit max_rows
    for update of p skip locked
  )
  update public.profiles p
  set letter_last_sent = due.local_today
  from due
  where p.user_id = due.user_id
  returning p.user_id, due.email, due.tz;
$$;
revoke all on function public.claim_due_letters(int) from public, anon, authenticated;
grant execute on function public.claim_due_letters(int) to service_role;

-- The signed "stop" link in the letter (checked by the server before calling this).
create or replace function public.stop_letters(uid uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles set weekly_letter = false where user_id = uid;
$$;
revoke all on function public.stop_letters(uuid) from public, anon, authenticated;
grant execute on function public.stop_letters(uuid) to service_role;
