-- Fix FEFO allocation inside the inventory_movements trigger.
-- The trigger runs after the product-level movement is inserted. If FEFO reads
-- vw_product_stock_state directly at that moment, the current outgoing movement
-- has already reduced sellable_qty and products with exact stock can look empty.
-- This function reconstructs the lot state immediately before the movement being
-- processed, then writes the lot-level FEFO movements.

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
  v_product_physical_before numeric;
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

    select greatest(coalesce(live.stock_qty, 0) - coalesce(v_movement.qty_delta, 0), 0)
      into v_product_physical_before
    from public.vw_inventory_live live
    where live.external_code = v_movement.external_code;

    v_product_physical_before := coalesce(v_product_physical_before, 0);

    for v_lot in
      with lot_base as (
        select
          vl.lot_id,
          vl.medicine_id,
          vl.external_code,
          vl.barcode,
          vl.lot_no,
          vl.lot_sequence,
          vl.expires_at,
          greatest(coalesce(vl.lot_qty, 0), 0)::numeric(14,4) as raw_lot_qty,
          coalesce(
            sum(greatest(coalesce(vl.lot_qty, 0), 0)) over (
              partition by vl.external_code
              order by vl.lot_sequence desc nulls last,
                       vl.expires_at desc nulls last,
                       vl.lot_no desc nulls last,
                       vl.lot_id desc
              rows between unbounded preceding and 1 preceding
            ),
            0
          )::numeric(14,4) as newer_lot_qty
        from public.vw_inventory_lot_live vl
        left join public.medicines m on m.id = vl.medicine_id
        where vl.external_code = v_movement.external_code
          and coalesce(m.active, true) = true
          and greatest(coalesce(vl.lot_qty, 0), 0) > 0
      ),
      lot_state_before as (
        select
          *,
          greatest(
            0,
            least(raw_lot_qty, v_product_physical_before - newer_lot_qty)
          )::numeric(14,4) as sellable_lot_qty_before
        from lot_base
      )
      select *
      from lot_state_before
      where sellable_lot_qty_before > 0
        and (expires_at is null or expires_at > current_date)
      order by expires_at asc nulls last, lot_no asc nulls last, lot_sequence asc nulls last
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_lot.sellable_lot_qty_before);

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
          'sellable_lot_qty_before', v_lot.sellable_lot_qty_before,
          'product_physical_qty_before', v_product_physical_before
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
