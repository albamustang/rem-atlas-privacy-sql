-- REM Atlas: founding badges for everyone who joins during the open beta (decided 2026-11-09).
-- Until now only the first 100 paying members got a founding number. While site_settings
-- 'beta_open' is true, everyone who becomes a paying member (member or patron) gets one, kept for
-- good. When the beta ends: update site_settings set value = false where key = 'beta_open';
-- after that the old rule (first 100 only) applies again. Free trials never get a number.

insert into public.site_settings (key, value) values ('beta_open', true)
on conflict (key) do nothing;

create or replace function public.memberships_founding_number()
returns trigger
language plpgsql
security definer -- reads site_settings, which has no policies (the webhook writes as service_role)
set search_path = ''
as $$
begin
  new.updated_at := now();
  if new.founding_number is null and new.status in ('active', 'trialing')
     and (coalesce((select value from public.site_settings where key = 'beta_open'), false)
          or (select count(*) from public.memberships where founding_number is not null) < 100) then
    new.founding_number := coalesce((select max(founding_number) from public.memberships), 0) + 1;
  end if;
  return new;
end;
$$;
revoke all on function public.memberships_founding_number() from public, anon, authenticated;

-- Anyone already paying without a number gets one now, oldest first (their dates stay as they are).
alter table public.memberships disable trigger memberships_founding_number;
update public.memberships m
set founding_number = n.num
from (
  select user_id,
         coalesce((select max(founding_number) from public.memberships), 0)
           + row_number() over (order by updated_at, user_id) as num
  from public.memberships
  where founding_number is null and status in ('active', 'trialing', 'past_due')
) n
where m.user_id = n.user_id;
alter table public.memberships enable trigger memberships_founding_number;
