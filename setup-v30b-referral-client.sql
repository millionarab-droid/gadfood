-- v30b: expose the referral config to the customer page (public settings whitelist)
-- The customer page reads settings with the ANON key (loadSettings). Without
-- 'referral' in this whitelist the client falls back to its 50/50 defaults.
-- Recreated from the v25 policy (setup-v25-security-fixes.sql, م-14) with
-- 'referral' added; the staff policy is untouched.
drop policy if exists "public read settings" on public.settings;
create policy "public read settings" on public.settings for select to anon, authenticated using (
  key = any(array['config','prices','menu_add','order','item_photos','banner','branches','loyalty','addons','best_sellers','item_descriptions','rush_notice','referral'])
);
