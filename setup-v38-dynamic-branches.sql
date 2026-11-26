-- setup-v38-dynamic-branches.sql — v38: dynamic branch list (add/delete branches from Settings)
-- The branch list lives in settings key 'branch_list' (array of {n, en}).
-- The client (index.html + admin.html) reads it and overrides the hardcoded 9.
-- branch_codes (v22) already exists; new branches get the next code (10, 11, ...)
-- via the admin panel, and next_order_no() auto-creates the branch_order_seq row
-- on the branch's first order. No function changes needed here.

insert into public.settings (key, value, updated_at)
values ('branch_list',
  '[{"n":"المهندسين","en":"Mohandessin"},{"n":"عباس العقاد (مدينة نصر)","en":"Abbas El Akkad (Nasr City)"},{"n":"وسط البلد","en":"Downtown"},{"n":"المعادي","en":"Maadi"},{"n":"المعراج","en":"El Merag"},{"n":"الميرغني – مصر الجديدة","en":"Mirghani – Heliopolis"},{"n":"التجمع الخامس – جامعة المستقبل","en":"Fifth Settlement – Future University"},{"n":"التجمع الخامس – مسجد الحمد","en":"Fifth Settlement – Al Hamd Mosque"},{"n":"الشروق","en":"Shorouk"}]'::jsonb,
  now())
on conflict (key) do nothing;

-- branch_list must be readable by ANON (the customer page reads settings with the
-- anon key). Add it to the public-read whitelist (same pattern as v30b/v33/v35).
-- branch_codes stays STAFF-ONLY (internal order-number mapping).
drop policy if exists "public read settings" on public.settings;
create policy "public read settings" on public.settings for select to anon, authenticated using (
  key = any(array['config','prices','menu_add','order','item_photos','banner','branches','loyalty','addons','best_sellers','item_descriptions','rush_notice','referral','branch_closures','delivery_zones','branch_list'])
);
