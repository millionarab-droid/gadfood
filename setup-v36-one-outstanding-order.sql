-- setup-v36-one-outstanding-order.sql — one outstanding order per customer (v36)
-- Mohamed 2026-11-26 10:24 EET: if a customer has an order that hasn't arrived yet
-- (status new/preparing/delivering) they CANNOT confirm a new order.
-- Server gate: a SEPARATE small BEFORE INSERT trigger (does NOT touch
-- validate_order_money — recreating its 200-line body to add one check is
-- error-prone). The trigger defers auth failures to validate_order_money.
-- Client: checkOutstanding() in record() + a friendly message for the
-- server's 'outstanding order exists' rejection (patch-v36-index.py).
-- Admin: histHtml shows WHEN the customer made their last order
-- (patch-v36-admin.py).

create or replace function public.check_one_outstanding_order()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if new.user_id is distinct from auth.uid() then return new; end if;
  -- v36: أوردر واحد شغال بس — لو عندك أوردر لسه موصلش مينفعش تأكد أوردر جديد
  if exists (select 1 from public.orders where user_id = new.user_id and status in ('new','preparing','delivering')) then
    raise exception 'outstanding order exists';
  end if;
  return new;
end $$;
drop trigger if exists trg_one_outstanding_order on public.orders;
create trigger trg_one_outstanding_order before insert on public.orders
for each row execute function public.check_one_outstanding_order();

-- verification
select 'outstanding trigger exists' as check, (count(*)=1) as ok from pg_trigger where tgname='trg_one_outstanding_order';
select 'outstanding fn has check' as check, (pg_get_functiondef(oid) like '%outstanding order exists%') as ok from pg_proc where proname='check_one_outstanding_order';
