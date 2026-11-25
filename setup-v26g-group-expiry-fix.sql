-- setup-v26g-group-expiry-fix.sql — group links expire after 1 hour, enforced on EVERY path
-- Bug: link FJAW4V (expires_at 2026-11-25T12:31:43Z) still opened as 'open' 8h later.
-- Cause: group_state_json (the read path) never checked expires_at; approve/remove/
-- set_status/set_ready did not either; and the default validity was 2 hours, not the
-- agreed 1 hour. The client already shows 'اللينك ده مش شغال أو انتهت صلاحيته' on any
-- group_state error, so no client change is needed.
-- Bodies below are verbatim from the live v26/v26b files, only the expiry lines added.

-- 1. Default validity: 1 hour (was 2 hours)
alter table public.group_orders alter column expires_at set default (now() + interval '1 hour');

-- 2. New links expire after 1 hour (explicit, not just the default)
create or replace function public.create_group_link(p_branch text, p_invitees jsonb, p_host_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_gid uuid;
  v_inv jsonb;
  v_name text;
  v_av text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  v_code := public.gen_group_code();
  insert into public.group_orders (code, host_user_id, host_name, branch, expires_at)
  values (v_code, v_uid, coalesce(nullif(trim(p_host_name), ''), 'أنا'), coalesce(p_branch, ''), now() + interval '1 hour')
  returning id into v_gid;
  -- host is a member too (approved, owns the host seat)
  insert into public.group_members (group_id, name, avatar_url, is_guest, approved)
  values (v_gid, coalesce(nullif(trim(p_host_name), ''), 'أنا'), null, false, true);
  -- invited friends: approved, seat free until they join
  if p_invitees is not null then
    for v_inv in select * from jsonb_array_elements(p_invitees) loop
      v_name := nullif(trim(coalesce(v_inv->>'n', '')), '');
      if v_name is not null then
        v_av := nullif(trim(coalesce(v_inv->>'av', '')), '');
        insert into public.group_members (group_id, name, avatar_url, is_guest, approved)
        values (v_gid, v_name, v_av, false, true)
        on conflict (group_id, lower(name)) do nothing;
      end if;
    end loop;
  end if;
  return jsonb_build_object('code', v_code, 'group_id', v_gid);
end;
$$;;

-- 3. Reading an expired link now raises (client shows 'اللينك ده مش شغال أو انتهت صلاحيته')
create or replace function public.group_state_json(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_g public.group_orders;
  v_members jsonb;
  v_items jsonb;
begin
  select * into v_g from public.group_orders where code = p_code;
  if not found then
    raise exception 'group not found';
  end if;
  if v_g.expires_at < now() then raise exception 'group expired'; end if;
  select coalesce(jsonb_agg(
    jsonb_build_object('id', m.id, 'name', m.name, 'avatar', m.avatar_url,
      'is_guest', m.is_guest, 'approved', m.approved, 'ready', m.ready,
      'taken', (m.seat_token is not null), 'joined', (m.joined_at is not null))
    order by m.joined_at nulls first, m.name), '[]'::jsonb)
  into v_members from public.group_members m where m.group_id = v_g.id;
  select coalesce(jsonb_agg(
    jsonb_build_object('member_id', i.member_id, 'key', i.item_key,
      'name', i.name, 'label', i.label, 'price', i.price, 'qty', i.qty)
    order by i.updated_at), '[]'::jsonb)
  into v_items from public.group_items i where i.group_id = v_g.id;
  return jsonb_build_object(
    'group', jsonb_build_object('id', v_g.id, 'code', v_g.code,
      'host_name', v_g.host_name, 'branch', v_g.branch, 'status', v_g.status,
      'order_no', v_g.order_no, 'expires_at', v_g.expires_at),
    'members', v_members, 'items', v_items);
end;
$$;;

-- 4. Marking ready on an expired group is blocked
create or replace function public.group_set_ready(p_code text, p_seat text, p_ready boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_g public.group_orders;
  v_m public.group_members;
begin
  select * into v_g from public.group_orders where code = p_code;
  if not found then raise exception 'group not found'; end if;
  if v_g.status <> 'open' then raise exception 'group is not open'; end if;
  if v_g.expires_at < now() then raise exception 'group expired'; end if;
  select * into v_m from public.group_members
  where group_id = v_g.id and seat_token = p_seat;
  if not found then raise exception 'not a member'; end if;
  update public.group_members set ready = coalesce(p_ready, false) where id = v_m.id;
  return true;
end;
$$;;

-- 5. Approving/rejecting a guest on an expired group is blocked
create or replace function public.group_approve_member(p_code text, p_member_id uuid, p_approve boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_g public.group_orders;
begin
  select * into v_g from public.group_orders where code = p_code;
  if not found then raise exception 'group not found'; end if;
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_g.host_user_id <> auth.uid() then raise exception 'not host'; end if;
  if v_g.expires_at < now() then raise exception 'group expired'; end if;
  if p_approve then
    update public.group_members set approved = true
    where id = p_member_id and group_id = v_g.id;
  else
    delete from public.group_members where id = p_member_id and group_id = v_g.id;
  end if;
  return true;
end;
$$;;

-- 6. Removing a member from an expired group is blocked
create or replace function public.group_remove_member(p_code text, p_member_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_g public.group_orders;
begin
  select * into v_g from public.group_orders where code = p_code;
  if not found then raise exception 'group not found'; end if;
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_g.host_user_id <> auth.uid() then raise exception 'not host'; end if;
  if v_g.expires_at < now() then raise exception 'group expired'; end if;
  delete from public.group_members where id = p_member_id and group_id = v_g.id;
  return true;
end;
$$;;

-- 7. Changing status on an expired group is blocked, EXCEPT cancelling it ('expired')
--    and marking it ordered after its real order was placed ('ordered')
create or replace function public.group_set_status(p_code text, p_status text, p_order_no text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_g public.group_orders;
begin
  select * into v_g from public.group_orders where code = p_code;
  if not found then raise exception 'group not found'; end if;
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_g.host_user_id <> auth.uid() then raise exception 'not host'; end if;
  if p_status not in ('open','locked','ordered','expired') then raise exception 'bad status'; end if;
  if v_g.expires_at < now() and p_status not in ('expired','ordered') then raise exception 'group expired'; end if;
  update public.group_orders
  set status = p_status, order_no = coalesce(p_order_no, order_no)
  where id = v_g.id;
  return true;
end;
$$;;

-- 8. One-time cleanup: groups already past expiry become 'expired' (includes FJAW4V)
update public.group_orders set status = 'expired'
where status in ('open', 'locked') and expires_at < now();

-- Verification (run after applying):
--   select code, status, expires_at from public.group_orders where code = 'FJAW4V';
--     -- must show status 'expired'
--   select public.group_state('FJAW4V');
--     -- must raise 'group expired'
