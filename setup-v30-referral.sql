-- v30: phone uniqueness (one fixed number per account) + referral system
-- Order of application matters: columns/indexes -> referrals table -> loyalty
-- types -> config -> BACKFILL codes -> triggers (backfill must precede the
-- trigger that forces referral_code to its old value on update).
-- NOTE: the phone unique index FAILS if duplicate phones exist — run the
-- duplicate check first: select normalize_phone(phone), count(*) from
-- profiles group by 1 having count(*) > 1; (must return 0 rows).

-- 1) phone normalization (immutable, mirrors client normPhone)
create or replace function public.normalize_phone(p text)
returns text language sql immutable as $$
  select nullif(
    case
      when d like '0020%' then '0' || substring(d from 5)
      when d like '20%' and length(d) = 12 then '0' || substring(d from 3)
      else d
    end, '')
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') as d) t;
$$;

-- 2) referral code generator (GAD-XXXX, unambiguous alphabet, unique-checked)
create or replace function public.gen_referral_code()
returns text language plpgsql as $$
declare
  v_code text;
  v_i int := 0;
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_j int;
begin
  loop
    v_code := 'GAD-';
    for v_j in 1..4 loop
      v_code := v_code || substr(v_chars, (floor(random()*length(v_chars))::int)+1, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where referral_code = v_code);
    v_i := v_i + 1;
    if v_i > 20 then raise exception 'could not generate unique referral code'; end if;
  end loop;
  return v_code;
end;
$$;

-- 3) profiles columns + unique indexes
alter table public.profiles add column if not exists referral_code text;
alter table public.profiles add column if not exists referred_by text;
create unique index if not exists profiles_referral_code_uidx
  on public.profiles (referral_code) where referral_code is not null;
create unique index if not exists profiles_phone_uidx
  on public.profiles (public.normalize_phone(phone)) where phone is not null and phone <> '';

-- 4) referrals ledger (one row per invitee, status pending -> rewarded)
create table if not exists public.referrals (
  id bigint generated always as identity primary key,
  inviter_id uuid not null references auth.users(id) on delete cascade,
  invitee_id uuid not null references auth.users(id) on delete cascade,
  code text not null,
  status text not null default 'pending' check (status in ('pending','rewarded')),
  order_no text,
  created_at timestamptz not null default now(),
  rewarded_at timestamptz,
  unique (invitee_id)
);
alter table public.referrals enable row level security;
drop policy if exists "referrals inviter read own" on public.referrals;
create policy "referrals inviter read own" on public.referrals for select using (auth.uid() = inviter_id);
drop policy if exists "referrals staff read" on public.referrals;
create policy "referrals staff read" on public.referrals for select using (public.is_staff());

-- 5) loyalty ledger: allow referral award types
alter table public.loyalty_transactions drop constraint if exists loyalty_transactions_type_check;
alter table public.loyalty_transactions add constraint loyalty_transactions_type_check
  check (type in ('earn','redeem','referral_invitee','referral_inviter'));

-- 6) referral config (defaults 50/50; admin can change from the Settings tab)
insert into public.settings (key, value)
values ('referral', '{"on":true,"inviter_points":50,"invitee_points":50}'::jsonb)
on conflict (key) do nothing;

-- 7) BACKFILL referral codes for existing profiles (before the trigger exists)
update public.profiles set referral_code = public.gen_referral_code() where referral_code is null;

-- 8) BEFORE trigger: server-generated code, immutability, phone uniqueness
create or replace function public.trg_profiles_referral_guard()
returns trigger language plpgsql as $$
declare
  v_norm text;
  v_dup boolean;
begin
  if tg_op = 'INSERT' then
    NEW.referral_code := public.gen_referral_code();
  else
    if OLD.referral_code is not null then NEW.referral_code := OLD.referral_code; end if;
    if OLD.referred_by is not null then NEW.referred_by := OLD.referred_by; end if;
  end if;
  if NEW.phone is not null and NEW.phone <> '' then
    v_norm := public.normalize_phone(NEW.phone);
    if v_norm is not null then
      NEW.phone := v_norm;
      select exists (select 1 from public.profiles where id <> NEW.id and public.normalize_phone(phone) = v_norm)
        into v_dup;
      if v_dup then raise exception 'phone already registered'; end if;
    end if;
  end if;
  return NEW;
end;
$$;
drop trigger if exists trg_profiles_referral_guard on public.profiles;
create trigger trg_profiles_referral_guard before insert or update on public.profiles
  for each row execute function public.trg_profiles_referral_guard();

-- 9) AFTER trigger: validate the invite code + award the invitee once
create or replace function public.trg_profiles_referral_award()
returns trigger language plpgsql as $$
declare
  v_cfg jsonb;
  v_on boolean := true;
  v_invitee_pts int := 50;
  v_inviter_id uuid;
begin
  if tg_op = 'UPDATE' and OLD.referred_by is not null then return NEW; end if;
  if NEW.referred_by is null then return NEW; end if;
  select value into v_cfg from public.settings where key = 'referral';
  v_on := coalesce((v_cfg->>'on')::boolean, true);
  v_invitee_pts := coalesce((v_cfg->>'invitee_points')::int, 50);
  if not v_on then raise exception 'referral disabled'; end if;
  select id into v_inviter_id from public.profiles where referral_code = NEW.referred_by;
  if v_inviter_id is null then raise exception 'invalid referral code'; end if;
  if v_inviter_id = NEW.id then raise exception 'cannot refer yourself'; end if;
  insert into public.referrals (inviter_id, invitee_id, code, status)
    values (v_inviter_id, NEW.id, NEW.referred_by, 'pending');
  if v_invitee_pts > 0 then
    perform set_config('app.loyalty_rpc', '1', true);
    update public.profiles set points = points + v_invitee_pts where id = NEW.id;
    insert into public.loyalty_transactions (user_id, order_id, order_no, points, type, note)
      values (NEW.id, null, null, v_invitee_pts, 'referral_invitee', 'نقاط دعوة — كود ' || NEW.referred_by);
  end if;
  return NEW;
end;
$$;
drop trigger if exists trg_profiles_referral_award on public.profiles;
create trigger trg_profiles_referral_award after insert or update of referred_by on public.profiles
  for each row execute function public.trg_profiles_referral_award();

-- 10) award_loyalty_points with the referrer award (regenerated from the live
-- v15 body by gen-v30-sql.py — appended below).

create or replace function public.award_loyalty_points(p_order_id bigint)
returns int language plpgsql security definer as $$
declare
  o public.orders%rowtype;
  earn_rate numeric := 1;
  pts int := 0;
begin
  perform set_config('app.loyalty_rpc', '1', true);
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return 0; end if;
  if o.status <> 'done' then return 0; end if;
  if o.user_id is null then return 0; end if;
  if o.points_earned > 0 then return o.points_earned; end if;
  select coalesce((value->>'earn_per_egp')::numeric, 1) into earn_rate
    from public.settings where key = 'loyalty';
  pts := floor(o.total * earn_rate)::int;
  if pts <= 0 then return 0; end if;
  update public.profiles set points = points + pts, updated_at = now() where id = o.user_id;
  insert into public.loyalty_transactions (user_id, order_id, order_no, points, type, note)
    values (o.user_id, o.id, o.order_no, pts, 'earn', 'نقاط أوردر ' || o.order_no);
  update public.orders set points_earned = pts where id = o.id;
  -- referral: reward the inviter once, on the invitee's first delivered order
  declare
    v_ref public.referrals%rowtype;
    v_cfg2 jsonb;
    v_inviter_pts int := 50;
  begin
    select * into v_ref from public.referrals where invitee_id = o.user_id and status = 'pending';
    if v_ref.id is not null then
      select value into v_cfg2 from public.settings where key = 'referral';
      if coalesce((v_cfg2->>'on')::boolean, true) then
        v_inviter_pts := coalesce((v_cfg2->>'inviter_points')::int, 50);
        if v_inviter_pts > 0 then
          perform set_config('app.loyalty_rpc', '1', true);
          update public.profiles set points = points + v_inviter_pts where id = v_ref.inviter_id;
          insert into public.loyalty_transactions (user_id, order_id, order_no, points, type, note)
            values (v_ref.inviter_id, o.id, o.order_no, v_inviter_pts, 'referral_inviter', 'نقاط دعوة صديق — ' || o.order_no);
          update public.referrals set status = 'rewarded', rewarded_at = now(), order_no = o.order_no where id = v_ref.id;
        end if;
      end if;
    end if;
  end;
  return pts;
end;
$$;

