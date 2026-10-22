-- Expected result: every query returns zero rows.

-- Product availability must match the 27 physical units now confirmed.
select external_code, physical_qty, sellable_qty, expired_qty, reserved_qty,
       quarantine_qty, not_sellable_qty
from public.vw_product_stock_state
where external_code = 750
  and (
    physical_qty <> 27
    or sellable_qty <> 27
    or expired_qty <> 0
    or reserved_qty <> 0
    or quarantine_qty <> 0
    or not_sellable_qty <> 0
  );

-- Current lot allocation must be 1 + 8 + 18 = 27.
with expected(lot_no, expires_at, qty) as (
  values
    ('17'::text, date '2027-07-31', 1::numeric),
    ('019'::text, date '2027-09-30', 8::numeric),
    ('27'::text, date '2028-02-28', 18::numeric)
), actual as (
  select lot_no, expires_at, physical_lot_qty as qty
  from public.vw_lot_stock_state
  where external_code = 750 and physical_lot_qty > 0
)
select * from (
  (select * from expected except select * from actual)
  union all
  (select * from actual except select * from expected)
) differences;

-- The original observation remains immutable evidence.
select id, expected_qty, counted_qty, variance_qty, status, applied_at
from public.inventory_count_session_items
where session_id = '3d392c92-4b0d-4e17-911d-8c60ae1c7018'::uuid
  and external_code = 750
  and not (
    expected_qty = 27
    and counted_qty = 23
    and variance_qty = -4
    and status = 'counted'
    and applied_at is null
  );

-- The verified case is closed without a pending stock adjustment.
select c.id, c.verified_qty, c.confirmed_variance_qty,
       c.stock_adjustment_status, c.investigation_status
from public.inventory_variance_cases c
join public.inventory_count_session_items i on i.id = c.count_item_id
where i.session_id = '3d392c92-4b0d-4e17-911d-8c60ae1c7018'::uuid
  and i.external_code = 750
  and not (
    c.verified_qty = 24
    and c.confirmed_variance_qty = -3
    and c.stock_adjustment_status = 'not_required'
    and c.investigation_status = 'resolved'
  );

-- The exceptional correction must be complete at product, lot and case level.
select required_key
from (values
  ('count_observation_reversal:2026-10-20:750'::text),
  ('count_observation_reversal_lot:2026-10-20:750:019'::text),
  ('count_observation_resolution:2026-10-20:750'::text)
) required(required_key)
where not exists (
  select 1 from public.inventory_movements im
  where im.source_event_key = required.required_key
  union all
  select 1 from public.inventory_lot_movements ilm
  where ilm.source_event_key = required.required_key
  union all
  select 1 from public.inventory_variance_resolutions r
  where r.idempotency_key = required.required_key
);
