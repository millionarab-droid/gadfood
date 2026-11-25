-- setup-cleanup-2026-11-25.sql — final cleanup after the v32/v33/addon/clock/expiry E2E wave
-- 1. Delete the scheduled test order GAD0300002 (id 109, Maadi, 51.30, scheduled 2026-11-25 22:18 Cairo)
--    + its messages / loyalty / activity rows.
-- 2. Reset the Maadi branch counter 3 -> 1; delete the Mohandessin seq row (created by the v33 test).
-- 3. Clear the stale branch_closures entry (الشروق test closure, expired 20:23 UTC).
-- 4. Set a FRESH 10-minute closure on الشروق (for the live clock-countdown check that follows)
--    — as Gad (admin) via the JWT-claims context.
-- 5. Verify everything and report the exact results.

-- 1. test order rows (id 109 is the only live test order)
delete from public.order_messages where order_id = 109;
delete from public.loyalty_transactions where order_id = 109 or order_no = 'GAD0300002';
delete from public.activity_log where details->>'order_no' = 'GAD0300002';
delete from public.orders where id = 109;

-- 2. branch counters
update public.branch_order_seq set last_no = 1 where branch = 'المعادي';
delete from public.branch_order_seq where branch = 'المهندسين';

-- 3. clear stale closures
update public.settings set value = '{}'::jsonb where key = 'branch_closures';

-- 4. fresh 10-min closure on الشروق (clock-countdown check)
begin;
select set_config('request.jwt.claims', '{"sub":"d15e3708-1cca-4f65-83c5-e2153f9a0fbd","role":"authenticated","email":"gadfood16475@gmail.com","aud":"authenticated"}', true);
select public.set_branch_closure('الشروق', 10);
commit;

-- 5. verification (report every result exactly)
select count(*) as order_109_left from public.orders where id = 109;
select count(*) as orders_today_left from public.orders where created_at >= '2026-11-25'::date;
select id, order_no, branch, status, total, created_at from public.orders order by created_at desc limit 5;
select points as gad_points from public.profiles where email = 'gadfood16475@gmail.com';
select branch, last_no from public.branch_order_seq order by branch;
select value as branch_closures_now from public.settings where key = 'branch_closures';
select value->'branch_off' as prices_branch_off from public.settings where key = 'prices';
