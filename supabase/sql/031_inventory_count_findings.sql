alter table public.inventory_count_session_items
  add column if not exists condition_status text not null default 'ok',
  add column if not exists condition_qty numeric(14,4) not null default 0,
  add column if not exists condition_note text;

do $$
begin
  alter table public.inventory_count_session_items
    add constraint inventory_count_session_items_condition_status_chk
    check (condition_status in ('ok','expired','damaged','not_sellable','review'));
exception when duplicate_object then null;
end $$;

create or replace function public.inventory_count_session_payload(p_session_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
select to_jsonb(x)
from (
  select
    s.id,
    s.title,
    s.scope,
    s.status,
    s.started_at,
    s.closed_at,
    u.display_name as started_by_name,
    count(i.id) as total_items,
    count(i.id) filter (where i.status = 'pending') as pending_items,
    count(i.id) filter (where i.status in ('counted','applied')) as counted_items,
    count(i.id) filter (where i.status = 'applied') as applied_items,
    count(i.id) filter (where coalesce(i.condition_status, 'ok') <> 'ok') as finding_items,
    coalesce(sum(i.condition_qty) filter (where coalesce(i.condition_status, 'ok') <> 'ok'), 0) as finding_qty,
    max(i.counted_at) as last_counted_at,
    max(i.external_code) filter (where i.counted_at = (select max(i2.counted_at) from public.inventory_count_session_items i2 where i2.session_id = s.id)) as last_counted_code
  from public.inventory_count_sessions s
  left join public.inventory_count_session_items i on i.session_id = s.id
  left join public.app_users u on u.id = s.started_by
  where s.id = p_session_id
  group by s.id, u.display_name
) x;
$$;

drop function if exists public.rpc_inventory_count_session_item_save(text, uuid, numeric, text);

create or replace function public.rpc_inventory_count_session_item_save(
  p_session_token text,
  p_item_id uuid,
  p_counted_qty numeric,
  p_note text default null,
  p_condition_status text default 'ok',
  p_condition_qty numeric default 0,
  p_condition_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_item record;
  v_condition text := coalesce(nullif(trim(p_condition_status), ''), 'ok');
  v_condition_qty numeric := coalesce(p_condition_qty, 0);
  v_condition_note text := nullif(trim(coalesce(p_condition_note, p_note, '')), '');
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para guardar conteos';
  end if;

  if p_counted_qty is null or p_counted_qty < 0 or p_counted_qty <> trunc(p_counted_qty) then
    raise exception 'El conteo debe ser entero y mayor o igual a 0';
  end if;

  if v_condition not in ('ok','expired','damaged','not_sellable','review') then
    raise exception 'Condicion de producto no valida';
  end if;

  if v_condition_qty < 0 or v_condition_qty <> trunc(v_condition_qty) then
    raise exception 'La cantidad del hallazgo debe ser entera y mayor o igual a 0';
  end if;

  if v_condition = 'ok' then
    v_condition_qty := 0;
    v_condition_note := null;
  elsif v_condition_qty <= 0 then
    raise exception 'Indica la cantidad afectada por el hallazgo';
  elsif v_condition_note is null then
    raise exception 'Debes comentar el hallazgo cuando la condicion no es OK';
  end if;

  select i.*, s.status as session_status
    into v_item
  from public.inventory_count_session_items i
  join public.inventory_count_sessions s on s.id = i.session_id
  where i.id = p_item_id
  for update of i;

  if v_item.id is null then
    raise exception 'Producto de conteo no encontrado';
  end if;

  if v_item.session_status <> 'open' then
    raise exception 'La sesion de conteo no esta abierta';
  end if;

  if v_item.status = 'applied' then
    raise exception 'Este producto ya tiene ajuste aplicado';
  end if;

  if v_condition_qty > trunc(p_counted_qty) then
    raise exception 'La cantidad del hallazgo no puede ser mayor al conteo fisico';
  end if;

  update public.inventory_count_session_items
     set counted_qty = trunc(p_counted_qty),
         status = 'counted',
         counted_by = v_user_id,
         counted_at = now(),
         note = nullif(trim(coalesce(p_note, '')), ''),
         condition_status = v_condition,
         condition_qty = v_condition_qty,
         condition_note = v_condition_note
   where id = p_item_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'INVENTORY_COUNT_ITEM_SAVE',
    v_user_id,
    jsonb_build_object(
      'item_id', p_item_id,
      'session_id', v_item.session_id,
      'external_code', v_item.external_code,
      'counted_qty', trunc(p_counted_qty),
      'condition_status', v_condition,
      'condition_qty', v_condition_qty,
      'condition_note', v_condition_note
    )
  );

  return (
    select to_jsonb(x)
    from (
      select
        i.id,
        i.session_id,
        i.external_code,
        m.name as medicine_name,
        i.expected_qty,
        i.counted_qty,
        i.variance_qty,
        i.status,
        i.counted_at,
        u.display_name as counted_by_name,
        i.note,
        i.condition_status,
        i.condition_qty,
        i.condition_note
      from public.inventory_count_session_items i
      join public.medicines m on m.id = i.medicine_id
      left join public.app_users u on u.id = i.counted_by
      where i.id = p_item_id
    ) x
  );
end;
$$;

grant execute on function public.rpc_inventory_count_session_item_save(text, uuid, numeric, text, text, numeric, text) to anon, authenticated;

create or replace function public.rpc_inventory_count_session_items(
  p_session_token text,
  p_session_id uuid,
  p_query text default '',
  p_status text default 'all',
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_status text := coalesce(nullif(trim(p_status), ''), 'all');
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 1000));
  v_rows jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para consultar conteos';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows
  from (
    select
      i.id,
      i.session_id,
      i.external_code,
      m.name as medicine_name,
      m.secondary_name,
      m.model,
      m.barcode,
      i.expected_qty,
      i.counted_qty,
      i.variance_qty,
      i.status,
      i.note,
      i.condition_status,
      i.condition_qty,
      i.condition_note,
      i.counted_at,
      u.display_name as counted_by_name,
      i.applied_at,
      au.display_name as applied_by_name
    from public.inventory_count_session_items i
    join public.medicines m on m.id = i.medicine_id
    left join public.app_users u on u.id = i.counted_by
    left join public.app_users au on au.id = i.applied_by
    where i.session_id = p_session_id
      and (v_status = 'all' or i.status = v_status)
      and (
        v_query = ''
        or i.external_code::text = v_query
        or coalesce(m.barcode, '') ilike '%' || v_query || '%'
        or m.name ilike '%' || v_query || '%'
        or coalesce(m.secondary_name, '') ilike '%' || v_query || '%'
        or coalesce(m.model, '') ilike '%' || v_query || '%'
        or coalesce(i.condition_note, '') ilike '%' || v_query || '%'
      )
    order by
      case i.status when 'pending' then 0 when 'counted' then 1 else 2 end,
      m.name
    limit v_limit
  ) x;

  return jsonb_build_object(
    'session', public.inventory_count_session_payload(p_session_id),
    'rows', v_rows
  );
end;
$$;

grant execute on function public.rpc_inventory_count_session_items(text, uuid, text, text, integer) to anon, authenticated;
