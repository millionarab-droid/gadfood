-- setup-v34-order-alerts.sql — order alert lifecycle (v34)
-- orders.ack_by/ack_at (Accept), copied_at (first copy = final state),
-- edited_by/edited_role/edited_at (set by edit_order_items on every staff edit).
-- Generated from the live v35 bodies by gen-v34-sql.py — nothing else changed.

alter table public.orders
  add column if not exists ack_by text,
  add column if not exists ack_at timestamptz,
  add column if not exists copied_at timestamptz,
  add column if not exists edited_by text,
  add column if not exists edited_role text,
  add column if not exists edited_at timestamptz;

create or replace function public.edit_order_items(p_order_no text, p_items jsonb)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_order record;
  v_cfg jsonb; v_pr jsonb; v_ov jsonb; v_off jsonb; v_boff jsonb; v_boff_arr jsonb; v_add jsonb; v_madd jsonb; v_loy jsonb; v_dz jsonb; v_zone_fee numeric;
  v_fee numeric; v_vat_rate numeric; v_rate numeric;
  v_it jsonb; v_ad jsonb;
  v_name text; v_label text; v_key text; v_key_leg text; v_sk text; v_q int; v_p numeric;
  v_base numeric; v_addon_sum numeric; v_line numeric; v_ok boolean; v_in_madd boolean;
  v_sub numeric := 0; v_disc numeric := 0; v_fee_calc numeric := 0;
  v_base_calc numeric; v_vat numeric; v_total numeric; v_pts_disc numeric := 0;
  v_pr_row record;
  v_old_keys jsonb := '[]'::jsonb;
  v_old_total numeric;
  v_promo text; v_promo_dropped boolean := false;
  v_items_txt text; v_msg text;
  v_total_txt text; v_old_total_txt text;
begin
  if not public.is_staff() then raise exception 'not staff'; end if;

  select * into v_order from public.orders where order_no = p_order_no for update;
  if not found then raise exception 'order not found'; end if;
  if v_order.status <> 'new' then raise exception 'order cannot be edited in status %', v_order.status; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items must be a non-empty array';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'too many items'; end if;

  -- نفس مصادر الإعدادات بتاعة validate_order_money
  select value into v_cfg from public.settings where key = 'config';
  v_fee := coalesce((v_cfg->>'fee')::numeric, 30);
  v_vat_rate := coalesce((v_cfg->>'vat')::numeric, 14) / 100;
  select value into v_pr from public.settings where key = 'prices';
  v_ov := coalesce(v_pr->'overrides','{}'::jsonb);
  v_off := coalesce(v_pr->'off','[]'::jsonb);
  v_boff := coalesce(v_pr->'branch_off','{}'::jsonb);
  select value into v_add from public.settings where key = 'addons';
  v_add := coalesce(v_add,'{}'::jsonb);
  select value into v_madd from public.settings where key = 'menu_add';
  select value into v_loy from public.settings where key = 'loyalty';
  v_rate := coalesce((v_loy->>'redeem_points_per_egp')::numeric, 10);

  -- مفاتيح الأصناف اللي كانت في الأوردر أصلاً (عشان الـ off ميمنعش تعديلها)
  select coalesce(jsonb_agg(distinct (it->>'n') || '|' || coalesce(it->>'l','')), '[]'::jsonb) into v_old_keys
  from jsonb_array_elements(coalesce(v_order.items,'[]'::jsonb)) it;
  v_old_total := v_order.total;

  -- تأكيد السعر لكل سطر (مطابق للتريجر)
  for v_it in select * from jsonb_array_elements(p_items) loop
    v_name := v_it->>'n'; v_label := coalesce(v_it->>'l',''); v_q := (v_it->>'q')::int; v_p := (v_it->>'p')::numeric;
    if v_name is null or v_name = '' or v_q is null or v_p is null then raise exception 'bad item'; end if;
    if v_q < 1 or v_q > 99 then raise exception 'bad quantity'; end if;
    if v_p < 0 then raise exception 'bad price'; end if;
    v_sk := coalesce(v_it->>'sk','');
    v_key_leg := v_name || '|' || v_label;
    v_key := case when v_sk <> '' then v_sk || '|' || v_name || '|' || v_label else v_key_leg end;
    if ((v_off ? v_key) or (v_off ? v_key_leg)) and not (v_old_keys ? v_key_leg) then raise exception 'item unavailable: %', v_key; end if;
    if ((v_boff ? v_key) or (v_boff ? v_key_leg)) and not (v_old_keys ? v_key_leg) then
      v_boff_arr := coalesce(v_boff->v_key, v_boff->v_key_leg);
      if v_boff_arr ? v_order.branch then raise exception 'item unavailable in branch: %', v_key; end if;
    end if;
    v_addon_sum := coalesce((select sum((a->>'p')::numeric) from jsonb_array_elements(coalesce(v_it->'addons','[]'::jsonb)) a), 0);
    if v_it ? 'addons' then
      for v_ad in select * from jsonb_array_elements(v_it->'addons') loop
        if not exists (
          select 1 from jsonb_each(v_add) sec, jsonb_array_elements(sec.value) a
          where a->>'n' = (v_ad->>'n')
            and (a->>'p')::numeric = (v_ad->>'p')::numeric
            and (a->'items' is null or a->'items' @> to_jsonb(v_name))
        ) then raise exception 'bad addon: %', (v_ad->>'n'); end if;
      end loop;
    end if;
    v_ok := false; v_in_madd := false; v_base := null;
    if v_ov ? v_key then
      v_base := (v_ov->>v_key)::numeric;
      v_line := v_base + v_addon_sum;
      if v_line = v_p then v_ok := true; end if;
    end if;
    if not v_ok and v_key <> v_key_leg and (v_ov ? v_key_leg) then
      v_base := (v_ov->>v_key_leg)::numeric;
      v_line := v_base + v_addon_sum;
      if v_line = v_p then v_ok := true; end if;
    end if;
    if not v_ok and v_madd is not null then
      select (o->>'p')::numeric into v_base
      from jsonb_array_elements(v_madd) g, jsonb_array_elements(g->'s') s,
           jsonb_array_elements(s->'i') it, jsonb_array_elements(it->'o') o
      where it->>'n' = v_name and coalesce(o->>'l','') = v_label and (v_sk = '' or s->>'k' = v_sk) limit 1;
      if v_base is not null then
        v_in_madd := true;
        v_line := v_base + v_addon_sum;
        if v_line = v_p then v_ok := true; end if;
      end if;
    end if;
    if not v_ok and not (v_ov ? v_key) and not (v_ov ? v_key_leg) and not v_in_madd then
      for v_base in select price from public.menu_prices where name = v_name and label = v_label loop
        v_line := v_base + v_addon_sum;
        if v_line = v_p then v_ok := true; exit; end if;
      end loop;
    end if;
    if not v_ok then raise exception 'price mismatch: % (sent %)', v_key, v_p; end if;
    v_sub := v_sub + v_q * v_p;
  end loop;

  -- البرومو: إعادة فحص — اللي مبقاش مطابق بيتشال (مش خطأ)
  v_promo := v_order.promo;
  if v_promo is not null and v_promo <> '' then
    select * into v_pr_row from public.check_promo(v_promo, v_order.phone, null) limit 1;
    if v_pr_row.type is null or not coalesce(v_pr_row.eligible, false) or v_sub < coalesce(v_pr_row.min_order, 0) then
      v_promo := null; v_promo_dropped := true; v_pr_row := null;
    elsif v_pr_row.type = 'percent' then v_disc := round(v_sub * v_pr_row.value) / 100;
    elsif v_pr_row.type = 'amount' then v_disc := least(v_sub, v_pr_row.value);
    elsif v_pr_row.type = 'free_delivery' then v_disc := 0;
    else v_promo := null; v_promo_dropped := true; v_pr_row := null;
    end if;
  end if;

  -- v35: رسوم التوصيل من منطقة الأوردر لو موجودة
  v_zone_fee := null;
  if v_order.fulfillment = 'delivery' and v_order.zone is not null and v_order.zone <> '' then
    select value into v_dz from public.settings where key = 'delivery_zones';
    v_dz := coalesce(v_dz, '{}'::jsonb);
    select (z->>'fee')::numeric into v_zone_fee
    from jsonb_array_elements(coalesce(v_dz -> v_order.branch, '[]'::jsonb)) z
    where z->>'n' = v_order.zone limit 1;
  end if;

  -- التوصيل
  if v_order.fulfillment = 'delivery' then v_fee_calc := coalesce(v_zone_fee, v_fee); else v_fee_calc := 0; end if;
  -- v17 lesson: never read a record field behind AND — the evaluator may touch
  -- v_pr_row.type before the IS NOT NULL test. Nested IF guarantees the order
  -- (a no-promo order leaves v_pr_row unassigned and the AND form raised
  -- 'record "v_pr_row" is not assigned yet' on every save).
  if v_pr_row is not null then
    if v_pr_row.type = 'free_delivery' then v_fee_calc := 0; end if;
  end if;

  -- النقاط المستبدلة: الخصم = floor(redeemed / rate) زي التريجر بالظبط
  v_pts_disc := 0;
  if coalesce(v_order.points_redeemed, 0) > 0 then
    v_pts_disc := floor(v_order.points_redeemed / nullif(v_rate, 0));
  end if;

  v_base_calc := greatest(0, v_sub - v_disc - v_pts_disc + v_fee_calc);
  v_vat := round(v_base_calc * v_vat_rate * 100) / 100;
  v_total := round((v_base_calc + v_vat) * 100) / 100;

  -- نص الأصناف الجديد (للأوردر + للرسالة)
  select string_agg(
    (it->>'q') || '× ' || (it->>'n') || case when coalesce(it->>'l','') <> '' then ' (' || (it->>'l') || ')' else '' end
    || case when coalesce(it->>'for','') <> '' and (it->>'for') <> coalesce(v_order.name,'') then ' — لـ ' || (it->>'for') else '' end,
    '، ')
  into v_items_txt
  from jsonb_array_elements(p_items) it;

  update public.orders set
    items = p_items,
    items_text = v_items_txt,
    subtotal = v_sub,
    discount = v_disc,
    delivery = v_fee_calc,
    vat = v_vat,
    total = v_total,
    points_discount = v_pts_disc,
    promo = v_promo,
    edited_by = (auth.jwt()->>'email'),
    edited_role = case when public.is_admin() then 'admin' else 'agent' end,
    edited_at = now()
  where order_no = p_order_no;

  -- رسالة للزبون في شات الأوردر (بتشغّل شارة "رسالة جديدة" + التنبيه عنده)
  v_total_txt := case when v_total = trunc(v_total) then to_char(v_total,'FM999999990') else to_char(v_total,'FM999999990.00') end;
  v_old_total_txt := case when v_old_total = trunc(v_old_total) then to_char(v_old_total,'FM999999990') else to_char(v_old_total,'FM999999990.00') end;
  v_msg := 'تم تعديل الأوردر بواسطة الإدارة — الأصناف الجديدة: ' || coalesce(v_items_txt, '') || '. الإجمالي الجديد: ' || v_total_txt || ' ج (كان ' || v_old_total_txt || ' ج)';
  if v_promo_dropped then
    v_msg := v_msg || ' — ملاحظة: البرومو اتشال لأن الإجمالي الجديد مش مطابق لشروطه';
  end if;
  insert into public.order_messages(order_id, order_no, sender, sender_name, message, read_by_staff, read_by_customer)
  values (v_order.id, p_order_no, 'staff', 'الإدارة', left(v_msg, 1000), true, false);

  return jsonb_build_object(
    'ok', true, 'order_no', p_order_no,
    'subtotal', v_sub, 'discount', v_disc, 'delivery', v_fee_calc,
    'vat', v_vat, 'total', v_total, 'points_discount', v_pts_disc,
    'promo', v_promo, 'promo_dropped', v_promo_dropped,
    'message', v_msg
  );
end $$;

create or replace function public.ack_order(p_order_no text)
returns boolean language plpgsql security definer as $$
declare v_id int; begin
  if not public.is_staff() then raise exception 'not staff'; end if;
  update public.orders set ack_by = (auth.jwt()->>'email'), ack_at = now()
  where order_no = p_order_no and ack_at is null returning id into v_id;
  if v_id is null then
    if not exists (select 1 from public.orders where order_no = p_order_no) then raise exception 'order not found'; end if;
    return false;
  end if;
  return true;
end $$;
revoke all on function public.ack_order(text) from public;
revoke all on function public.ack_order(text) from anon;
grant execute on function public.ack_order(text) to authenticated;

create or replace function public.mark_order_copied(p_order_no text)
returns boolean language plpgsql security definer as $$
declare v_id int; begin
  if not public.is_staff() then raise exception 'not staff'; end if;
  update public.orders set copied_at = now()
  where order_no = p_order_no and copied_at is null returning id into v_id;
  if v_id is null then
    if not exists (select 1 from public.orders where order_no = p_order_no) then raise exception 'order not found'; end if;
    return false;
  end if;
  return true;
end $$;
revoke all on function public.mark_order_copied(text) from public;
revoke all on function public.mark_order_copied(text) from anon;
grant execute on function public.mark_order_copied(text) to authenticated;

-- verification
select 'ack columns (6)' as check,
  (select count(*) = 6 from information_schema.columns
    where table_name = 'orders' and column_name in ('ack_by','ack_at','copied_at','edited_by','edited_role','edited_at')) as ok;
select 'ack_order exists' as check,
  (select count(*) = 1 from pg_proc where proname = 'ack_order') as ok;
select 'mark_order_copied exists' as check,
  (select count(*) = 1 from pg_proc where proname = 'mark_order_copied') as ok;
select 'edit sets edited markers' as check,
  (pg_get_functiondef(oid) like '%edited_by%') as ok
  from pg_proc where proname = 'edit_order_items';
