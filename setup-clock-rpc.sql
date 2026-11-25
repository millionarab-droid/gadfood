-- setup-clock-rpc.sql — server clock for the Gad site (Mohamed's rule, 2026-11-25 22:31 EET)
-- NEVER trust the device/phone clock (it can be tampered with or just wrong);
-- the site is Egypt-only, so every client time decision/display uses the
-- Supabase server clock (Africa/Cairo) via this RPC. The client computes
-- CLOCK_OFF = server_now - Date.now() once at load (and refreshes it) and
-- routes all time logic through nowMs(). The RPC returns only the time —
-- no data — so it is open to anon + authenticated.
create or replace function public.get_server_time()
returns timestamptz
language sql
stable
security definer
as $$
  select now();
$$;

-- Verification (run after applying):
--   select public.get_server_time();  -- returns the server timestamp
--   -- anon curl probe (from the VM, with the anon key):
--   -- curl -s -X POST https://apcvurppgwscpktdurdt.supabase.co/rest/v1/rpc/get_server_time \
--   --   -H "apikey: <ANON>" -H "Authorization: Bearer <ANON>" \
--   --   -H "Content-Type: application/json" -d '{}'
--   -- must return a timestamp like "2026-11-25T20:33:30+00:00", NOT a 404/42501.
