-- Reconcile ERP expiry movement 346, recorded against the wrong product.
--
-- Documentary evidence:
-- - Product 730 bought 3 units and sold all 3 before movement 346. The ERP
--   movement then removed 2 units and produced an impossible balance of -2.
-- - Product 737 bought 3 units, sold 1 and retained the matching 2 expired
--   units from lot F33082.
-- - The physical count found zero units for both products.
--
-- The application already has product 730 at zero. This migration therefore
-- leaves 730 untouched and removes the two expired physical units from 737.
-- Historical imports and the closed count session remain immutable.

begin;

do $$
declare
  v_session_id constant uuid := '3d392c92-4b0d-4e17-911d-8c60ae1c7018'::uuid;
  v_external_code constant integer := 737;
  v_product_event_key constant text := 'count_crossed_expiry:2026-10-20:737';
  v_lot_event_key constant text := 'count_crossed_expiry_lot:2026-10-20:737:F33082';
  v_session record;
  v_item_730 record;
  v_item_737 record;
  v_stock_730 record;
  v_stock_737 record;
  v_lot record;
  v_product_movement_id uuid;
begin
  select *
    into v_session
  from public.inventory_count_sessions
  where id = v_session_id;

  if v_session.id is null
     or v_session.status <> 'closed'
     or v_session.started_at::date <> date '2026-10-20' then
    raise exception 'No se encontro el conteo cerrado esperado del 2026-10-20';
  end if;

  select i.*, m.barcode, m.name as medicine_name
    into v_item_730
  from public.inventory_count_session_items i
  join public.medicines m on m.id = i.medicine_id
  where i.session_id = v_session_id
    and i.external_code = 730;

  select i.*, m.barcode, m.name as medicine_name
    into v_item_737
  from public.inventory_count_session_items i
  join public.medicines m on m.id = i.medicine_id
  where i.session_id = v_session_id
    and i.external_code = 737;

  if v_item_730.id is null
     or v_item_730.expected_qty <> -2
     or v_item_730.counted_qty <> 0
     or v_item_730.variance_qty <> 2
     or v_item_730.status <> 'counted' then
    raise exception 'El conteo original del producto 730 no coincide con la evidencia auditada';
  end if;

  if v_item_737.id is null
     or v_item_737.expected_qty <> 2
     or v_item_737.counted_qty <> 0
     or v_item_737.variance_qty <> -2
     or v_item_737.status <> 'counted' then
    raise exception 'El conteo original del producto 737 no coincide con la evidencia auditada';
  end if;

  select id
    into v_product_movement_id
  from public.inventory_movements
  where source_event_key = v_product_event_key;

  if v_product_movement_id is null then
    select *
      into v_stock_730
    from public.vw_product_stock_state
    where external_code = 730;

    select *
      into v_stock_737
    from public.vw_product_stock_state
    where external_code = 737;

    if v_stock_730.physical_qty <> 0
       or v_stock_730.sellable_qty <> 0 then
      raise exception 'El producto 730 ya no esta en cero: %', to_jsonb(v_stock_730);
    end if;

    if v_stock_737.physical_qty <> 2
       or v_stock_737.expired_qty <> 2
       or v_stock_737.sellable_qty <> 0
       or v_stock_737.reserved_qty <> 0
       or v_stock_737.quarantine_qty <> 0
       or v_stock_737.not_sellable_qty <> 0 then
      raise exception 'Precondicion de stock incumplida para producto 737: %', to_jsonb(v_stock_737);
    end if;

    select *
      into v_lot
    from public.vw_lot_stock_state
    where external_code = 737
      and lot_no = 'F33082'
      and expires_at = date '2026-07-31';

    if v_lot.lot_id is null
       or v_lot.physical_lot_qty <> 2
       or v_lot.expired_lot_qty <> 2
       or v_lot.sellable_lot_qty <> 0 then
      raise exception 'El lote F33082 no coincide con la evidencia auditada: %', to_jsonb(v_lot);
    end if;

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
      created_by,
      metadata
    ) values (
      'manual_count_adjust_out',
      'count_session',
      v_session_id,
      v_item_737.id,
      v_product_event_key,
      v_item_737.medicine_id,
      v_external_code,
      v_item_737.barcode,
      -2,
      coalesce(v_item_737.expected_unit_cost, 0),
      'Correccion trazable de movimiento ERP 346 cruzado entre productos 730 y 737',
      v_session.started_by,
      jsonb_build_object(
        'resolution_reason', 'movimiento_de_vencimiento_asignado_a_producto_incorrecto',
        'erp_movement_no', 346,
        'incorrect_erp_external_code', 730,
        'correct_external_code', 737,
        'correct_lot_no', 'F33082',
        'correct_expires_at', '2026-07-31',
        'qty', 2,
        'count_session_id', v_session_id,
        'count_item_id', v_item_737.id,
        'evidence', 'Kardex 730 termina en -2 por salida 346; Kardex 737 conserva las mismas 2 unidades; conteo fisico confirma cero en ambos.'
      )
    )
    returning id into v_product_movement_id;

    insert into public.inventory_lot_movements(
      lot_id,
      inventory_movement_id,
      movement_type,
      source_type,
      source_id,
      source_item_id,
      source_event_key,
      medicine_id,
      external_code,
      barcode,
      qty_delta,
      created_by,
      metadata
    ) values (
      v_lot.lot_id,
      v_product_movement_id,
      'lot_count_adjust_out',
      'inventory_admin_correction',
      v_session_id,
      v_item_737.id,
      v_lot_event_key,
      v_item_737.medicine_id,
      v_external_code,
      v_item_737.barcode,
      -2,
      v_session.started_by,
      jsonb_build_object(
        'reason', 'Correccion de salida ERP 346 registrada en producto 730 en lugar de 737',
        'lot_no', 'F33082',
        'expires_at', '2026-07-31'
      )
    );

    insert into public.audit_log(event_type, user_id, metadata)
    values (
      'INVENTORY_COUNT_ITEM_APPLY',
      v_session.started_by,
      jsonb_build_object(
        'source_event_key', v_product_event_key,
        'audit_action', 'crossed_expiry_movement_correction',
        'session_id', v_session_id,
        'item_id', v_item_737.id,
        'external_code', v_external_code,
        'product_movement_id', v_product_movement_id,
        'erp_movement_no', 346,
        'incorrect_erp_external_code', 730,
        'qty_delta', -2,
        'applied_by_migration', '092_reconcile_crossed_expiry_730_737.sql'
      )
    );
  end if;

  select *
    into v_stock_730
  from public.vw_product_stock_state
  where external_code = 730;

  select *
    into v_stock_737
  from public.vw_product_stock_state
  where external_code = 737;

  if v_stock_730.physical_qty <> 0
     or v_stock_730.sellable_qty <> 0 then
    raise exception 'Validacion final fallo para producto 730: %', to_jsonb(v_stock_730);
  end if;

  if v_stock_737.physical_qty <> 0
     or v_stock_737.expired_qty <> 0
     or v_stock_737.sellable_qty <> 0 then
    raise exception 'Validacion final fallo para producto 737: %', to_jsonb(v_stock_737);
  end if;

  if exists (
    select 1
    from public.vw_lot_stock_state
    where external_code = 737
      and physical_lot_qty <> 0
  ) then
    raise exception 'Quedaron unidades fisicas por lote para producto 737';
  end if;

  if not exists (
    select 1
    from public.inventory_count_session_items
    where id = v_item_730.id
      and expected_qty = -2
      and counted_qty = 0
      and variance_qty = 2
      and status = 'counted'
  ) or not exists (
    select 1
    from public.inventory_count_session_items
    where id = v_item_737.id
      and expected_qty = 2
      and counted_qty = 0
      and variance_qty = -2
      and status = 'counted'
  ) then
    raise exception 'El conteo historico fue alterado durante la correccion';
  end if;
end;
$$;

commit;

-- Validation after applying:
-- select external_code, physical_qty, expired_qty, sellable_qty
-- from public.vw_product_stock_state where external_code in (730, 737);
--
-- select lot_no, expires_at, physical_lot_qty, expired_lot_qty, sellable_lot_qty
-- from public.vw_lot_stock_state where external_code = 737;
--
-- Logical rollback must use opposite append-only product and lot movements.
-- Never delete this correction or rewrite movement 346 in historical sources.
