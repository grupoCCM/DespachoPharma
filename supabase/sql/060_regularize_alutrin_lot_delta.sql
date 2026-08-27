-- Regularize historical product-level stock without lot detail for product 797.
-- This is intentionally lot-only: product-level inventory already has the
-- correct quantity. The movement closes the pre-FEFO gap between product
-- sellable stock and lot sellable stock.

do $$
declare
  v_external_code integer := 797;
  v_delta numeric(14,4);
  v_lot record;
begin
  with lot_sum as (
    select
      external_code,
      sum(sellable_lot_qty)::numeric(14,4) as sellable_lot_qty
    from public.vw_lot_stock_state
    where external_code = v_external_code
    group by external_code
  )
  select
    (p.sellable_qty - coalesce(l.sellable_lot_qty, 0))::numeric(14,4)
    into v_delta
  from public.vw_product_stock_state p
  left join lot_sum l on l.external_code = p.external_code
  where p.external_code = v_external_code;

  if coalesce(v_delta, 0) <= 0 then
    return;
  end if;

  select
    ls.lot_id,
    ls.medicine_id,
    ls.external_code,
    ls.barcode,
    ls.lot_no,
    ls.expires_at
    into v_lot
  from public.vw_lot_stock_state ls
  where ls.external_code = v_external_code
    and ls.is_sellable is true
  order by ls.expires_at asc nulls last, ls.lot_sequence asc nulls last, ls.lot_no asc nulls last
  limit 1;

  if v_lot.lot_id is null then
    raise exception 'No existe lote vendible para regularizar producto %', v_external_code;
  end if;

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
  )
  values (
    v_lot.lot_id,
    null,
    'lot_regularization_in',
    'inventory_admin_correction',
    null,
    null,
    'lot_regularization:product_797:pre_fefo_delta',
    v_lot.medicine_id,
    v_lot.external_code,
    v_lot.barcode,
    v_delta,
    null,
    jsonb_build_object(
      'reason', 'Regularizacion tecnica Fase 1: sincronizacion de huerfanos pre-FEFO',
      'external_code', v_external_code,
      'delta_qty', v_delta,
      'lot_no', v_lot.lot_no,
      'expires_at', v_lot.expires_at
    )
  )
  on conflict (source_event_key) where source_event_key is not null do nothing;
end $$;

notify pgrst, 'reload schema';
