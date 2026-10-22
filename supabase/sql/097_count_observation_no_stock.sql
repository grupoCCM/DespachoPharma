-- Keep physical-count observations separate from inventory movements.
--
-- A verified variance can be closed without changing stock when the product is
-- found or the variance is documentary. This migration also reverses the
-- premature Izaban 25 adjustment from the 2026-10-20 count after the three
-- units were physically found in lot 019 (expires 2027-09-30).

begin;

create or replace function public.rpc_inventory_variance_resolve(
  p_session_token text,
  p_case_id uuid,
  p_resolution_type text,
  p_qty_resolved numeric,
  p_amount_recovered numeric,
  p_note text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_case record;
  v_already_resolved numeric;
  v_pending numeric;
  v_movement_id uuid;
  v_key text := nullif(trim(p_idempotency_key), '');
  v_existing_case_id uuid;
  v_resolve_without_stock boolean := false;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede resolver expedientes de diferencias'; end if;
  if p_resolution_type not in ('found_recovered','reimbursement','authorized_loss','document_error','responsibility_assigned','supplier_return','other') then raise exception 'Tipo de resolucion invalido'; end if;
  if p_qty_resolved is null or p_qty_resolved <= 0 or p_qty_resolved <> trunc(p_qty_resolved) then raise exception 'La cantidad resuelta debe ser un entero mayor que cero'; end if;
  if coalesce(p_amount_recovered, 0) < 0 then raise exception 'El monto recuperado no puede ser negativo'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Describe la resolucion'; end if;
  if v_key is null then raise exception 'Falta identificador de operacion'; end if;

  select case_id into v_existing_case_id
  from public.inventory_variance_resolutions
  where idempotency_key = v_key;

  if v_existing_case_id is not null then
    select greatest(
      abs(c.confirmed_variance_qty) - coalesce((
        select sum(r.qty_resolved) from public.inventory_variance_resolutions r where r.case_id = c.id
      ), 0),
      0
    ) into v_pending
    from public.inventory_variance_cases c
    where c.id = v_existing_case_id;

    return (
      select to_jsonb(c) || jsonb_build_object('pending_resolution_qty', v_pending, 'idempotent_replay', true)
      from public.inventory_variance_cases c
      where c.id = v_existing_case_id
    );
  end if;

  select c.*, m.barcode, s.status as session_status into v_case
  from public.inventory_variance_cases c
  join public.medicines m on m.id = c.medicine_id
  join public.inventory_count_sessions s on s.id = c.count_session_id
  where c.id = p_case_id
  for update of c;

  if v_case.id is null then raise exception 'Expediente no encontrado'; end if;
  if v_case.session_status = 'cancelled' then raise exception 'No se puede resolver una diferencia de un conteo cancelado'; end if;
  if v_case.verified_qty is null then raise exception 'Verifica primero el segundo conteo'; end if;
  if v_case.investigation_status = 'resolved' then raise exception 'Este expediente ya esta resuelto'; end if;

  select coalesce(sum(qty_resolved), 0) into v_already_resolved
  from public.inventory_variance_resolutions where case_id = p_case_id;
  v_pending := abs(v_case.confirmed_variance_qty) - v_already_resolved;

  if p_qty_resolved > v_pending then raise exception 'La cantidad excede las unidades pendientes del expediente'; end if;
  if p_resolution_type = 'found_recovered' and v_case.confirmed_variance_qty >= 0 then
    raise exception 'La recuperacion fisica solo aplica a faltantes';
  end if;

  v_resolve_without_stock := v_case.stock_adjustment_status = 'pending'
    and p_resolution_type in ('found_recovered', 'document_error');

  if v_case.stock_adjustment_status = 'pending' and not v_resolve_without_stock then
    raise exception 'Aplica la diferencia al inventario o resuelve como producto encontrado/error documental sin ajuste';
  end if;

  if v_resolve_without_stock and p_qty_resolved <> v_pending then
    raise exception 'Antes de ajustar stock, la resolucion sin movimiento debe cerrar todas las unidades pendientes';
  end if;

  -- Recovery changes stock only when a prior administrative adjustment was
  -- actually applied. If stock is still pending, finding the product merely
  -- closes the observation and leaves availability untouched.
  if p_resolution_type = 'found_recovered' and not v_resolve_without_stock then
    perform pg_advisory_xact_lock(93093, v_case.external_code);
    insert into public.inventory_movements(
      movement_type, source_type, source_id, source_item_id, source_event_key,
      medicine_id, external_code, barcode, qty_delta, unit_cost, note, created_by, metadata
    ) values (
      'variance_case_recovery_in', 'inventory_variance_case', v_case.id, v_case.count_item_id,
      'variance_case_recovery:' || v_key,
      v_case.medicine_id, v_case.external_code, v_case.barcode, p_qty_resolved,
      v_case.unit_cost_snapshot, 'Producto recuperado despues de un ajuste administrativo de inventario',
      v_user_id, jsonb_build_object('case_id', v_case.id, 'resolution_type', p_resolution_type)
    ) returning id into v_movement_id;
  end if;

  insert into public.inventory_variance_resolutions(
    case_id, resolution_type, qty_resolved, amount_recovered, note,
    inventory_movement_id, idempotency_key, created_by, metadata
  ) values (
    p_case_id, p_resolution_type, p_qty_resolved, coalesce(p_amount_recovered, 0),
    trim(p_note), v_movement_id, v_key, v_user_id,
    jsonb_build_object('resolved_without_stock_movement', v_resolve_without_stock)
  );

  insert into public.inventory_variance_case_events(
    case_id, event_type, qty, amount, reason_code, note,
    inventory_movement_id, idempotency_key, created_by, metadata
  ) values (
    p_case_id, 'resolution', p_qty_resolved, coalesce(p_amount_recovered, 0),
    p_resolution_type, trim(p_note), v_movement_id,
    'variance_case_resolution_event:' || v_key, v_user_id,
    jsonb_build_object('resolved_without_stock_movement', v_resolve_without_stock)
  );

  v_pending := v_pending - p_qty_resolved;
  update public.inventory_variance_cases
  set investigation_status = case when v_pending = 0 then 'resolved' else 'partially_resolved' end,
      stock_adjustment_status = case
        when v_resolve_without_stock and v_pending = 0 then 'not_required'
        else stock_adjustment_status
      end,
      resolved_by = case when v_pending = 0 then v_user_id else null end,
      resolved_at = case when v_pending = 0 then now() else null end,
      resolution_note = case when v_pending = 0 then trim(p_note) else resolution_note end,
      metadata = metadata || jsonb_build_object(
        'last_resolution_without_stock_movement', v_resolve_without_stock
      )
  where id = p_case_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_ITEM_APPLY', v_user_id, jsonb_build_object(
    'audit_action', 'variance_case_resolve',
    'case_id', p_case_id,
    'resolution_type', p_resolution_type,
    'qty_resolved', p_qty_resolved,
    'remaining_qty', v_pending,
    'movement_id', v_movement_id,
    'resolved_without_stock_movement', v_resolve_without_stock
  ));

  return (select to_jsonb(c) || jsonb_build_object('pending_resolution_qty', v_pending) from public.inventory_variance_cases c where c.id = p_case_id);
end;
$$;

revoke execute on function public.rpc_inventory_variance_resolve(text, uuid, text, numeric, numeric, text, text) from public;
grant execute on function public.rpc_inventory_variance_resolve(text, uuid, text, numeric, numeric, text, text) to anon, authenticated;

do $$
declare
  v_session_id constant uuid := '3d392c92-4b0d-4e17-911d-8c60ae1c7018'::uuid;
  v_external_code constant integer := 750;
  v_product_key constant text := 'count_observation_reversal:2026-10-20:750';
  v_lot_key constant text := 'count_observation_reversal_lot:2026-10-20:750:019';
  v_resolution_key constant text := 'count_observation_resolution:2026-10-20:750';
  v_session record;
  v_item record;
  v_case record;
  v_stock record;
  v_movement_id uuid;
  v_lot_id uuid;
  v_visible_lots jsonb;
begin
  select * into v_session
  from public.inventory_count_sessions
  where id = v_session_id;

  if v_session.id is null or v_session.status <> 'closed' or v_session.started_at::date <> date '2026-10-20' then
    raise exception 'No se encontro el conteo cerrado esperado del 2026-10-20';
  end if;

  select i.*, m.barcode, m.name as medicine_name into v_item
  from public.inventory_count_session_items i
  join public.medicines m on m.id = i.medicine_id
  where i.session_id = v_session_id and i.external_code = v_external_code;

  if v_item.id is null or v_item.expected_qty <> 27 or v_item.counted_qty <> 23 or v_item.variance_qty <> -4 then
    raise exception 'El conteo original de Izaban 25 ya no coincide con la evidencia auditada';
  end if;

  select * into v_case
  from public.inventory_variance_cases
  where count_item_id = v_item.id
  for update;

  if v_case.id is null or v_case.verified_qty <> 24 or v_case.confirmed_variance_qty <> -3 then
    raise exception 'El expediente verificado de Izaban 25 no coincide con la evidencia auditada';
  end if;

  select id into v_movement_id
  from public.inventory_movements
  where source_event_key = v_product_key;

  if v_movement_id is null then
    select * into v_stock
    from public.vw_product_stock_state
    where external_code = v_external_code;

    if v_stock.physical_qty <> 24 or v_stock.sellable_qty <> 24
       or v_stock.reserved_qty <> 0 or v_stock.expired_qty <> 0
       or v_stock.quarantine_qty <> 0 or v_stock.not_sellable_qty <> 0 then
      raise exception 'Precondicion de stock incumplida para producto 750: %', to_jsonb(v_stock);
    end if;

    if not exists (
      select 1 from public.inventory_movements
      where source_event_key = 'count_resolution:2026-10-20:750'
        and qty_delta = -4
    ) or not exists (
      select 1 from public.inventory_movements
      where source_event_key = 'count_recount:2026-10-20:750'
        and qty_delta = 1
    ) then
      raise exception 'No se encontraron los movimientos historicos exactos que originaron el saldo 24';
    end if;

    select coalesce(jsonb_object_agg(lot_no, physical_lot_qty order by lot_no), '{}'::jsonb)
      into v_visible_lots
    from public.vw_lot_stock_state
    where external_code = v_external_code and physical_lot_qty > 0;

    if v_visible_lots <> '{"019": 5, "17": 1, "27": 18}'::jsonb then
      raise exception 'La distribucion actual de lotes del producto 750 cambio: %', v_visible_lots;
    end if;

    select lot_id into v_lot_id
    from public.vw_lot_stock_state
    where external_code = v_external_code
      and lot_no = '019'
      and expires_at = date '2027-09-30'
      and physical_lot_qty = 5;

    if v_lot_id is null then
      raise exception 'No se encontro el lote 019 vigente de Izaban 25';
    end if;

    perform pg_advisory_xact_lock(93093, v_external_code);

    insert into public.inventory_movements(
      movement_type, source_type, source_id, source_item_id, source_event_key,
      medicine_id, external_code, barcode, qty_delta, unit_cost, note, created_by, metadata
    ) values (
      'count_observation_reversal_in', 'inventory_admin_correction', v_session_id, v_item.id,
      v_product_key, v_item.medicine_id, v_external_code, v_item.barcode, 3,
      coalesce(v_item.expected_unit_cost, 0),
      'Reversion del descuento prematuro: tres unidades de Izaban fueron encontradas fisicamente',
      v_session.started_by,
      jsonb_build_object(
        'resolution_reason', 'producto_encontrado_sin_perdida',
        'count_session_id', v_session_id,
        'count_item_id', v_item.id,
        'case_id', v_case.id,
        'found_qty', 3,
        'lot_no', '019',
        'expires_at', '2027-09-30',
        'historical_count_preserved', true,
        'applied_by_migration', '097_count_observation_no_stock.sql'
      )
    ) returning id into v_movement_id;

    insert into public.inventory_lot_movements(
      lot_id, inventory_movement_id, movement_type, source_type, source_id,
      source_item_id, source_event_key, medicine_id, external_code, barcode,
      qty_delta, created_by, metadata
    ) values (
      v_lot_id, v_movement_id, 'count_observation_reversal_lot_in',
      'inventory_admin_correction', v_session_id, v_item.id, v_lot_key,
      v_item.medicine_id, v_external_code, v_item.barcode, 3, v_session.started_by,
      jsonb_build_object(
        'reason', 'Tres unidades encontradas fisicamente despues del conteo',
        'lot_no', '019',
        'expires_at', '2027-09-30',
        'case_id', v_case.id
      )
    );

    insert into public.inventory_variance_resolutions(
      case_id, resolution_type, qty_resolved, amount_recovered, note,
      inventory_movement_id, idempotency_key, created_by, metadata
    ) values (
      v_case.id, 'found_recovered', 3, 0,
      'Las tres unidades faltantes fueron encontradas detras del mostrador; lote 019, vence 09/2027.',
      v_movement_id, v_resolution_key, v_session.started_by,
      jsonb_build_object(
        'exceptional_reversal_of_premature_count_adjustment', true,
        'lot_no', '019',
        'expires_at', '2027-09-30'
      )
    );

    insert into public.inventory_variance_case_events(
      case_id, event_type, qty, amount, reason_code, note,
      inventory_movement_id, idempotency_key, created_by, metadata
    ) values (
      v_case.id, 'resolution', 3, 0, 'found_recovered',
      'Producto encontrado; se revierte un ajuste prematuro sin alterar la evidencia del conteo.',
      v_movement_id, 'count_observation_resolution_event:2026-10-20:750',
      v_session.started_by,
      jsonb_build_object('lot_no', '019', 'expires_at', '2027-09-30')
    );

    update public.inventory_variance_cases
    set investigation_status = 'resolved',
        stock_adjustment_status = 'not_required',
        stock_adjustment_movement_id = null,
        stock_adjusted_by = null,
        stock_adjusted_at = null,
        resolved_by = v_session.started_by,
        resolved_at = now(),
        resolution_note = 'Tres unidades encontradas fisicamente; no existio perdida de inventario.',
        metadata = metadata || jsonb_build_object(
          'exceptional_correction', 'premature_count_adjustment_reversed',
          'found_qty', 3,
          'lot_no', '019',
          'expires_at', '2027-09-30',
          'historical_count_preserved', true
        )
    where id = v_case.id;

    insert into public.audit_log(event_type, user_id, metadata)
    values (
      'INVENTORY_COUNT_ITEM_APPLY', v_session.started_by,
      jsonb_build_object(
        'audit_action', 'reverse_premature_count_stock_effect',
        'external_code', v_external_code,
        'session_id', v_session_id,
        'item_id', v_item.id,
        'case_id', v_case.id,
        'qty_delta', 3,
        'lot_no', '019',
        'expires_at', '2027-09-30',
        'movement_id', v_movement_id,
        'source_event_key', v_product_key,
        'applied_by_migration', '097_count_observation_no_stock.sql'
      )
    );
  end if;

  select * into v_stock
  from public.vw_product_stock_state
  where external_code = v_external_code;

  if v_stock.physical_qty <> 27 or v_stock.sellable_qty <> 27
     or v_stock.reserved_qty <> 0 or v_stock.expired_qty <> 0
     or v_stock.quarantine_qty <> 0 or v_stock.not_sellable_qty <> 0 then
    raise exception 'Validacion final de stock fallo para producto 750: %', to_jsonb(v_stock);
  end if;

  select coalesce(jsonb_object_agg(lot_no, physical_lot_qty order by lot_no), '{}'::jsonb)
    into v_visible_lots
  from public.vw_lot_stock_state
  where external_code = v_external_code and physical_lot_qty > 0;

  if v_visible_lots <> '{"019": 8, "17": 1, "27": 18}'::jsonb then
    raise exception 'Validacion final de lotes fallo para producto 750: %', v_visible_lots;
  end if;

  if not exists (
    select 1 from public.inventory_variance_cases
    where id = v_case.id
      and investigation_status = 'resolved'
      and stock_adjustment_status = 'not_required'
      and confirmed_variance_qty = -3
  ) then
    raise exception 'El expediente de Izaban no quedo cerrado sin ajuste pendiente';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;

-- Validation after applying:
-- select external_code, physical_qty, sellable_qty, expired_qty, reserved_qty
-- from public.vw_product_stock_state where external_code = 750;
--
-- select lot_no, expires_at, physical_lot_qty, sellable_lot_qty
-- from public.vw_lot_stock_state where external_code = 750
-- order by expires_at, lot_no;
--
-- The count item remains the immutable observation (23). The variance case
-- documents the verified recount (24) and the later recovery of three units.
