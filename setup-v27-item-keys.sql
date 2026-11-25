-- setup-v27-item-keys.sql — per-item availability/price keys (section|name|option)
-- Problem: availability + price overrides were keyed by name|option only, so
-- turning off "فلافل" turned off BOTH the sandwich (fal|فلافل, 15) and the roll
-- (roll|فلافل, 36). Same ambiguity existed server-side in validate_order_money
-- and edit_order_items (v_key = name|label).
-- Fix: keys become section|name|option everywhere. Order items now carry 'sk'
-- (section key, sent by itemsArr()/oeSave). Server keeps a legacy fallback:
-- off/override checks also try the old name|label key, so any pre-fix entry
-- still applies (live prices.off is currently empty, so nothing to migrate).
-- menu_prices needs NO change: its loop accepts any row whose price matches.
-- No trigger changes: CREATE OR REPLACE keeps the existing triggers + grants.
--
create or replace function public.validate_order_money()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb; v_pr jsonb; v_ov jsonb; v_off jsonb; v_add jsonb; v_madd jsonb; v_loy jsonb;
  v_fee numeric; v_vat_rate numeric; v_rate numeric; v_min_redeem int;
  v_items jsonb; v_it jsonb; v_ad jsonb;
  v_name text; v_label text; v_key text; v_key_leg text; v_sk text; v_q int; v_p numeric;
  v_base numeric; v_addon_sum numeric; v_line numeric; v_ok boolean; v_in_madd boolean;
  v_sub numeric := 0; v_disc numeric := 0; v_fee_calc numeric := 0;
  v_base_calc numeric; v_vat numeric; v_total numeric; v_pts_disc numeric := 0;
  v_pr_row record; v_bal int;
begin
  -- ح-2: مفيش أوردر من مجهول إطلاقاً (الدخول إجباري للطلب)
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if new.user_id is distinct from auth.uid() then
    raise exception 'user mismatch';
  end if;

  select value into v_cfg from public.settings where key = 'config';
  v_fee := coalesce((v_cfg->>'fee')::numeric, 30);
  v_vat_rate := coalesce((v_cfg->>'vat')::numeric, 14) / 100;
  select value into v_pr from public.settings where key = 'prices';
  v_ov := coalesce(v_pr->'overrides','{}'::jsonb);
  v_off := coalesce(v_pr->'off','[]'::jsonb);
  select value into v_add from public.settings where key = 'addons';
  v_add := coalesce(v_add,'{}'::jsonb);
  select value into v_madd from public.settings where key = 'menu_add';
  select value into v_loy from public.settings where key = 'loyalty';
  v_rate := coalesce((v_loy->>'redeem_points_per_egp')::numeric, 10);
  v_min_redeem := coalesce((v_loy->>'min_redeem_points')::int, 100);

  v_items := new.items;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'order has no items';
  end if;
  if jsonb_array_length(v_items) > 100 then raise exception 'too many items'; end if;

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_name := v_it->>'n'; v_label := coalesce(v_it->>'l',''); v_q := (v_it->>'q')::int; v_p := (v_it->>'p')::numeric;
    if v_name is null or v_name = '' or v_q is null or v_p is null then raise exception 'bad item'; end if;
    if v_q < 1 or v_q > 99 then raise exception 'bad quantity'; end if;
    if v_p < 0 then raise exception 'bad price'; end if;
    v_sk := coalesce(v_it->>'sk','');
    v_key_leg := v_name || '|' || v_label;
    v_key := case when v_sk <> '' then v_sk || '|' || v_name || '|' || v_label else v_key_leg end;
    if (v_off ? v_key) or (v_off ? v_key_leg) then raise exception 'item unavailable: %', v_key; end if;
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

  -- البرومو: إعادة تحقق كاملة من السيرفر
  if new.promo is not null and new.promo <> '' then
    select * into v_pr_row from public.check_promo(new.promo, new.phone, null) limit 1;
    if v_pr_row.type is null then raise exception 'unknown promo'; end if;
    if not coalesce(v_pr_row.eligible, false) then raise exception 'promo not eligible'; end if;
    if v_sub < coalesce(v_pr_row.min_order, 0) then raise exception 'promo min order not met'; end if;
    if v_pr_row.type = 'percent' then v_disc := round(v_sub * v_pr_row.value) / 100;
    elsif v_pr_row.type = 'amount' then v_disc := least(v_sub, v_pr_row.value);
    elsif v_pr_row.type = 'free_delivery' then v_disc := 0;
    else raise exception 'bad promo type'; end if;
  end if;

  -- التوصيل
  if new.fulfillment = 'delivery' then v_fee_calc := v_fee; else v_fee_calc := 0; end if;
  if v_pr_row is not null then
    if v_pr_row.type = 'free_delivery' then v_fee_calc := 0; end if;
  end if;

  -- النقاط — ح-1: الخصم الذري هنا، في نفس معاملة إدخال الأوردر
  v_pts_disc := coalesce(new.points_discount, 0);
  if coalesce(new.points_redeemed, 0) > 0 then
    if new.user_id is null then raise exception 'points need a logged-in user'; end if;
    if new.points_redeemed < v_min_redeem then raise exception 'points below minimum'; end if;
    -- قفل صف الملف الشخصي أولاً: طلبان متزامنان لنفس العميل يتسلسلان
    select points into v_bal from public.profiles where id = new.user_id for update;
    if v_bal is null or v_bal < new.points_redeemed then raise exception 'insufficient points'; end if;
    if v_pts_disc <> floor(new.points_redeemed / nullif(v_rate, 0)) then raise exception 'points discount mismatch'; end if;
    perform set_config('app.loyalty_rpc', '1', true);
    update public.profiles set points = points - new.points_redeemed, updated_at = now() where id = new.user_id;
    insert into public.loyalty_transactions (user_id, order_id, order_no, points, type, note)
      values (new.user_id, null, new.order_no, -new.points_redeemed, 'redeem', 'استبدال نقاط في أوردر ' || new.order_no);
  elsif v_pts_disc <> 0 then raise exception 'points discount without redeem'; end if;

  v_base_calc := greatest(0, v_sub - v_disc - v_pts_disc + v_fee_calc);
  v_vat := round(v_base_calc * v_vat_rate * 100) / 100;
  v_total := round((v_base_calc + v_vat) * 100) / 100;

  if new.subtotal <> v_sub then raise exception 'subtotal mismatch (sent %, expected %)', new.subtotal, v_sub; end if;
  if new.discount <> v_disc then raise exception 'discount mismatch (sent %, expected %)', new.discount, v_disc; end if;
  if new.delivery <> v_fee_calc then raise exception 'delivery mismatch (sent %, expected %)', new.delivery, v_fee_calc; end if;
  if new.vat <> v_vat then raise exception 'vat mismatch (sent %, expected %)', new.vat, v_vat; end if;
  if new.total <> v_total then raise exception 'total mismatch (sent %, expected %)', new.total, v_total; end if;
  if new.points_discount <> v_pts_disc then raise exception 'points discount mismatch'; end if;
  return new;
end $$;

create or replace function public.edit_order_items(p_order_no text, p_items jsonb)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_order record;
  v_cfg jsonb; v_pr jsonb; v_ov jsonb; v_off jsonb; v_add jsonb; v_madd jsonb; v_loy jsonb;
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

  -- التوصيل
  if v_order.fulfillment = 'delivery' then v_fee_calc := v_fee; else v_fee_calc := 0; end if;
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
    promo = v_promo
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
