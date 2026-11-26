-- setup-cleanup-2026-11-26.sql — final cleanup of the 2026-11-26 test orders:
-- GAD0100001 (المهندسين, 51.30, v36 probe, cancelled) +
-- GAD0300005 (المعادي, 91.20 after admin edit, v36 + purple-card + tracker tests)
-- + their messages / loyalty / activity rows; reset delivery_zones to {};
-- reset المعادي seq 5 -> 1, المهندسين seq 1 -> 0; verify.
-- Neither order became 'done' (no points awarded) — Gad's points must stay 228.

-- 1. related rows + test orders (today's two test orders only)
delete from public.order_messages where order_no in ('GAD0100001','GAD0300005');
delete from public.loyalty_transactions where order_no in ('GAD0100001','GAD0300005');
delete from public.activity_log where details->>'order_no' in ('GAD0100001','GAD0300005');
delete from public.orders where order_no in ('GAD0100001','GAD0300005') and created_at >= '2026-11-26'::date;

-- 2. branch counters
update public.branch_order_seq set last_no = 1 where branch = 'المعادي';
update public.branch_order_seq set last_no = 0 where branch = 'المهندسين';

-- 3. test delivery zone back to empty (no real zones configured yet)
update public.settings set value = '{}'::jsonb where key = 'delivery_zones';

-- 4. verification (report every result exactly)
select count(*) as test_orders_left from public.orders where order_no in ('GAD0100001','GAD0300005');
select count(*) as orders_today_left from public.orders where created_at >= '2026-11-26'::date;
select points as gad_points from public.profiles where email = 'gadfood16475@gmail.com';
select branch, last_no from public.branch_order_seq order by branch;
select value as branch_closures_now from public.settings where key = 'branch_closures';
select value as delivery_zones_now from public.settings where key = 'delivery_zones';
select order_no, branch, status, total from public.orders order by created_at desc limit 5;
