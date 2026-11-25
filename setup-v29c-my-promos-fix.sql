-- v29c: fix my_promos() 42804 — uses_left expression returns bigint (count(*)),
-- but the function declares integer in its RETURNS TABLE. Cast the CASE to int.
-- (Found by the v28 re-test: any manual promo with max_uses broke the whole
-- banner query, so the "ليك برومو كود" slide never appeared.)
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
    (case when pr.max_uses is null then null else greatest(pr.max_uses - (
      select count(*) from public.orders o
      where lower(o.promo) = lower(pr.code) and o.phone = v_phone and o.status <> 'cancelled'
    ), 0) end)::int,
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
