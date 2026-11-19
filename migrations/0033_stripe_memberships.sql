-- REM Atlas: memberships move from Paddle to Stripe (CLAUDE.md section 8f). Run once in the Supabase
-- SQL editor, before pushing the Stripe code. No real payment was ever taken through Paddle: the only
-- rows are test memberships from its sandbox, so they go, which also frees founding numbers 1 and 2
-- for real supporters.

delete from memberships;

alter table memberships rename column paddle_subscription_id to stripe_subscription_id;
alter table memberships rename column paddle_customer_id to stripe_customer_id;
