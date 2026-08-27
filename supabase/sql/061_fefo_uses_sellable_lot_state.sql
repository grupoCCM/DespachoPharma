-- Harden FEFO lot extraction for dispatches.
-- Outgoing dispatch movements must consume only sellable lots. If there is not
-- enough sellable lot stock, fail the transaction instead of creating an
-- unassigned lot movement.

create or replace function public.inventory_apply_lot_fifo(p_inventory_movement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movement record;
  v_remaining numeric;
  v_take numeric;
  v_lot record;
  v_return record;
begin
  select *
    into v_movement
  from public.inventory_movements
  where id = p_inventory_movement_id;

  if v_movement.id is null or coalesce(v_movement.qty_delta, 0) = 0 then
    return;
  end if;

  if coalesce(v_movement.source_type, '') not in ('dispatch_validate', 'dispatch_void', 'dispatch_adjust') then
    return;
  end if;

  if exists (
    select 1
    from public.inventory_lot_movements
    where inventory_movement_id = v_movement.id
  ) then
    return;
  end if;

  if v_movement.qty_delta < 0 then
    v_remaining := abs(v_movement.qty_delta);

    for v_lot in
      select *
      from public.vw_lot_stock_state
      where external_code = v_movement.external_code
        and sellable_lot_qty > 0
        and is_sellable is true
      order by expires_at asc nulls last, lot_no asc nulls last, lot_sequence asc nulls last
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_lot.sellable_lot_qty);

      insert into public.inventory_lot_movements(
        lot_id, inventory_movement_id, movement_type, source_type, source_id,
        source_item_id, source_event_key, medicine_id, external_code, barcode,
        qty_delta, created_by, metadata
      )
      values (
        v_lot.lot_id,
        v_movement.id,
        v_movement.movement_type,
        v_movement.source_type,
        v_movement.source_id,
        v_movement.source_item_id,
        'lot_fefo:' || v_movement.id::text || ':' || v_lot.lot_id::text,
        v_movement.medicine_id,
        v_movement.external_code,
        v_movement.barcode,
        -1 * v_take,
        v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object(
          'fefo', true,
          'lot_no', v_lot.lot_no,
          'expires_at', v_lot.expires_at,
          'sellable_lot_qty_before', v_lot.sellable_lot_qty
        )
      )
      on conflict (source_event_key) where source_event_key is not null do nothing;

      v_remaining := v_remaining - v_take;
    end loop;

    if v_remaining > 0 then
      raise exception 'No hay lotes vendibles suficientes para despachar producto %. Faltante por lote: %.',
        v_movement.external_code,
        v_remaining;
    end if;
  else
    v_remaining := v_movement.qty_delta;

    for v_return in
      select
        lm.lot_id,
        min(lm.created_at) as first_out_at,
        -1 * sum(lm.qty_delta) as qty_out
      from public.inventory_lot_movements lm
      where lm.source_item_id = v_movement.source_item_id
      group by lm.lot_id
      having -1 * sum(lm.qty_delta) > 0
      order by first_out_at desc nulls last
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_return.qty_out);

      insert into public.inventory_lot_movements(
        lot_id, inventory_movement_id, movement_type, source_type, source_id,
        source_item_id, source_event_key, medicine_id, external_code, barcode,
        qty_delta, created_by, metadata
      )
      values (
        v_return.lot_id,
        v_movement.id,
        v_movement.movement_type,
        v_movement.source_type,
        v_movement.source_id,
        v_movement.source_item_id,
        'lot_return:' || v_movement.id::text || ':' || coalesce(v_return.lot_id::text, 'unassigned'),
        v_movement.medicine_id,
        v_movement.external_code,
        v_movement.barcode,
        v_take,
        v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object('fifo_return', true)
      )
      on conflict (source_event_key) where source_event_key is not null do nothing;

      v_remaining := v_remaining - v_take;
    end loop;
  end if;
end;
$$;

grant execute on function public.inventory_apply_lot_fifo(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
