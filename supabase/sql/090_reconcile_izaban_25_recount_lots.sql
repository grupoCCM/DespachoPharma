-- Reconcile the verified physical recount for Izaban 25 mg (external code 750).
--
-- The closed count session remains immutable: it captured 23 units. A supervised
-- recount confirmed 24 units split across three sellable lots:
--   lot 17  / 2027-07-31 /  1 unit
--   lot 019 / 2027-09-30 /  5 units
--   lot 27  / 2028-02-28 / 18 units
--
-- This migration adds one product-level unit and corrects the current lot
-- allocation without deleting or rewriting any historical movement.

begin;

do $$
declare
  v_session_id constant uuid := '3d392c92-4b0d-4e17-911d-8c60ae1c7018'::uuid;
  v_external_code constant integer := 750;
  v_product_event_key constant text := 'count_recount:2026-10-20:750';
  v_session record;
  v_item record;
  v_stock record;
  v_snapshot_item record;
  v_product_movement_id uuid;
  v_lot_17_id uuid;
  v_lot_019_id uuid;
  v_lot_27_id uuid;
  v_visible_lots jsonb;
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
    into v_item
  from public.inventory_count_session_items i
  join public.medicines m on m.id = i.medicine_id
  where i.session_id = v_session_id
    and i.external_code = v_external_code;

  if v_item.id is null
     or v_item.expected_qty <> 27
     or v_item.counted_qty <> 23
     or v_item.variance_qty <> -4
     or v_item.status <> 'counted'
     or v_item.applied_at is not null then
    raise exception 'El conteo original de Izaban 25 ya no coincide con la evidencia auditada';
  end if;

  select id
    into v_product_movement_id
  from public.inventory_movements
  where source_event_key = v_product_event_key;

  if v_product_movement_id is null then
    select *
      into v_stock
    from public.vw_product_stock_state
    where external_code = v_external_code;

    if v_stock.physical_qty <> 23
       or v_stock.sellable_qty <> 23
       or v_stock.reserved_qty <> 0
       or v_stock.expired_qty <> 0
       or v_stock.quarantine_qty <> 0
       or v_stock.not_sellable_qty <> 0 then
      raise exception 'Precondicion de stock incumplida para producto 750: %', to_jsonb(v_stock);
    end if;

    select coalesce(
      jsonb_object_agg(lot_no, physical_lot_qty order by lot_no),
      '{}'::jsonb
    )
      into v_visible_lots
    from public.vw_lot_stock_state
    where external_code = v_external_code
      and physical_lot_qty > 0;

    if v_visible_lots <> '{"019": 10.0000, "10": 3.0000, "27": 10.0000}'::jsonb then
      raise exception 'La distribucion actual de lotes del producto 750 cambio: %', v_visible_lots;
    end if;

    select inventory_snapshot_item_id, snapshot_created_at
      into v_snapshot_item
    from public.vw_inventory_lot_live
    where external_code = v_external_code
    order by snapshot_created_at desc
    limit 1;

    if v_snapshot_item.inventory_snapshot_item_id is null then
      raise exception 'No existe item de snapshot vigente para producto 750';
    end if;

    select id into v_lot_019_id
    from public.inventory_lots
    where inventory_snapshot_item_id = v_snapshot_item.inventory_snapshot_item_id
      and lot_no = '019'
      and expires_at = date '2027-09-30';

    select id into v_lot_27_id
    from public.inventory_lots
    where inventory_snapshot_item_id = v_snapshot_item.inventory_snapshot_item_id
      and lot_no = '27'
      and expires_at = date '2028-02-28';

    if v_lot_019_id is null or v_lot_27_id is null then
      raise exception 'No se encontraron los lotes 019 y 27 esperados para producto 750';
    end if;

    select id into v_lot_17_id
    from public.inventory_lots
    where inventory_snapshot_item_id = v_snapshot_item.inventory_snapshot_item_id
      and lot_no = '17';

    if v_lot_17_id is not null then
      raise exception 'Ya existe un lote 17 no auditado para producto 750';
    end if;

    insert into public.inventory_lots(
      inventory_snapshot_item_id,
      medicine_id,
      lot_no,
      expires_at,
      qty,
      source_detail,
      lot_sequence
    ) values (
      v_snapshot_item.inventory_snapshot_item_id,
      v_item.medicine_id,
      '17',
      date '2027-07-31',
      0,
      'Reconteo fisico auditado 21/10/2026: lote omitido en historial importado',
      (
        select coalesce(max(lot_sequence), 0) + 1
        from public.inventory_lots
        where inventory_snapshot_item_id = v_snapshot_item.inventory_snapshot_item_id
      )
    )
    returning id into v_lot_17_id;

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
      'manual_count_recount_in',
      'count_session',
      v_session_id,
      v_item.id,
      v_product_event_key,
      v_item.medicine_id,
      v_external_code,
      v_item.barcode,
      1,
      coalesce(v_item.expected_unit_cost, 0),
      'Correccion trazable por reconteo fisico de Izaban 25',
      v_session.started_by,
      jsonb_build_object(
        'resolution_reason', 'reconteo_fisico_y_reconstruccion_de_lotes',
        'original_counted_qty', 23,
        'verified_recount_qty', 24,
        'erp_qty', 27,
        'remaining_physical_shortage', 3,
        'count_session_id', v_session_id,
        'count_item_id', v_item.id,
        'lot_evidence', jsonb_build_array(
          jsonb_build_object('lot_no', '17', 'expires_at', '2027-07-31', 'qty', 1),
          jsonb_build_object('lot_no', '019', 'expires_at', '2027-09-30', 'qty', 5),
          jsonb_build_object('lot_no', '27', 'expires_at', '2028-02-28', 'qty', 18)
        )
      )
    )
    returning id into v_product_movement_id;

    insert into public.inventory_lot_movements(
      lot_id, inventory_movement_id, movement_type, source_type, source_id,
      source_item_id, source_event_key, medicine_id, external_code, barcode,
      qty_delta, created_by, metadata
    ) values
    (
      v_lot_17_id, null, 'lot_recount_adjust_in', 'inventory_admin_correction',
      v_session_id, v_item.id, 'count_recount_lot:2026-10-20:750:17',
      v_item.medicine_id, v_external_code, v_item.barcode, 1, v_session.started_by,
      jsonb_build_object('reason', 'Lote confirmado en reconteo fisico', 'expires_at', '2027-07-31')
    ),
    (
      v_lot_019_id, null, 'lot_recount_adjust_out', 'inventory_admin_correction',
      v_session_id, v_item.id, 'count_recount_lot:2026-10-20:750:019',
      v_item.medicine_id, v_external_code, v_item.barcode, -5, v_session.started_by,
      jsonb_build_object('reason', 'Saldo de lote confirmado por reconteo fisico', 'expires_at', '2027-09-30')
    ),
    (
      v_lot_27_id, null, 'lot_recount_adjust_in', 'inventory_admin_correction',
      v_session_id, v_item.id, 'count_recount_lot:2026-10-20:750:27',
      v_item.medicine_id, v_external_code, v_item.barcode, 8, v_session.started_by,
      jsonb_build_object('reason', 'Saldo de lote confirmado por reconteo fisico', 'expires_at', '2028-02-28')
    );

    insert into public.audit_log(event_type, user_id, metadata)
    values (
      'INVENTORY_COUNT_ITEM_APPLY',
      v_session.started_by,
      jsonb_build_object(
        'source_event_key', v_product_event_key,
        'audit_action', 'verified_recount_correction',
        'session_id', v_session_id,
        'item_id', v_item.id,
        'external_code', v_external_code,
        'product_movement_id', v_product_movement_id,
        'original_counted_qty', 23,
        'verified_recount_qty', 24,
        'remaining_physical_shortage', 3,
        'lot_17_qty', 1,
        'lot_019_qty', 5,
        'lot_27_qty', 18,
        'applied_by_migration', '090_reconcile_izaban_25_recount_lots.sql'
      )
    );
  end if;

  select *
    into v_stock
  from public.vw_product_stock_state
  where external_code = v_external_code;

  if v_stock.physical_qty <> 24
     or v_stock.sellable_qty <> 24
     or v_stock.reserved_qty <> 0
     or v_stock.expired_qty <> 0
     or v_stock.quarantine_qty <> 0
     or v_stock.not_sellable_qty <> 0 then
    raise exception 'Validacion final de stock fallo para producto 750: %', to_jsonb(v_stock);
  end if;

  select coalesce(
    jsonb_object_agg(lot_no, physical_lot_qty order by lot_no),
    '{}'::jsonb
  )
    into v_visible_lots
  from public.vw_lot_stock_state
  where external_code = v_external_code
    and physical_lot_qty > 0;

  if v_visible_lots <> '{"019": 5.0000, "17": 1.0000, "27": 18.0000}'::jsonb then
    raise exception 'Validacion final de lotes fallo para producto 750: %', v_visible_lots;
  end if;

  if (
    select coalesce(sum(physical_lot_qty), 0)
    from public.vw_lot_stock_state
    where external_code = v_external_code
  ) <> 24 then
    raise exception 'La suma final de lotes no es 24 para producto 750';
  end if;

  if not exists (
    select 1
    from public.inventory_count_session_items
    where id = v_item.id
      and expected_qty = 27
      and counted_qty = 23
      and variance_qty = -4
      and status = 'counted'
      and applied_at is null
  ) then
    raise exception 'El conteo historico fue alterado durante la correccion';
  end if;
end;
$$;

commit;

-- Validation after applying:
-- select external_code, physical_qty, sellable_qty, expired_qty, reserved_qty
-- from public.vw_product_stock_state where external_code = 750;
--
-- select lot_no, expires_at, physical_lot_qty, sellable_lot_qty
-- from public.vw_lot_stock_state where external_code = 750
-- order by expires_at, lot_no;
--
-- Logical rollback must use opposite append-only movements. Never delete the
-- recount correction, its lot movements, or the original count evidence.
