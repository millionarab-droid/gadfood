-- Gad v28: phone-list promos — max uses per phone + my_promos() for the customer banner.
-- Run in the Supabase Gadfood project SQL Editor.
-- 1) promos.max_uses (per-phone use limit; NULL = unlimited).
-- 2) check_promo rewritten from the LIVE v25 M2 body (throttle kept) + usage gate:
--    when max_uses is set and the caller's phone already used the code max_uses times
--    (non-cancelled orders), eligible = false. validate_order_money calls check_promo,
--    so the gate is enforced server-side on every order insert.
-- 3) my_promos() — for a LOGGED-IN customer only: the manual-target promos whose
--    target_customers list contains the caller's profile phone, with uses left.
--    It does NOT call check_promo (so it never burns the M2 throttle).
--    Granted to authenticated only (never anon).

alter table public.promos
  add column if not exists max_uses int check (max_uses is null or max_uses > 0);

create or replace function public.check_promo(p text, p_phone text default null, p_email text default null)
returns table(type text, value numeric, min_order numeric, eligible boolean, target_type text, target_value numeric)
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
  v_month_start timestamptz := date_trunc('month', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
begin
  -- خنق: 20 فحص/ساعة لنفس الهاتف، 100/ساعة لنفس الكود (M2 — كما هو)
  insert into public.promo_check_log(phone, code) values (p_phone, lower(p));
  delete from public.promo_check_log where created_at < now() - interval '1 day';
  if p_phone is not null and (select count(*) from public.promo_check_log where phone = p_phone and created_at > now() - interval '1 hour') > 20 then
    raise exception 'too many promo checks';
  end if;
  if (select count(*) from public.promo_check_log where code = lower(p) and created_at > now() - interval '1 hour') > 100 then
    raise exception 'too many promo checks';
  end if;
  if p_email is not null then
    select id into v_uid from public.profiles where lower(email) = lower(p_email) limit 1;
  end if;

  return query
  select pr.type, pr.value, coalesce(pr.min_order, 0),
    case
      when pr.max_uses is not null and p_phone is not null and (
        select count(*) from public.orders o
        where lower(o.promo) = lower(p) and o.phone = p_phone and o.status <> 'cancelled'
      ) >= pr.max_uses then false
      else case pr.target_type
      when 'all' then true
      when 'min_spent' then coalesce((
        select sum(o.total) from public.orders o
        where o.status = 'done' and o.created_at >= v_month_start
          and (o.phone = p_phone or (v_uid is not null and o.user_id = v_uid))
      ), 0) >= coalesce(pr.target_value, 0)
      when 'min_orders' then (
        select count(*) from public.orders o
        where o.status = 'done' and o.created_at >= v_month_start
          and (o.phone = p_phone or (v_uid is not null and o.user_id = v_uid))
      ) >= coalesce(pr.target_value, 0)
      when 'manual' then coalesce((
        p_phone is not null and p_phone = any(coalesce((select array_agg(x) from jsonb_array_elements_text(pr.target_customers) x), '{}'::text[]))
        or (p_email is not null and lower(p_email) = any(coalesce((select array_agg(lower(x)) from jsonb_array_elements_text(pr.target_customers) x), '{}'::text[])))
        or (v_uid is not null and v_uid::text = any(coalesce((select array_agg(x) from jsonb_array_elements_text(pr.target_customers) x), '{}'::text[])))
        or (v_uid is not null and exists(select 1 from public.profiles pf where pf.id = v_uid and pf.phone = any(coalesce((select array_agg(x) from jsonb_array_elements_text(pr.target_customers) x), '{}'::text[]))))
      ), false)
      else true
    end
    end,
    pr.target_type, coalesce(pr.target_value, 0)
  from public.promos pr
  where lower(pr.code) = lower(p) and pr.active;
end;
$$;
revoke execute on function public.check_promo(text, text, text) from public;
grant execute on function public.check_promo(text, text, text) to anon, authenticated;

create or replace function public.my_promos()
returns table(code text, type text, value numeric, min_order numeric, max_uses int, uses_left int, note text)
language plpgsql security definer set search_path = public as $$
declare
  v_phone text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select phone into v_phone from public.profiles where id = auth.uid();
  if v_phone is null or v_phone = '' then return; end if;
  return query
  select pr.code, pr.type, pr.value, coalesce(pr.min_order, 0), pr.max_uses,
    case when pr.max_uses is null then null else greatest(pr.max_uses - (
      select count(*) from public.orders o
      where lower(o.promo) = lower(pr.code) and o.phone = v_phone and o.status <> 'cancelled'
    ), 0) end,
    pr.note
  from public.promos pr
  where pr.active and pr.target_type = 'manual'
    and v_phone = any(coalesce((select array_agg(x) from jsonb_array_elements_text(pr.target_customers) x), '{}'::text[]))
    and (pr.max_uses is null or (
      select count(*) from public.orders o
      where lower(o.promo) = lower(pr.code) and o.phone = v_phone and o.status <> 'cancelled'
    ) < pr.max_uses);
end;
$$;
revoke execute on function public.my_promos() from public;
revoke execute on function public.my_promos() from anon;
grant execute on function public.my_promos() to authenticated;

-- verification
select column_name, data_type from information_schema.columns
where table_schema='public' and table_name='promos' and column_name='max_uses';
select proname, pg_get_function_arguments(oid) as args from pg_proc
where proname in ('check_promo','my_promos') order by proname;
