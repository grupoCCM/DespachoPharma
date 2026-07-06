create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  movement_type text not null,
  source_type text not null,
  source_id uuid,
  source_item_id uuid,
  source_event_key text,
  medicine_id uuid references public.medicines(id),
  external_code integer,
  barcode text,
  qty_delta numeric(14,4) not null,
  unit_cost numeric(14,4),
  note text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint inventory_movements_qty_nonzero check (qty_delta <> 0)
);

create unique index if not exists ux_inventory_movements_source_event_key
  on public.inventory_movements(source_event_key)
  where source_event_key is not null;

create index if not exists ix_inventory_movements_external_created
  on public.inventory_movements(external_code, created_at);

create index if not exists ix_inventory_movements_barcode_created
  on public.inventory_movements(barcode, created_at);

create or replace view public.vw_inventory_live as
with latest_snapshot as (
  select id, created_at
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
),
snapshot_stock as (
  select
    i.external_code,
    i.medicine_id,
    m.barcode,
    i.description_snapshot,
    i.model,
    i.presentation,
    i.stock_qty,
    i.unit_cost,
    i.stock_value,
    s.created_at as snapshot_created_at
  from latest_snapshot s
  join public.inventory_snapshot_items i on i.snapshot_id = s.id
  left join public.medicines m on m.id = i.medicine_id
),
movement_stock as (
  select
    im.external_code,
    sum(im.qty_delta) as movement_qty
  from public.inventory_movements im
  cross join latest_snapshot s
  where im.external_code is not null
    and im.created_at > s.created_at
  group by im.external_code
)
select
  ss.external_code,
  ss.medicine_id,
  ss.barcode,
  ss.description_snapshot,
  ss.model,
  ss.presentation,
  ss.stock_qty as snapshot_stock_qty,
  coalesce(ms.movement_qty, 0) as movement_qty,
  ss.stock_qty + coalesce(ms.movement_qty, 0) as stock_qty,
  ss.unit_cost,
  case
    when ss.unit_cost is null then ss.stock_value
    else (ss.stock_qty + coalesce(ms.movement_qty, 0)) * ss.unit_cost
  end as stock_value,
  ss.snapshot_created_at
from snapshot_stock ss
left join movement_stock ms on ms.external_code = ss.external_code;

create or replace function public.inventory_insert_dispatch_movement(
  p_dispatch_id uuid,
  p_item_id uuid,
  p_barcode text,
  p_qty_delta numeric,
  p_movement_type text,
  p_source_type text,
  p_event_key text,
  p_user_id uuid default null,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_medicine_id uuid;
  v_external_code integer;
begin
  if coalesce(p_qty_delta, 0) = 0 then
    return;
  end if;

  select id, external_code
    into v_medicine_id, v_external_code
  from public.medicines
  where barcode = p_barcode
  order by active desc, external_code
  limit 1;

  insert into public.inventory_movements(
    movement_type,
    source_type,
    source_id,
    source_item_id,
    source_event_key,
    medicine_id,
    external_code,
    barcode,
    qty_delta,
    note,
    created_by,
    metadata
  )
  values (
    p_movement_type,
    p_source_type,
    p_dispatch_id,
    p_item_id,
    p_event_key,
    v_medicine_id,
    v_external_code,
    p_barcode,
    p_qty_delta,
    p_note,
    p_user_id,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('resolved', v_external_code is not null)
  )
  on conflict (source_event_key) where source_event_key is not null do nothing;
end;
$$;

create or replace function public.rpc_cashier_validate(p_session_token text, p_dispatch_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_item record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role not in ('cashier','admin') then
    raise exception 'Permiso denegado';
  end if;

  select status into v_status
  from public.dispatch_header
  where id = p_dispatch_id;

  if v_status <> 'confirmed' then
    raise exception 'Solo se puede validar si está confirmed';
  end if;

  update public.dispatch_header
     set status = 'validated',
         validated_by = v_user_id,
         validated_at = now()
   where id = p_dispatch_id;

  for v_item in
    select id, barcode, qty, product_name_snapshot
    from public.dispatch_items
    where dispatch_id = p_dispatch_id
  loop
    perform public.inventory_insert_dispatch_movement(
      p_dispatch_id,
      v_item.id,
      v_item.barcode,
      -1 * v_item.qty,
      'dispatch_out',
      'dispatch_validate',
      'dispatch_validate:' || v_item.id::text,
      v_user_id,
      'Descuento por despacho validado',
      jsonb_build_object('product_name', v_item.product_name_snapshot)
    );
  end loop;

  insert into public.audit_log(event_type, user_id, dispatch_id)
  values ('CASHIER_VALIDATE', v_user_id, p_dispatch_id);
end;
$$;

create or replace function public.rpc_dispatch_void(p_session_token text, p_dispatch_id uuid, p_reason text default null::text)
returns table(success boolean, dispatch_id uuid, previous_status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_delivery bigint;
  v_expediente text;
  v_item record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo el administrador puede anular despachos';
  end if;

  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'Debe indicar un motivo para la anulación';
  end if;

  select status, delivery_no, expediente
    into v_status, v_delivery, v_expediente
  from public.dispatch_header
  where id = p_dispatch_id;

  if v_status is null then
    raise exception 'Despacho no encontrado';
  end if;

  if v_status = 'voided' then
    raise exception 'Este despacho ya fue anulado previamente';
  end if;

  if v_status = 'validated' then
    for v_item in
      select id, barcode, qty, product_name_snapshot
      from public.dispatch_items
      where dispatch_id = p_dispatch_id
    loop
      perform public.inventory_insert_dispatch_movement(
        p_dispatch_id,
        v_item.id,
        v_item.barcode,
        v_item.qty,
        'dispatch_return',
        'dispatch_void',
        'dispatch_void:' || v_item.id::text,
        v_user_id,
        'Devolución por anulación de despacho validado',
        jsonb_build_object('product_name', v_item.product_name_snapshot, 'reason', p_reason)
      );
    end loop;
  end if;

  update public.dispatch_header
     set status = 'voided',
         voided_by = v_user_id,
         voided_at = now(),
         void_reason = p_reason,
         updated_at = now()
   where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_VOID',
    v_user_id,
    p_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery,
      'expediente', v_expediente,
      'previous_status', v_status::text,
      'reason', p_reason
    )
  );

  return query select true, p_dispatch_id, v_status::text;
end;
$$;

create or replace function public.rpc_dispatch_adjust_item(
  p_session_token text,
  p_dispatch_id uuid,
  p_item_id uuid,
  p_new_qty integer,
  p_reason text default null::text
)
returns table(success boolean, item_id uuid, old_qty integer, new_qty integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_delivery_no bigint;
  v_old_qty integer;
  v_barcode text;
  v_product_name text;
  v_items_left integer;
  v_delta numeric;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo el administrador puede ajustar items';
  end if;

  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'Debe indicar un motivo para el ajuste';
  end if;

  if p_new_qty < 0 then
    raise exception 'La cantidad no puede ser negativa';
  end if;

  select status, delivery_no into v_status, v_delivery_no
  from public.dispatch_header
  where id = p_dispatch_id;

  if v_status is null then
    raise exception 'Despacho no encontrado';
  end if;

  if v_status = 'voided' then
    raise exception 'No se puede ajustar un despacho anulado';
  end if;

  select qty, barcode, product_name_snapshot
    into v_old_qty, v_barcode, v_product_name
  from public.dispatch_items
  where id = p_item_id and dispatch_id = p_dispatch_id;

  if v_old_qty is null then
    raise exception 'Item no encontrado en este despacho';
  end if;

  if v_old_qty = p_new_qty then
    raise exception 'La cantidad nueva es igual a la actual (%)', v_old_qty;
  end if;

  if v_status = 'validated' then
    v_delta := v_old_qty - p_new_qty;
    perform public.inventory_insert_dispatch_movement(
      p_dispatch_id,
      p_item_id,
      v_barcode,
      v_delta,
      case when v_delta > 0 then 'dispatch_adjust_return' else 'dispatch_adjust_out' end,
      'dispatch_adjust',
      'dispatch_adjust:' || p_item_id::text || ':' || gen_random_uuid()::text,
      v_user_id,
      'Ajuste de despacho validado',
      jsonb_build_object('old_qty', v_old_qty, 'new_qty', p_new_qty, 'reason', p_reason, 'product_name', v_product_name)
    );
  end if;

  if p_new_qty = 0 then
    select count(*) into v_items_left
    from public.dispatch_items
    where dispatch_id = p_dispatch_id and id <> p_item_id;

    if v_items_left = 0 then
      raise exception 'No se puede eliminar el último item. Use "Anular despacho" en su lugar.';
    end if;

    delete from public.dispatch_items
    where id = p_item_id and dispatch_id = p_dispatch_id;
  else
    update public.dispatch_items
       set qty = p_new_qty,
           updated_at = now()
     where id = p_item_id and dispatch_id = p_dispatch_id;
  end if;

  update public.dispatch_header
     set updated_at = now()
   where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_ADJUST_ITEM',
    v_user_id,
    p_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery_no,
      'item_id', p_item_id,
      'barcode', v_barcode,
      'product_name', v_product_name,
      'old_qty', v_old_qty,
      'new_qty', p_new_qty,
      'action', case when p_new_qty = 0 then 'REMOVED' else 'ADJUSTED' end,
      'reason', p_reason
    )
  );

  return query select true, p_item_id, v_old_qty, p_new_qty;
end;
$$;

create or replace function public.inventory_purchase_item_movement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_purchase_date date;
begin
  if coalesce(new.qty, 0) = 0 then
    return new;
  end if;

  select purchase_date
    into v_purchase_date
  from public.purchase_documents
  where id = new.purchase_document_id;

  insert into public.inventory_movements(
    movement_type,
    source_type,
    source_id,
    source_item_id,
    source_event_key,
    medicine_id,
    external_code,
    barcode,
    qty_delta,
    unit_cost,
    note,
    metadata
  )
  select
    'purchase_in',
    'purchase_file',
    new.purchase_document_id,
    new.id,
    'purchase_item:' || new.id::text,
    new.medicine_id,
    new.external_code,
    m.barcode,
    new.qty,
    new.unit_cost_estimated,
    'Ingreso por línea nueva de archivo de compras',
    jsonb_build_object(
      'purchase_date', v_purchase_date,
      'description', new.description_snapshot,
      'source_file', new.source_file,
      'source_row_number', new.source_row_number,
      'resolved', new.external_code is not null
    )
  from public.medicines m
  where m.id = new.medicine_id
  on conflict (source_event_key) where source_event_key is not null do nothing;

  if new.medicine_id is null then
    insert into public.inventory_movements(
      movement_type,
      source_type,
      source_id,
      source_item_id,
      source_event_key,
      medicine_id,
      external_code,
      barcode,
      qty_delta,
      unit_cost,
      note,
      metadata
    )
    values (
      'purchase_in',
      'purchase_file',
      new.purchase_document_id,
      new.id,
      'purchase_item:' || new.id::text,
      null,
      new.external_code,
      null,
      new.qty,
      new.unit_cost_estimated,
      'Ingreso por línea nueva de archivo de compras sin catálogo resuelto',
      jsonb_build_object(
        'purchase_date', v_purchase_date,
        'description', new.description_snapshot,
        'source_file', new.source_file,
        'source_row_number', new.source_row_number,
        'resolved', false
      )
    )
    on conflict (source_event_key) where source_event_key is not null do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_inventory_purchase_item_movement on public.purchase_items;
create trigger trg_inventory_purchase_item_movement
after insert on public.purchase_items
for each row execute function public.inventory_purchase_item_movement();

create or replace function public.rpc_public_availability_search(p_query text, p_limit integer default 30)
returns jsonb
language sql
security definer
set search_path = public
as $$
with latest_ref as (
  select distinct on (external_code)
    external_code,
    reference_price
  from public.medicine_reference_prices
  order by external_code, loaded_at desc
),
latest_rotation as (
  select rr.id
  from public.rotation_runs rr
  order by rr.cutoff_date desc nulls last, rr.created_at desc
  limit 1
),
base as (
  select
    m.external_code,
    m.name as medicine_name,
    m.secondary_name,
    m.brand_name,
    m.presentation_name,
    m.model,
    m.subgroup_name,
    m.barcode,
    m.active,
    m.price_1 as sale_price,
    coalesce(i.stock_qty, 0) as stock_qty,
    coalesce(i.stock_value, 0) as stock_value,
    coalesce(o.reference_price, lr.reference_price) as reference_price,
    rm.monthly_rotation,
    rm.coverage_months,
    rm.last_sale_date
  from public.medicines m
  left join public.vw_inventory_live i on i.external_code = m.external_code
  left join latest_ref lr on lr.external_code = m.external_code
  left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
  left join latest_rotation r on true
  left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
  where coalesce(trim(p_query), '') = ''
     or m.external_code::text = trim(p_query)
     or coalesce(m.barcode, '') ilike '%' || trim(p_query) || '%'
     or m.name ilike '%' || trim(p_query) || '%'
     or coalesce(m.secondary_name, '') ilike '%' || trim(p_query) || '%'
     or coalesce(m.model, '') ilike '%' || trim(p_query) || '%'
     or coalesce(m.brand_name, '') ilike '%' || trim(p_query) || '%'
     or coalesce(m.presentation_name, '') ilike '%' || trim(p_query) || '%'
     or coalesce(m.subgroup_name, '') ilike '%' || trim(p_query) || '%'
)
select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
from (
  select
    external_code,
    medicine_name,
    secondary_name,
    brand_name,
    presentation_name,
    model,
    subgroup_name,
    barcode,
    active,
    stock_qty,
    sale_price,
    reference_price,
    monthly_rotation,
    coverage_months,
    last_sale_date,
    case
      when active is false then 'Inactivo'
      when stock_qty <= 0 then 'Agotado'
      when stock_qty < 15 then 'Pocas unidades'
      else 'Disponible'
    end as availability_status
  from base
  order by
    case
      when active is false then 3
      when stock_qty <= 0 then 2
      when stock_qty < 15 then 1
      else 0
    end,
    medicine_name
  limit greatest(1, least(coalesce(p_limit, 30), 100))
) x;
$$;

grant select on public.inventory_movements to authenticated;
grant select on public.vw_inventory_live to anon, authenticated;
grant execute on function public.rpc_public_availability_search(text, integer) to anon, authenticated;
