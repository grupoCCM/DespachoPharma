-- Correct individual dispatch items without deleting their traceability.
-- Validated reductions return inventory to the exact lot previously consumed.

begin;

alter table public.dispatch_items
  add column if not exists original_qty integer,
  add column if not exists line_status text not null default 'active',
  add column if not exists corrected_at timestamptz,
  add column if not exists corrected_by uuid references public.app_users(id),
  add column if not exists correction_reason text;

update public.dispatch_items
set original_qty = qty
where original_qty is null;

alter table public.dispatch_items
  alter column original_qty set not null;

alter table public.dispatch_items
  drop constraint if exists dispatch_items_qty_check,
  drop constraint if exists dispatch_items_original_qty_check,
  drop constraint if exists dispatch_items_line_status_check,
  drop constraint if exists dispatch_items_effective_state_check;

alter table public.dispatch_items
  add constraint dispatch_items_qty_check check (qty >= 0),
  add constraint dispatch_items_original_qty_check check (original_qty > 0 and qty <= original_qty),
  add constraint dispatch_items_line_status_check check (line_status in ('active', 'removed')),
  add constraint dispatch_items_effective_state_check check (
    (line_status = 'active' and qty > 0)
    or (line_status = 'removed' and qty = 0)
  );

create or replace function public.dispatch_item_preserve_original_qty()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  if tg_op = 'INSERT' and new.original_qty is null then
    new.original_qty := new.qty;
  elsif tg_op = 'UPDATE'
    and new.qty > old.original_qty
    and old.corrected_at is null then
    new.original_qty := new.qty;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_dispatch_item_preserve_original_qty on public.dispatch_items;
create trigger trg_dispatch_item_preserve_original_qty
before insert or update of qty on public.dispatch_items
for each row execute function public.dispatch_item_preserve_original_qty();

create table if not exists public.dispatch_item_adjustments (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.dispatch_header(id) on delete restrict,
  dispatch_item_id uuid not null references public.dispatch_items(id) on delete restrict,
  old_qty integer not null check (old_qty > 0),
  new_qty integer not null check (new_qty >= 0),
  qty_delta integer not null check (qty_delta > 0),
  reason text not null check (length(trim(reason)) > 0),
  dispatch_status public.dispatch_status not null,
  inventory_movement_id uuid references public.inventory_movements(id) on delete restrict,
  reservation_units_released numeric(14,4) not null default 0 check (reservation_units_released >= 0),
  created_by uuid not null references public.app_users(id),
  created_at timestamptz not null default now(),
  constraint dispatch_item_adjustments_qty_check check (new_qty < old_qty and qty_delta = old_qty - new_qty)
);

create index if not exists idx_dispatch_item_adjustments_dispatch
  on public.dispatch_item_adjustments(dispatch_id, created_at);

create index if not exists idx_dispatch_item_adjustments_item
  on public.dispatch_item_adjustments(dispatch_item_id, created_at);

alter table public.dispatch_item_adjustments enable row level security;
revoke all on table public.dispatch_item_adjustments from public, anon, authenticated;

drop function if exists public.rpc_dispatch_adjust_item(text, uuid, uuid, integer, text);
drop function if exists public.rpc_dispatch_adjust_item(text, uuid, uuid, integer, text, boolean);

create function public.rpc_dispatch_adjust_item(
  p_session_token text,
  p_dispatch_id uuid,
  p_item_id uuid,
  p_new_qty integer,
  p_reason text default null,
  p_physical_return_confirmed boolean default false
)
returns table(success boolean, item_id uuid, old_qty integer, new_qty integer)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_source_kind text;
  v_inventory_effect text;
  v_reservation_version smallint;
  v_delivery_no bigint;
  v_old_qty integer;
  v_barcode text;
  v_product_name text;
  v_line_status text;
  v_items_left integer;
  v_delta integer;
  v_adjustment_id uuid := gen_random_uuid();
  v_inventory_movement_id uuid;
  v_lot_returned numeric := 0;
  v_release_remaining numeric;
  v_released numeric := 0;
  v_reserved numeric;
  v_res record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Permiso denegado: solo el administrador puede corregir productos'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'Debe indicar un motivo para la correccion'; end if;
  if p_new_qty is null or p_new_qty < 0 then raise exception 'La cantidad no puede ser negativa'; end if;

  select status, source_kind, inventory_effect, stock_reservation_version, delivery_no
    into v_status, v_source_kind, v_inventory_effect, v_reservation_version, v_delivery_no
  from public.dispatch_header
  where id = p_dispatch_id
  for update;

  if v_status is null then raise exception 'Despacho no encontrado'; end if;
  if v_status = 'voided' then raise exception 'No se puede corregir un despacho anulado'; end if;
  if v_source_kind <> 'internal_dispatch' or v_inventory_effect <> 'cashier_validation' then
    raise exception 'Las ventas externas conciliadas no se corrigen desde este flujo';
  end if;

  select qty, barcode, product_name_snapshot, line_status
    into v_old_qty, v_barcode, v_product_name, v_line_status
  from public.dispatch_items
  where id = p_item_id and dispatch_id = p_dispatch_id
  for update;

  if v_old_qty is null then raise exception 'Producto no encontrado en este despacho'; end if;
  if v_line_status <> 'active' or v_old_qty <= 0 then raise exception 'Este producto ya fue retirado del despacho'; end if;
  if p_new_qty = v_old_qty then raise exception 'La cantidad nueva es igual a la actual (%)', v_old_qty; end if;
  if p_new_qty > v_old_qty then
    raise exception 'Este flujo solo permite disminuir cantidades. Registre una nueva entrega para agregar unidades.';
  end if;

  if p_new_qty = 0 then
    select count(*) into v_items_left
    from public.dispatch_items
    where dispatch_id = p_dispatch_id
      and id <> p_item_id
      and line_status = 'active'
      and qty > 0;

    if v_items_left = 0 then
      raise exception 'No se puede retirar el ultimo producto. Use "Anular despacho" en su lugar.';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('dispatch_stock:' || v_barcode, 0));
  v_delta := v_old_qty - p_new_qty;

  -- A confirmed dispatch has not moved physical stock yet. Release only its reservation.
  if v_status = 'confirmed' and coalesce(v_reservation_version, 0) >= 1 then
    perform 1
    from public.inventory_reservations
    where dispatch_item_id = p_item_id and status = 'active'
    for update;

    select coalesce(sum(qty), 0) into v_reserved
    from public.inventory_reservations
    where dispatch_item_id = p_item_id and status = 'active';

    if v_reserved <> v_old_qty then
      raise exception 'La reserva del producto ya no coincide con el despacho. Recargue e intente nuevamente.';
    end if;

    v_release_remaining := v_delta;
    for v_res in
      select r.*, l.expires_at, l.lot_no
      from public.inventory_reservations r
      join public.inventory_lots l on l.id = r.lot_id
      where r.dispatch_item_id = p_item_id and r.status = 'active'
      order by l.expires_at desc nulls first, l.lot_no desc nulls first, r.id desc
      for update of r
    loop
      exit when v_release_remaining <= 0;

      if v_release_remaining >= v_res.qty then
        update public.inventory_reservations
        set status = 'released',
            released_at = now(),
            release_reason = 'dispatch_item_correction',
            updated_at = now()
        where id = v_res.id;

        v_release_remaining := v_release_remaining - v_res.qty;
        v_released := v_released + v_res.qty;
      else
        update public.inventory_reservations
        set qty = qty - v_release_remaining,
            updated_at = now()
        where id = v_res.id;

        insert into public.inventory_reservations(
          dispatch_id, dispatch_item_id, medicine_id, external_code, barcode,
          lot_id, qty, status, reserved_at, released_at, release_reason, created_by
        ) values (
          v_res.dispatch_id, v_res.dispatch_item_id, v_res.medicine_id, v_res.external_code,
          v_res.barcode, v_res.lot_id, v_release_remaining, 'released', v_res.reserved_at,
          now(), 'dispatch_item_correction', v_res.created_by
        );

        v_released := v_released + v_release_remaining;
        v_release_remaining := 0;
      end if;
    end loop;

    if v_release_remaining > 0 then
      raise exception 'No se pudo liberar completamente la reserva del producto. Faltante: %', v_release_remaining;
    end if;

    select coalesce(sum(qty), 0) into v_reserved
    from public.inventory_reservations
    where dispatch_item_id = p_item_id and status = 'active';

    if v_reserved <> p_new_qty then
      raise exception 'La reserva restante no coincide con la nueva cantidad';
    end if;
  end if;

  -- A validated dispatch already moved stock. Return the correction to its original lot.
  if v_status = 'validated' then
    if not coalesce(p_physical_return_confirmed, false) then
      raise exception 'Debe confirmar que las unidades regresaron fisicamente antes de devolverlas al inventario';
    end if;

    perform public.inventory_insert_dispatch_movement(
      p_dispatch_id,
      p_item_id,
      v_barcode,
      v_delta,
      'dispatch_adjust_return',
      'dispatch_adjust',
      'dispatch_adjust:' || v_adjustment_id::text,
      v_user_id,
      'Devolucion por correccion de producto en despacho validado',
      jsonb_build_object(
        'adjustment_id', v_adjustment_id,
        'old_qty', v_old_qty,
        'new_qty', p_new_qty,
        'reason', trim(p_reason),
        'product_name', v_product_name,
        'physical_return_confirmed', p_physical_return_confirmed
      )
    );

    select id into v_inventory_movement_id
    from public.inventory_movements
    where source_event_key = 'dispatch_adjust:' || v_adjustment_id::text;

    if v_inventory_movement_id is null then
      raise exception 'No se pudo registrar la devolucion de inventario';
    end if;

    select coalesce(sum(qty_delta), 0) into v_lot_returned
    from public.inventory_lot_movements
    where inventory_movement_id = v_inventory_movement_id;

    if v_lot_returned <> v_delta then
      raise exception 'No se pudo devolver la correccion al lote original. Esperado: %, aplicado: %',
        v_delta, v_lot_returned;
    end if;
  end if;

  update public.dispatch_items
  set qty = p_new_qty,
      line_status = case when p_new_qty = 0 then 'removed' else 'active' end,
      corrected_at = now(),
      corrected_by = v_user_id,
      correction_reason = trim(p_reason),
      updated_at = now()
  where id = p_item_id and dispatch_id = p_dispatch_id;

  insert into public.dispatch_item_adjustments(
    id, dispatch_id, dispatch_item_id, old_qty, new_qty, qty_delta, reason,
    dispatch_status, inventory_movement_id, reservation_units_released, created_by
  ) values (
    v_adjustment_id, p_dispatch_id, p_item_id, v_old_qty, p_new_qty, v_delta,
    trim(p_reason), v_status, v_inventory_movement_id, v_released, v_user_id
  );

  update public.dispatch_header set updated_at = now() where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_ADJUST_ITEM', v_user_id, p_dispatch_id,
    jsonb_build_object(
      'adjustment_id', v_adjustment_id,
      'delivery_no', v_delivery_no,
      'item_id', p_item_id,
      'barcode', v_barcode,
      'product_name', v_product_name,
      'old_qty', v_old_qty,
      'new_qty', p_new_qty,
      'reason', trim(p_reason),
      'dispatch_status', v_status,
      'reservation_units_released', v_released,
      'inventory_movement_id', v_inventory_movement_id
    )
  );

  return query select true, p_item_id, v_old_qty, p_new_qty;
end;
$function$;

create or replace function public.rpc_cashier_validate(p_session_token text, p_dispatch_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_source_kind text;
  v_inventory_effect text;
  v_reservation_version smallint;
  v_item record;
  v_reserved numeric;
  v_item_count integer;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role not in ('cashier','admin') then raise exception 'Permiso denegado'; end if;

  select status, source_kind, inventory_effect, stock_reservation_version
    into v_status, v_source_kind, v_inventory_effect, v_reservation_version
  from public.dispatch_header where id = p_dispatch_id for update;

  if v_status <> 'confirmed' then raise exception 'Solo se puede validar si esta confirmed'; end if;
  if v_source_kind <> 'internal_dispatch' or v_inventory_effect <> 'cashier_validation' then
    raise exception 'Esta entrega corresponde a una venta externa conciliada; no requiere validacion de Caja';
  end if;

  select count(*) into v_item_count
  from public.dispatch_items
  where dispatch_id = p_dispatch_id and line_status = 'active' and qty > 0;

  if v_item_count = 0 then raise exception 'La entrega no tiene productos activos para validar'; end if;

  for v_item in
    select id, barcode, qty, product_name_snapshot
    from public.dispatch_items
    where dispatch_id = p_dispatch_id and line_status = 'active' and qty > 0
    order by barcode, id
  loop
    perform pg_advisory_xact_lock(hashtextextended('dispatch_stock:' || v_item.barcode, 0));

    if coalesce(v_reservation_version, 0) >= 1 then
      perform 1 from public.inventory_reservations
      where dispatch_item_id = v_item.id and status = 'active' for update;

      select coalesce(sum(qty), 0) into v_reserved
      from public.inventory_reservations
      where dispatch_item_id = v_item.id and status = 'active';

      if v_reserved <> v_item.qty then
        raise exception 'La reserva de % ya no esta completa. Recargue la entrega o solicite anulacion.',
          v_item.product_name_snapshot;
      end if;
    else
      perform public.dispatch_raise_if_stock_insufficient(v_item.barcode, v_item.qty, p_dispatch_id);
    end if;
  end loop;

  for v_item in
    select id, barcode, qty, product_name_snapshot
    from public.dispatch_items
    where dispatch_id = p_dispatch_id and line_status = 'active' and qty > 0
    order by barcode, id
  loop
    perform public.inventory_insert_dispatch_movement(
      p_dispatch_id, v_item.id, v_item.barcode, -1 * v_item.qty,
      'dispatch_out', 'dispatch_validate', 'dispatch_validate:' || v_item.id::text,
      v_user_id, 'Descuento por despacho validado',
      jsonb_build_object('product_name', v_item.product_name_snapshot, 'reserved', coalesce(v_reservation_version,0) >= 1)
    );
  end loop;

  if coalesce(v_reservation_version, 0) >= 1 then
    update public.inventory_reservations
    set status = 'fulfilled', fulfilled_at = now(), updated_at = now()
    where dispatch_id = p_dispatch_id and status = 'active';
  end if;

  update public.dispatch_header
  set status = 'validated', validated_by = v_user_id, validated_at = now(), updated_at = now()
  where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values ('CASHIER_VALIDATE', v_user_id, p_dispatch_id,
          jsonb_build_object('stock_reservation_version', coalesce(v_reservation_version,0)));
end;
$function$;

create or replace function public.rpc_dispatch_void(
  p_session_token text,
  p_dispatch_id uuid,
  p_reason text default null
)
returns table(success boolean, dispatch_id uuid, previous_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_source_kind text;
  v_inventory_effect text;
  v_delivery bigint;
  v_expediente text;
  v_item record;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Permiso denegado: solo el administrador puede anular despachos'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'Debe indicar un motivo para la anulacion'; end if;

  select dh.status, dh.delivery_no, dh.expediente, dh.source_kind, dh.inventory_effect
    into v_status, v_delivery, v_expediente, v_source_kind, v_inventory_effect
  from public.dispatch_header dh where dh.id = p_dispatch_id for update;

  if v_status is null then raise exception 'Despacho no encontrado'; end if;
  if v_status = 'voided' then raise exception 'Este despacho ya fue anulado previamente'; end if;

  if v_status = 'validated' and v_source_kind = 'internal_dispatch' and v_inventory_effect = 'cashier_validation' then
    for v_item in
      select di.id, di.barcode, di.qty, di.product_name_snapshot
      from public.dispatch_items di
      where di.dispatch_id = p_dispatch_id and di.line_status = 'active' and di.qty > 0
      order by di.barcode, di.id
    loop
      perform pg_advisory_xact_lock(hashtextextended('dispatch_stock:' || v_item.barcode, 0));
      perform public.inventory_insert_dispatch_movement(
        p_dispatch_id, v_item.id, v_item.barcode, v_item.qty,
        'dispatch_return', 'dispatch_void', 'dispatch_void:' || v_item.id::text,
        v_user_id, 'Devolucion por anulacion de despacho validado',
        jsonb_build_object('product_name', v_item.product_name_snapshot, 'reason', p_reason)
      );
    end loop;
  else
    update public.inventory_reservations
    set status = 'released', released_at = now(), release_reason = 'dispatch_void', updated_at = now()
    where dispatch_id = p_dispatch_id and status = 'active';
  end if;

  update public.dispatch_header dh
  set status = 'voided', voided_by = v_user_id, voided_at = now(), void_reason = p_reason, updated_at = now()
  where dh.id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_VOID', v_user_id, p_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery, 'expediente', v_expediente,
      'previous_status', v_status::text, 'source_kind', v_source_kind,
      'inventory_effect', v_inventory_effect, 'reason', p_reason,
      'reservation_released', v_status <> 'validated'
    )
  );

  return query select true, p_dispatch_id, v_status::text;
end;
$function$;

create or replace function public.rpc_dispatch_search(
  p_session_token text,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_status public.dispatch_status default null,
  p_expediente text default null,
  p_delivery_no bigint default null,
  p_created_by uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(
  dispatch_id uuid, delivery_no bigint, expediente text, status public.dispatch_status,
  created_at timestamptz, confirmed_at timestamptz, created_by uuid, created_by_name text,
  validated_at timestamptz, observed_at timestamptz, items_count integer, total_units integer,
  source_kind text, inventory_effect text, sales_document_id uuid, external_sale_no integer,
  external_voucher_no text, external_sale_date date
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;

  return query
  select
    h.id, h.delivery_no, h.expediente, h.status, h.created_at, h.confirmed_at,
    h.created_by, u.display_name, h.validated_at, h.observed_at,
    (select count(*)::int from public.dispatch_items i
      where i.dispatch_id = h.id and i.line_status = 'active' and i.qty > 0),
    (select coalesce(sum(i.qty),0)::int from public.dispatch_items i
      where i.dispatch_id = h.id and i.line_status = 'active' and i.qty > 0),
    h.source_kind, h.inventory_effect, h.sales_document_id, h.external_sale_no,
    h.external_voucher_no, h.external_sale_date
  from public.dispatch_header h
  join public.app_users u on u.id = h.created_by
  where (p_delivery_no is null or h.delivery_no = p_delivery_no)
    and (p_expediente is null or h.expediente ilike '%' || p_expediente || '%')
    and (p_status is null or h.status = p_status)
    and (p_created_by is null or h.created_by = p_created_by)
    and (p_date_from is null or h.created_at >= p_date_from)
    and (p_date_to is null or h.created_at <= p_date_to)
    and (
      v_role = 'admin'
      or (v_role = 'dispatch' and h.created_by = v_user_id)
      or (v_role = 'cashier' and h.status in ('confirmed','validated','observed') and h.source_kind = 'internal_dispatch')
    )
  order by h.created_at desc
  limit greatest(1, least(p_limit, 200))
  offset greatest(p_offset, 0);
end;
$function$;

create or replace function public.rpc_dispatch_get(p_session_token text, p_dispatch_id uuid)
returns table(header jsonb, items jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_h public.dispatch_header%rowtype;
  v_created_by_name text;
  v_voided_by_name text;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;

  select * into v_h from public.dispatch_header where id = p_dispatch_id;
  if not found then raise exception 'Entrega/Despacho no existe'; end if;
  if v_role = 'dispatch' and v_h.created_by <> v_user_id then raise exception 'Permiso denegado'; end if;
  if v_role = 'cashier' and (v_h.status not in ('confirmed','validated','observed') or v_h.source_kind <> 'internal_dispatch') then
    raise exception 'Permiso denegado';
  end if;

  select display_name into v_created_by_name from public.app_users where id = v_h.created_by;
  if v_h.voided_by is not null then
    select display_name into v_voided_by_name from public.app_users where id = v_h.voided_by;
  end if;

  return query
  select
    jsonb_build_object(
      'dispatch_id', v_h.id, 'delivery_no', v_h.delivery_no, 'expediente', v_h.expediente,
      'status', v_h.status, 'created_at', v_h.created_at, 'created_by', v_h.created_by,
      'created_by_name', v_created_by_name, 'confirmed_at', v_h.confirmed_at,
      'validated_by', v_h.validated_by, 'validated_at', v_h.validated_at,
      'observed_by', v_h.observed_by, 'observed_at', v_h.observed_at,
      'observation_note', v_h.observation_note, 'voided_by', v_h.voided_by,
      'voided_at', v_h.voided_at, 'void_reason', v_h.void_reason,
      'voided_by_name', v_voided_by_name, 'source_kind', v_h.source_kind,
      'inventory_effect', v_h.inventory_effect, 'sales_document_id', v_h.sales_document_id,
      'external_sale_no', v_h.external_sale_no, 'external_voucher_no', v_h.external_voucher_no,
      'external_sale_date', v_h.external_sale_date,
      'items_count', (select count(*)::int from public.dispatch_items i
        where i.dispatch_id = v_h.id and i.line_status = 'active' and i.qty > 0),
      'total_units', (select coalesce(sum(i.qty),0)::int from public.dispatch_items i
        where i.dispatch_id = v_h.id and i.line_status = 'active' and i.qty > 0),
      'corrected_items_count', (select count(*)::int from public.dispatch_items i
        where i.dispatch_id = v_h.id and i.corrected_at is not null)
    ),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id,
        'barcode', i.barcode,
        'product_name', i.product_name_snapshot,
        'qty', i.qty,
        'original_qty', i.original_qty,
        'line_status', i.line_status,
        'corrected_at', i.corrected_at,
        'corrected_by', i.corrected_by,
        'correction_reason', i.correction_reason
      ) order by case when i.line_status = 'active' then 0 else 1 end, i.product_name_snapshot)
      from public.dispatch_items i where i.dispatch_id = v_h.id
    ), '[]'::jsonb);
end;
$function$;

grant execute on function public.rpc_dispatch_adjust_item(text, uuid, uuid, integer, text, boolean) to anon, authenticated;
grant execute on function public.rpc_cashier_validate(text, uuid) to anon, authenticated;
grant execute on function public.rpc_dispatch_void(text, uuid, text) to anon, authenticated;
grant execute on function public.rpc_dispatch_search(text, timestamptz, timestamptz, public.dispatch_status, text, bigint, uuid, integer, integer) to anon, authenticated;
grant execute on function public.rpc_dispatch_get(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
