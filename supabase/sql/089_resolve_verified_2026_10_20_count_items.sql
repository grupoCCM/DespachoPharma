-- Resolve only the inventory differences proven by the 2026-10-20 audit.
--
-- This migration preserves the original purchase, dispatch and count history.
-- It adds traceable count-resolution movements and does not touch the three
-- cases that still require documentary confirmation: 720, 730 and 737.
--
-- Expected result:
-- - 46 shortage units resolved across seven products.
-- - The original count rows and findings remain unchanged as evidence.
-- - Products 720, 730 and 737 remain open for later investigation.

begin;

do $$
declare
  v_session_id constant uuid := '3d392c92-4b0d-4e17-911d-8c60ae1c7018'::uuid;
  v_session record;
  v_target record;
  v_item record;
  v_movement_id uuid;
  v_live_before numeric;
  v_live_after numeric;
  v_source_event_key text;
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

  for v_target in
    select *
    from (values
      (745,  4::numeric,  3::numeric, -1::numeric, 'faltante_fisico_confirmado', 'ERP y aplicacion conciliaban 4 unidades; conteo fisico encontro 3.'),
      (750, 27::numeric, 23::numeric, -4::numeric, 'faltante_fisico_confirmado', 'ERP y aplicacion conciliaban 27 unidades; conteo fisico encontro 23.'),
      (765, 22::numeric,  7::numeric, -15::numeric, 'compra_historica_duplicada', 'CF-1797 ya estaba incluida en la existencia base del 17/07/2026 y fue importada nuevamente desde Compras por Articulo (17).xlsx.'),
      (766, 23::numeric,  8::numeric, -15::numeric, 'compra_historica_duplicada', 'CF-1797 ya estaba incluida en la existencia base del 17/07/2026 y fue importada nuevamente desde Compras por Articulo (17).xlsx.'),
      (771,  2::numeric,  1::numeric, -1::numeric, 'faltante_fisico_confirmado', 'ERP y aplicacion conciliaban 2 unidades; conteo fisico encontro 1.'),
      (789,  6::numeric,  1::numeric, -5::numeric, 'compra_historica_duplicada', 'CF-23050 ya estaba incluida en la existencia base del 17/07/2026 y fue importada nuevamente desde Compras por Articulo (17).xlsx.'),
      (790,  7::numeric,  2::numeric, -5::numeric, 'compra_historica_duplicada', 'CF-23050 ya estaba incluida en la existencia base del 17/07/2026 y fue importada nuevamente desde Compras por Articulo (17).xlsx.')
    ) as t(external_code, expected_qty, counted_qty, adjustment_qty, reason_code, evidence)
  loop
    select
      i.*,
      m.barcode,
      m.name as medicine_name
      into v_item
    from public.inventory_count_session_items i
    join public.medicines m on m.id = i.medicine_id
    where i.session_id = v_session_id
      and i.external_code = v_target.external_code;

    if v_item.id is null
       or v_item.expected_qty <> v_target.expected_qty
       or v_item.counted_qty <> v_target.counted_qty
       or v_item.variance_qty <> v_target.adjustment_qty then
      raise exception 'El conteo del producto % ya no coincide con la evidencia auditada', v_target.external_code;
    end if;

    v_source_event_key := 'count_resolution:2026-10-20:' || v_target.external_code::text;

    select id
      into v_movement_id
    from public.inventory_movements
    where source_event_key = v_source_event_key;

    if v_movement_id is null then
      select stock_qty
        into v_live_before
      from public.vw_inventory_live
      where external_code = v_target.external_code;

      v_live_before := coalesce(v_live_before, 0);

      if v_live_before + v_target.adjustment_qty < 0 then
        raise exception 'La correccion dejaria inventario negativo para producto %', v_target.external_code;
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
        v_item.id,
        v_source_event_key,
        v_item.medicine_id,
        v_item.external_code,
        v_item.barcode,
        v_target.adjustment_qty,
        coalesce(v_item.expected_unit_cost, 0),
        'Resolucion trazable del conteo fisico del 20/10/2026',
        v_session.started_by,
        jsonb_build_object(
          'resolution_reason', v_target.reason_code,
          'evidence', v_target.evidence,
          'count_session_id', v_session_id,
          'count_item_id', v_item.id,
          'expected_qty', v_item.expected_qty,
          'counted_qty', v_item.counted_qty,
          'variance_qty', v_item.variance_qty,
          'live_qty_before', v_live_before,
          'audit_date', '2026-10-20'
        )
      )
      returning id into v_movement_id;

      select stock_qty
        into v_live_after
      from public.vw_inventory_live
      where external_code = v_target.external_code;

      if v_live_after <> v_live_before + v_target.adjustment_qty then
        raise exception 'La existencia del producto % no cambio como se esperaba', v_target.external_code;
      end if;
    end if;

    insert into public.audit_log(event_type, user_id, metadata)
    select
      'INVENTORY_COUNT_ITEM_APPLY',
      v_session.started_by,
      jsonb_build_object(
        'source_event_key', v_source_event_key,
        'item_id', v_item.id,
        'session_id', v_session_id,
        'external_code', v_target.external_code,
        'variance_qty', v_target.adjustment_qty,
        'movement_id', v_movement_id,
        'resolution_reason', v_target.reason_code,
        'evidence', v_target.evidence,
        'applied_by_migration', '089_resolve_verified_2026_10_20_count_items.sql'
      )
    where not exists (
      select 1
      from public.audit_log al
      where al.event_type = 'INVENTORY_COUNT_ITEM_APPLY'
        and al.metadata ->> 'source_event_key' = v_source_event_key
    );
  end loop;

  if exists (
    select 1
    from public.inventory_movements
    where source_event_key in (
      'count_resolution:2026-10-20:720',
      'count_resolution:2026-10-20:730',
      'count_resolution:2026-10-20:737'
    )
  ) then
    raise exception 'Los casos pendientes 720, 730 o 737 no deben modificarse en esta migracion';
  end if;
end;
$$;

commit;

-- Validation after applying:
-- select external_code, movement_type, qty_delta, source_event_key, metadata
-- from public.inventory_movements
-- where source_event_key like 'count_resolution:2026-10-20:%'
-- order by external_code;
--
-- The migration intentionally does not update inventory_count_session_items.
-- The PDF and database count remain the immutable observation captured that day.
--
-- Logical rollback, only if validation fails: insert opposite movements using
-- source_event_key 'count_resolution_rollback:2026-10-20:<external_code>'.
-- Never delete the correction movements or the original imported purchases.
