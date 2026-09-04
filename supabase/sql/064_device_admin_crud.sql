-- Device admin CRUD support.
-- Incremental and isolated: only device_* objects are created/replaced.

create table if not exists public.device_admin_audit (
  id uuid primary key default gen_random_uuid(),
  device_unit_id uuid references public.device_units(id),
  device_product_id uuid references public.device_products(id),
  action text not null,
  reason text not null,
  old_data jsonb,
  new_data jsonb,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  constraint device_admin_audit_action_check check (action in ('unit_update','unit_retire','bulk_register'))
);

create index if not exists idx_device_admin_audit_unit_created
on public.device_admin_audit(device_unit_id, created_at desc);

create index if not exists idx_device_admin_audit_action_created
on public.device_admin_audit(action, created_at desc);

alter table public.device_admin_audit enable row level security;

create or replace view public.vw_device_unit_trace
with (security_invoker = true) as
select
  u.id as device_unit_id,
  p.id as device_product_id,
  p.external_code,
  p.name as product_name,
  p.category,
  p.brand_name,
  p.model,
  u.serial_code,
  u.lot_no,
  u.expires_at,
  u.status,
  u.cost,
  u.source_doc_no,
  u.registered_at,
  ru.display_name as registered_by_name,
  u.sold_at,
  su.display_name as sold_by_name,
  s.sale_no,
  s.expediente,
  u.note,
  p.active as product_active,
  p.sale_price,
  p.default_cost,
  u.source_file,
  u.updated_at
from public.device_units u
join public.device_products p on p.id = u.device_product_id
left join public.app_users ru on ru.id = u.registered_by
left join public.app_users su on su.id = u.sold_by
left join public.device_sales s on s.id = u.sale_id;

create or replace function public.rpc_device_unit_admin_list(
  p_session_token text,
  p_query text default '',
  p_status text default 'all',
  p_limit integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
  v_q text := lower(trim(coalesce(p_query,'')));
  v_status text := lower(trim(coalesce(p_status,'all')));
  v_limit integer := greatest(1, least(coalesce(p_limit,120), 500));
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede consultar unidades de dispositivos';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.registered_at desc)
    from (
      select *
      from public.vw_device_unit_trace
      where (v_status = 'all' or lower(status) = v_status)
        and (
          v_q = ''
          or lower(product_name) like '%' || v_q || '%'
          or lower(coalesce(category,'')) like '%' || v_q || '%'
          or lower(serial_code) like '%' || v_q || '%'
          or external_code::text = v_q
          or lower(coalesce(source_doc_no,'')) like '%' || v_q || '%'
          or lower(coalesce(expediente,'')) like '%' || v_q || '%'
        )
      order by registered_at desc
      limit v_limit
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.rpc_device_units_bulk_register(
  p_session_token text,
  p_external_code integer,
  p_serials jsonb,
  p_lot_no text default null,
  p_expires_at date default null,
  p_cost numeric default null,
  p_source_doc_no text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_product public.device_products%rowtype;
  v_raw_count integer := 0;
  v_unique_count integer := 0;
  v_invalid_count integer := 0;
  v_existing_count integer := 0;
  v_inserted_count integer := 0;
  v_serial text;
  v_unit_id uuid;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede registrar unidades de dispositivos';
  end if;

  select * into v_product
  from public.device_products
  where external_code = p_external_code and active = true;

  if v_product.id is null then
    raise exception 'Producto/dispositivo no activo o no existe';
  end if;

  create temp table tmp_device_bulk_serials (
    serial_code text,
    normalized_serial text primary key,
    is_valid boolean not null
  ) on commit drop;

  insert into tmp_device_bulk_serials(serial_code, normalized_serial, is_valid)
  select distinct
    trim(value),
    lower(regexp_replace(trim(value), '\s+', '', 'g')),
    lower(regexp_replace(trim(value), '\s+', '', 'g')) ~ '^[a-z0-9-]{6,40}$'
  from jsonb_array_elements_text(coalesce(p_serials, '[]'::jsonb)) as serial_items(value)
  where length(trim(value)) > 0
  on conflict (normalized_serial) do nothing;

  select count(*) into v_raw_count
  from jsonb_array_elements_text(coalesce(p_serials, '[]'::jsonb)) as raw_items(value)
  where length(trim(value)) > 0;

  select count(*) into v_unique_count from tmp_device_bulk_serials;
  select count(*) into v_invalid_count from tmp_device_bulk_serials where not is_valid;

  if v_unique_count = 0 then
    raise exception 'No hay codigos para registrar';
  end if;

  if v_invalid_count > 0 then
    raise exception 'Hay % codigo(s) con formato invalido. Revisa la lista antes de registrar.', v_invalid_count;
  end if;

  select count(*) into v_existing_count
  from tmp_device_bulk_serials t
  join public.device_units u on u.normalized_serial = t.normalized_serial;

  for v_serial in
    select t.serial_code
    from tmp_device_bulk_serials t
    where not exists (
      select 1 from public.device_units u where u.normalized_serial = t.normalized_serial
    )
    order by t.serial_code
  loop
    insert into public.device_units(
      device_product_id, serial_code, lot_no, expires_at, cost, source_doc_no,
      registered_by, note, source_file
    ) values (
      v_product.id, v_serial, nullif(trim(coalesce(p_lot_no,'')), ''),
      p_expires_at, coalesce(p_cost, v_product.default_cost), nullif(trim(coalesce(p_source_doc_no,'')), ''),
      v_user_id, nullif(trim(coalesce(p_note,'')), ''), 'Carga masiva UI'
    )
    returning id into v_unit_id;

    insert into public.device_inventory_movements(
      device_unit_id, device_product_id, serial_code, movement_type, qty_delta,
      source_type, source_id, source_event_key, note, created_by
    ) values (
      v_unit_id, v_product.id, v_serial, 'receive', 1,
      'device_bulk_register', v_unit_id, 'device_bulk_register:' || lower(regexp_replace(trim(v_serial), '\s+', '', 'g')),
      'Ingreso por carga masiva de unidades serializadas', v_user_id
    )
    on conflict (source_event_key) where source_event_key is not null do nothing;

    insert into public.device_admin_audit(
      device_unit_id, device_product_id, action, reason, old_data, new_data, created_by
    ) values (
      v_unit_id, v_product.id, 'bulk_register', 'Carga masiva de unidades',
      null,
      jsonb_build_object('serial_code', v_serial, 'external_code', p_external_code, 'status', 'available'),
      v_user_id
    );

    v_inserted_count := v_inserted_count + 1;
  end loop;

  return jsonb_build_object(
    'received_lines', v_raw_count,
    'unique_lines', v_unique_count,
    'duplicated_in_batch', greatest(v_raw_count - v_unique_count, 0),
    'existing', v_existing_count,
    'inserted', v_inserted_count
  );
end;
$$;

create or replace function public.rpc_device_unit_update(
  p_session_token text,
  p_device_unit_id uuid,
  p_external_code integer,
  p_lot_no text default null,
  p_expires_at date default null,
  p_cost numeric default null,
  p_source_doc_no text default null,
  p_note text default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_old public.device_units%rowtype;
  v_product public.device_products%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede corregir unidades de dispositivos';
  end if;

  if v_reason is null then
    raise exception 'Motivo requerido para corregir una unidad';
  end if;

  select * into v_old
  from public.device_units
  where id = p_device_unit_id
  for update;

  if v_old.id is null then
    raise exception 'Unidad no encontrada';
  end if;

  if v_old.status <> 'available' then
    raise exception 'Solo se pueden corregir unidades disponibles. Estado actual: %', v_old.status;
  end if;

  select * into v_product
  from public.device_products
  where external_code = p_external_code and active = true;

  if v_product.id is null then
    raise exception 'Producto/dispositivo destino no activo o no existe';
  end if;

  update public.device_units
  set device_product_id = v_product.id,
      lot_no = nullif(trim(coalesce(p_lot_no,'')), ''),
      expires_at = p_expires_at,
      cost = p_cost,
      source_doc_no = nullif(trim(coalesce(p_source_doc_no,'')), ''),
      note = nullif(trim(coalesce(p_note,'')), '')
  where id = p_device_unit_id;

  update public.device_inventory_movements
  set device_product_id = v_product.id,
      note = concat_ws(' | ', note, 'Corregido: ' || v_reason)
  where device_unit_id = p_device_unit_id
    and movement_type = 'receive';

  insert into public.device_admin_audit(
    device_unit_id, device_product_id, action, reason, old_data, new_data, created_by
  ) values (
    p_device_unit_id, v_product.id, 'unit_update', v_reason,
    to_jsonb(v_old),
    jsonb_build_object(
      'device_product_id', v_product.id,
      'external_code', v_product.external_code,
      'lot_no', nullif(trim(coalesce(p_lot_no,'')), ''),
      'expires_at', p_expires_at,
      'cost', p_cost,
      'source_doc_no', nullif(trim(coalesce(p_source_doc_no,'')), ''),
      'note', nullif(trim(coalesce(p_note,'')), '')
    ),
    v_user_id
  );

  return jsonb_build_object('status', 'updated', 'device_unit_id', p_device_unit_id);
end;
$$;

create or replace function public.rpc_device_unit_retire(
  p_session_token text,
  p_device_unit_id uuid,
  p_new_status text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_old public.device_units%rowtype;
  v_status text := lower(trim(coalesce(p_new_status,'')));
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede retirar unidades de dispositivos';
  end if;

  if v_status not in ('inactive','damaged','lost','retired') then
    raise exception 'Estado de retiro no permitido';
  end if;

  if v_reason is null then
    raise exception 'Motivo requerido para retirar una unidad';
  end if;

  select * into v_old
  from public.device_units
  where id = p_device_unit_id
  for update;

  if v_old.id is null then
    raise exception 'Unidad no encontrada';
  end if;

  if v_old.status <> 'available' then
    raise exception 'Solo se pueden retirar unidades disponibles. Estado actual: %', v_old.status;
  end if;

  update public.device_units
  set status = v_status,
      note = concat_ws(' | ', note, 'Retiro admin: ' || v_reason)
  where id = p_device_unit_id;

  insert into public.device_inventory_movements(
    device_unit_id, device_product_id, serial_code, movement_type, qty_delta,
    source_type, source_id, source_event_key, note, created_by
  ) values (
    v_old.id, v_old.device_product_id, v_old.serial_code, 'admin_adjustment', -1,
    'device_unit_retire', v_old.id, 'device_unit_retire:' || v_old.id::text,
    'Retiro administrativo: ' || v_reason, v_user_id
  )
  on conflict (source_event_key) where source_event_key is not null do nothing;

  insert into public.device_admin_audit(
    device_unit_id, device_product_id, action, reason, old_data, new_data, created_by
  ) values (
    v_old.id, v_old.device_product_id, 'unit_retire', v_reason,
    to_jsonb(v_old),
    jsonb_build_object('status', v_status, 'reason', v_reason),
    v_user_id
  );

  return jsonb_build_object('status', v_status, 'device_unit_id', p_device_unit_id);
end;
$$;

grant execute on function public.rpc_device_unit_admin_list(text, text, text, integer) to anon, authenticated;
grant execute on function public.rpc_device_units_bulk_register(text, integer, jsonb, text, date, numeric, text, text) to anon, authenticated;
grant execute on function public.rpc_device_unit_update(text, uuid, integer, text, date, numeric, text, text, text) to anon, authenticated;
grant execute on function public.rpc_device_unit_retire(text, uuid, text, text) to anon, authenticated;
