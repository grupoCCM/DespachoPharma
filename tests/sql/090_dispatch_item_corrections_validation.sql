-- Read-only checks for 090_dispatch_item_corrections.sql.

-- Must return zero rows.
select id, dispatch_id, qty, original_qty, line_status
from public.dispatch_items
where original_qty < qty
   or (line_status = 'active' and qty <= 0)
   or (line_status = 'removed' and qty <> 0);

-- Confirmed reservation-v1 lines must match their active reservations.
-- Must return zero rows.
select
  di.id as dispatch_item_id,
  di.qty as effective_qty,
  coalesce(sum(r.qty) filter (where r.status = 'active'), 0) as active_reserved_qty
from public.dispatch_header dh
join public.dispatch_items di on di.dispatch_id = dh.id
left join public.inventory_reservations r on r.dispatch_item_id = di.id
where dh.status = 'confirmed'
  and dh.stock_reservation_version >= 1
  and di.line_status = 'active'
group by di.id, di.qty
having di.qty <> coalesce(sum(r.qty) filter (where r.status = 'active'), 0);

-- Every validated correction movement must have the same quantity at lot level.
-- Must return zero rows.
select
  a.id as adjustment_id,
  a.qty_delta,
  coalesce(sum(lm.qty_delta), 0) as lot_qty_delta
from public.dispatch_item_adjustments a
join public.inventory_movements im on im.id = a.inventory_movement_id
left join public.inventory_lot_movements lm on lm.inventory_movement_id = im.id
where a.dispatch_status = 'validated'
group by a.id, a.qty_delta
having a.qty_delta <> coalesce(sum(lm.qty_delta), 0);

-- Delivery 633 remains unchanged until its correction is explicitly confirmed.
select
  dh.delivery_no,
  dh.status,
  di.product_name_snapshot,
  di.original_qty,
  di.qty as effective_qty,
  di.line_status,
  di.correction_reason
from public.dispatch_header dh
join public.dispatch_items di on di.dispatch_id = dh.id
where dh.delivery_no = 633
order by di.product_name_snapshot;
