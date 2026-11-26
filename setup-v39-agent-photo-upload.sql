-- setup-v39-agent-photo-upload.sql
-- Fix: let AGENTS (eg1/eg2) change item photos, not just admins.
-- Root cause: v25 security fixes changed the item-photos storage policies
-- and the set_item_photo RPC from is_staff() to is_admin().
-- Mohamed tried to change the فول حمص photo from eg1 and could not.
-- Risk: low — agents are trusted staff (they already add items/sections);
-- the RPC still validates the URL must live in the item-photos bucket.

-- 1) Storage policies: admin-only -> staff (admin + agent)
drop policy if exists "item-photos staff insert" on storage.objects;
create policy "item-photos staff insert" on storage.objects
  for insert with check (bucket_id = 'item-photos' and public.is_staff());
drop policy if exists "item-photos staff update" on storage.objects;
create policy "item-photos staff update" on storage.objects
  for update using (bucket_id = 'item-photos' and public.is_staff());
drop policy if exists "item-photos staff delete" on storage.objects;
create policy "item-photos staff delete" on storage.objects
  for delete using (bucket_id = 'item-photos' and public.is_staff());

-- 2) set_item_photo RPC: admin-only -> staff
create or replace function public.set_item_photo(p_key text, p_url text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_staff() then raise exception 'not staff'; end if;
  if p_url is not null and p_url <> ''
     and p_url not like 'https://apcvurppgwscpktdurdt.supabase.co/storage/v1/object/public/item-photos/%' then
    raise exception 'photo must be in the item-photos bucket';
  end if;
  select value into v from public.settings where key = 'item_photos';
  if v is null then v := '{}'::jsonb; end if;
  if p_url is null or p_url = '' then
    v := v - p_key;
  else
    v := jsonb_set(v, array[p_key], to_jsonb(p_url));
  end if;
  update public.settings set value = v where key = 'item_photos';
  return v;
end;
$$;
