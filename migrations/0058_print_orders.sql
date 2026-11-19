-- Printed dreams, first product: the Dream Card (a folded card in an envelope, printed and posted by
-- Prodigi). One row per order. Owners can read their own orders; only the server (secret key) writes.
-- No address is stored here: Stripe Checkout collects it and the server passes it to the printer.
-- Explicit dreams can never be printed (checked here as well as in the app).

create table if not exists public.print_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  dream_id uuid references public.dreams(id) on delete set null,
  product text not null check (product in ('dream_card')),
  status text not null default 'checkout'
    check (status in ('checkout', 'paid', 'submitting', 'submitted', 'shipped', 'cancelled', 'failed')),
  amount_pence int not null check (amount_pence > 0),
  stripe_session_id text unique,
  prodigi_order_id text unique,
  file_paths text[] not null default '{}',
  tracking_url text,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  submitted_at timestamptz,
  shipped_at timestamptz
);
create index if not exists print_orders_user_idx on public.print_orders (user_id, created_at desc);
create index if not exists print_orders_status_idx on public.print_orders (status);

alter table public.print_orders enable row level security;
drop policy if exists "owner reads own print orders" on public.print_orders;
create policy "owner reads own print orders" on public.print_orders
  for select using (auth.uid() = user_id);
grant select on public.print_orders to authenticated;
revoke insert, update, delete on public.print_orders from anon, authenticated;
grant select, insert, update, delete on public.print_orders to service_role;

-- New orders: the dream must be the buyer's own and not explicit.
create or replace function public.print_orders_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.dreams d
    where d.id = new.dream_id and d.user_id = new.user_id and not d.is_explicit
  ) then
    raise exception 'this dream cannot be printed' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.print_orders_guard() from public, anon, authenticated;
drop trigger if exists print_orders_guard on public.print_orders;
create trigger print_orders_guard before insert on public.print_orders
  for each row execute function public.print_orders_guard();
