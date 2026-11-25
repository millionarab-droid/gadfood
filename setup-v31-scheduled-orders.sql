-- ============================================================
-- v31: الأوردرات المجدولة (On Hold) — نفس اليوم فقط
--  - عمود orders.scheduled_at (NULL = الأسرع)
--  - auto_advance_orders: يتخطى المجدول لحد 45 دقيقة قبل معاده
--  - validate_order_money: المجدول لازم يكون نفس اليوم + داخل مواعيد الفرع + بعد 45 دقيقة على الأقل
--  - get_order_status: يرجّع scheduled_at كمان (للتراكر)
-- المصدر: أجسام v29 (auto_advance + validate) و v25 (get_order_status) الحية — بدون أي تغيير تاني
-- ============================================================

alter table public.orders add column if not exists scheduled_at timestamptz;
create index if not exists orders_scheduled_idx on public.orders (scheduled_at) where status = 'new';

create or replace function public.auto_advance_orders() returns jsonb language plpgsql security definer set search_path = public as $$
declare n1 int := 0;
begin
  if auth.uid() is not null and not public.is_staff() then raise exception 'not allowed'; end if;
  update public.orders set status = 'preparing'
    where status = 'new' and created_at < now() - interval '5 minutes'
      and (scheduled_at is null or scheduled_at <= now() + interval '45 minutes');
  get diagnostics n1 = row_count;
  return jsonb_build_object('to_preparing', n1, 'to_delivering', 0);
end $$;
revoke execute on function public.auto_advance_orders() from public;

create or replace function public.validate_order_money()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb; v_pr jsonb; v_ov jsonb; v_off jsonb; v_add jsonb; v_madd jsonb; v_loy jsonb;
  v_br jsonb; v_bh jsonb; v_open text; v_close text; v_sched_time time; v_sched_mins int; v_open_mins int; v_close_mins int;
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

  -- v31: الأوردر المجدول — نفس اليوم (بتوقيت القاهرة) + داخل مواعيد الفرع + بعد 45 دقيقة على الأقل
  if new.scheduled_at is not null then
    if (new.scheduled_at at time zone 'Africa/Cairo')::date <> (now() at time zone 'Africa/Cairo')::date then
      raise exception 'scheduled orders must be same-day';
    end if;
    select value into v_br from public.settings where key = 'branches';
    v_bh := coalesce(v_br -> new.branch, '{}'::jsonb);
    if coalesce((v_bh->>'closed')::boolean, false) then raise exception 'branch closed'; end if;
    v_open := coalesce(v_bh->>'open', '08:00');
    v_close := coalesce(v_bh->>'close', '01:00');
    v_sched_time := (new.scheduled_at at time zone 'Africa/Cairo')::time;
    v_sched_mins := extract(hour from v_sched_time)::int * 60 + extract(minute from v_sched_time)::int;
    v_open_mins := split_part(v_open, ':', 1)::int * 60 + split_part(v_open, ':', 2)::int;
    v_close_mins := split_part(v_close, ':', 1)::int * 60 + split_part(v_close, ':', 2)::int;
    if v_close_mins > v_open_mins then
      if v_sched_mins < v_open_mins or v_sched_mins >= v_close_mins then raise exception 'outside branch hours'; end if;
    else
      if v_sched_mins >= v_close_mins and v_sched_mins < v_open_mins then raise exception 'outside branch hours'; end if;
    end if;
    if new.scheduled_at <= now() + interval '45 minutes' then
      raise exception 'scheduled time too soon';
    end if;
  end if;
  -- البرومو: إعادة تحقق كاملة من السيرفر (الهوية من الـ JWT داخل check_promo)
  if new.promo is not null and new.promo <> '' then
    perform pg_advisory_xact_lock(hashtext(auth.uid()::text || '|' || lower(new.promo)));
    select * into v_pr_row from public.check_promo(new.promo, new.phone, null, null) limit 1;
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

drop function if exists public.get_order_status(text, text);

create or replace function public.get_order_status(p_order_no text, p_phone text)
returns table(status text, fulfillment text, total numeric, scheduled_at timestamptz)
language sql security definer set search_path = public as $$
  select status, fulfillment, total, scheduled_at from public.orders
  where order_no = p_order_no and user_id = auth.uid() limit 1;
$$;
revoke execute on function public.get_order_status(text, text) from public;
revoke execute on function public.get_order_status(text, text) from anon;
grant execute on function public.get_order_status(text, text) to authenticated;
