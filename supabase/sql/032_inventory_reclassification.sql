do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_RECLASSIFY';
exception when duplicate_object then null;
end $$;

create table if not exists public.inventory_reclassifications (
  id uuid primary key default gen_random_uuid(),
  from_medicine_id uuid not null references public.medicines(id),
  from_external_code integer not null,
  to_medicine_id uuid not null references public.medicines(id),
  to_external_code integer not null,
  qty numeric(14,4) not null,
  reference_doc text,
  reason text not null,
  note text,
  out_movement_id uuid references public.inventory_movements(id),
  in_movement_id uuid references public.inventory_movements(id),
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint inventory_reclassifications_qty_chk check (qty > 0 and qty = trunc(qty)),
  constraint inventory_reclassifications_different_products_chk check (from_external_code <> to_external_code)
);

create index if not exists ix_inventory_reclassifications_created
on public.inventory_reclassifications(created_at desc);

create index if not exists ix_inventory_reclassifications_products
on public.inventory_reclassifications(from_external_code, to_external_code, created_at desc);

alter table public.inventory_reclassifications enable row level security;

create or replace function public.rpc_inventory_reclassify(
  p_session_token text,
  p_from_external_code integer,
  p_to_external_code integer,
  p_qty numeric,
  p_reference_doc text default null,
  p_reason text default null,
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
  v_from record;
  v_to record;
  v_qty numeric := coalesce(p_qty, 0);
  v_from_stock numeric;
  v_reference text := nullif(trim(coalesce(p_reference_doc, '')), '');
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_reclass_id uuid;
  v_out_movement_id uuid;
  v_in_movement_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  if p_from_external_code is null or p_to_external_code is null then
    raise exception 'Selecciona producto origen y destino';
  end if;

  if p_from_external_code = p_to_external_code then
    raise exception 'El producto origen y destino no pueden ser el mismo';
  end if;

  if v_qty <= 0 or v_qty <> trunc(v_qty) then
    raise exception 'La cantidad debe ser un entero mayor que 0';
  end if;

  if v_reason is null then
    raise exception 'Debes indicar el motivo de la reclasificacion';
  end if;

  select m.id, m.external_code, m.barcode, m.name, m.model, coalesce(vl.stock_qty, 0) as stock_qty, coalesce(vl.unit_cost, 0) as unit_cost
    into v_from
  from public.medicines m
  left join public.vw_inventory_live vl on vl.external_code = m.external_code
  where m.external_code = p_from_external_code
    and m.active is true
  limit 1;

  if v_from.id is null then
    raise exception 'Producto origen activo no encontrado';
  end if;

  select m.id, m.external_code, m.barcode, m.name, m.model, coalesce(vl.stock_qty, 0) as stock_qty, coalesce(vl.unit_cost, 0) as unit_cost
    into v_to
  from public.medicines m
  left join public.vw_inventory_live vl on vl.external_code = m.external_code
  where m.external_code = p_to_external_code
    and m.active is true
  limit 1;

  if v_to.id is null then
    raise exception 'Producto destino activo no encontrado';
  end if;

  select coalesce(stock_qty, 0)
    into v_from_stock
  from public.vw_inventory_live
  where external_code = p_from_external_code;

  v_from_stock := coalesce(v_from_stock, 0);

  if v_from_stock < v_qty then
    raise exception 'No se puede reclasificar %. Disponible en origen: %', v_qty::integer, v_from_stock::integer;
  end if;

  insert into public.inventory_reclassifications(
    from_medicine_id,
    from_external_code,
    to_medicine_id,
    to_external_code,
    qty,
    reference_doc,
    reason,
    note,
    created_by,
    metadata
  )
  values (
    v_from.id,
    v_from.external_code,
    v_to.id,
    v_to.external_code,
    v_qty,
    v_reference,
    v_reason,
    v_note,
    v_user_id,
    jsonb_build_object(
      'from_name', v_from.name,
      'from_barcode', v_from.barcode,
      'from_model', v_from.model,
      'to_name', v_to.name,
      'to_barcode', v_to.barcode,
      'to_model', v_to.model
    )
  )
  returning id into v_reclass_id;

  insert into public.inventory_movements(
    movement_type,
    source_type,
    source_id,
    source_event_key,
    medicine_id,
    external_code,
    barcode,
    qty_delta,
    unit_cost,
    note,
    created_by,
    metadata
  )
  values (
    'reclass_out',
    'inventory_reclass',
    v_reclass_id,
    'inventory_reclass:' || v_reclass_id::text || ':out',
    v_from.id,
    v_from.external_code,
    v_from.barcode,
    -1 * v_qty,
    v_from.unit_cost,
    'Salida por reclasificacion de inventario',
    v_user_id,
    jsonb_build_object(
      'reclassification_id', v_reclass_id,
      'direction', 'out',
      'counterpart_external_code', v_to.external_code,
      'counterpart_name', v_to.name,
      'reference_doc', v_reference,
      'reason', v_reason,
      'note', v_note
    )
  )
  returning id into v_out_movement_id;

  insert into public.inventory_movements(
    movement_type,
    source_type,
    source_id,
    source_event_key,
    medicine_id,
    external_code,
    barcode,
    qty_delta,
    unit_cost,
    note,
    created_by,
    metadata
  )
  values (
    'reclass_in',
    'inventory_reclass',
    v_reclass_id,
    'inventory_reclass:' || v_reclass_id::text || ':in',
    v_to.id,
    v_to.external_code,
    v_to.barcode,
    v_qty,
    coalesce(nullif(v_to.unit_cost, 0), v_from.unit_cost),
    'Entrada por reclasificacion de inventario',
    v_user_id,
    jsonb_build_object(
      'reclassification_id', v_reclass_id,
      'direction', 'in',
      'counterpart_external_code', v_from.external_code,
      'counterpart_name', v_from.name,
      'reference_doc', v_reference,
      'reason', v_reason,
      'note', v_note
    )
  )
  returning id into v_in_movement_id;

  update public.inventory_reclassifications
     set out_movement_id = v_out_movement_id,
         in_movement_id = v_in_movement_id
   where id = v_reclass_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'INVENTORY_RECLASSIFY',
    v_user_id,
    jsonb_build_object(
      'reclassification_id', v_reclass_id,
      'from_external_code', v_from.external_code,
      'from_name', v_from.name,
      'to_external_code', v_to.external_code,
      'to_name', v_to.name,
      'qty', v_qty,
      'reference_doc', v_reference,
      'reason', v_reason,
      'out_movement_id', v_out_movement_id,
      'in_movement_id', v_in_movement_id
    )
  );

  return jsonb_build_object(
    'ok', true,
    'id', v_reclass_id,
    'qty', v_qty,
    'from_external_code', v_from.external_code,
    'from_name', v_from.name,
    'to_external_code', v_to.external_code,
    'to_name', v_to.name,
    'out_movement_id', v_out_movement_id,
    'in_movement_id', v_in_movement_id
  );
end;
$$;

grant execute on function public.rpc_inventory_reclassify(text, integer, integer, numeric, text, text, text) to anon, authenticated;
