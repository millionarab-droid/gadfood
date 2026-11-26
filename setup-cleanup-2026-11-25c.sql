-- setup-cleanup-2026-11-25c.sql — delete the addon per-unit test order GAD0300002
-- (Maadi, 85.50, placed 2026-11-25 23:44 EET by the cloud E2E) + its messages /
-- loyalty / activity rows; reset the Maadi branch counter 2 -> 1; verify.
-- The order is 'new' (no points awarded) — Gad's points must stay 228.

-- 1. test order rows (today's GAD0300002 only)
delete from public.order_messages where order_no = 'GAD0300002';
delete from public.loyalty_transactions where order_no = 'GAD0300002';
delete from public.activity_log where details->>'order_no' = 'GAD0300002';
delete from public.orders where order_no = 'GAD0300002' and created_at >= '2026-11-25'::date;

-- 2. branch counter
update public.branch_order_seq set last_no = 1 where branch = 'المعادي';

-- 3. verification (report every result exactly)
select count(*) as test_order_left from public.orders where order_no = 'GAD0300002';
select count(*) as orders_today_left from public.orders where created_at >= '2026-11-25'::date;
select points as gad_points from public.profiles where email = 'gadfood16475@gmail.com';
select branch, last_no from public.branch_order_seq order by branch;
select value as branch_closures_now from public.settings where key = 'branch_closures';
select value as delivery_zones_now from public.settings where key = 'delivery_zones';
