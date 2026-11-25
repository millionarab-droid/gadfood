-- setup-cleanup-2026-11-25b.sql — small tidy-up after the 2026-11-25 evening wave
-- 1. Clear the expired test closure (الشروق, expired 23:10 Cairo) from branch_closures.
-- 2. Remove 'عمر' from Gad's friends — a test guest leftover from the group-link E2E
--    (real friends are أحمد + سارة only; عمر was approved as a guest in a test and
--    the approval auto-registered him as a friend).
-- 3. Verify everything and report the exact results.

update public.settings set value = '{}'::jsonb where key = 'branch_closures';

update public.profiles
set friends = (select coalesce(jsonb_agg(x),'[]'::jsonb)
                from jsonb_array_elements(friends) x where x->>'n' <> 'عمر')
where email = 'gadfood16475@gmail.com';

-- verification (report every result exactly)
select value as branch_closures_now from public.settings where key = 'branch_closures';
select friends as gad_friends from public.profiles where email = 'gadfood16475@gmail.com';
select points as gad_points from public.profiles where email = 'gadfood16475@gmail.com';
