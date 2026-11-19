-- Comments only on members' dreams (Ofcom draft, 2026-11-09). Comment writers are already adult
-- members; this stops them being able to comment on a dream belonging to a 16 or 17-year-old, by
-- letting only members (18+) switch comments on, and refusing any new comment on a dream whose
-- owner isn't a member now (covers lapsed members and switches set before this change).

drop policy if exists "owner sets switch" on comment_enabled;
create policy "member owner sets switch" on comment_enabled for insert with check (
  auth.uid() = user_id
  and public.member_tier(auth.uid()) is not null
  and exists (select 1 from public.dreams d where d.id = dream_id and d.user_id = auth.uid())
);

create or replace function public.dream_comments_owner_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.member_tier((select d.user_id from public.dreams d where d.id = new.dream_id)) is null then
    raise exception 'Comments are off for this dream.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.dream_comments_owner_member() from public, anon, authenticated;

drop trigger if exists dream_comments_owner_member on dream_comments;
create trigger dream_comments_owner_member before insert on dream_comments
  for each row execute function public.dream_comments_owner_member();
