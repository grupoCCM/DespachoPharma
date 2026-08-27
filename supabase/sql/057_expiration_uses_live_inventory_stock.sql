-- Expiration dashboard must use current operational stock, not only the latest
-- inventory snapshot. Supplier returns, dispatches and corrections are already
-- reflected in vw_inventory_live / inventory_lot_movements.

create or replace view public.vw_expiration_risk_latest as
with latest_snapshot as (
  select id, snapshot_date, source_file, created_at
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
),
live_lots as (
  select
    s.snapshot_date,
    s.source_file,
    vl.external_code,
    vl.medicine_id,
    vl.barcode,
    vl.medicine_name,
    vl.model,
    vl.secondary_name,
    vl.presentation,
    greatest(coalesce(vi.stock_qty, 0), 0)::numeric(14,4) as stock_qty,
    coalesce(vi.unit_cost, vl.unit_cost, 0)::numeric(14,6) as unit_cost,
    vl.lot_no,
    vl.lot_sequence,
    vl.expires_at,
    vl.original_lot_qty,
    greatest(coalesce(vl.lot_qty, 0), 0)::numeric(14,4) as adjusted_lot_qty,
    coalesce(
      sum(greatest(coalesce(vl.lot_qty, 0), 0)) over (
        partition by vl.external_code
        order by vl.lot_sequence desc nulls last, vl.expires_at desc nulls last, vl.lot_no desc nulls last, vl.lot_id desc
        rows between unbounded preceding and 1 preceding
      ),
      0
    )::numeric(14,4) as newer_lot_qty
  from latest_snapshot s
  join public.vw_inventory_lot_live vl on true
  left join public.vw_inventory_live vi on vi.external_code = vl.external_code
  left join public.medicines m on m.id = vl.medicine_id
  where coalesce(m.active, true) = true
    and greatest(coalesce(vi.stock_qty, 0), 0) > 0
    and greatest(coalesce(vl.lot_qty, 0), 0) > 0
),
fifo_live as (
  select
    *,
    greatest(
      0,
      least(
        adjusted_lot_qty,
        stock_qty - newer_lot_qty
      )
    ) as lot_qty
  from live_lots
)
select
  snapshot_date,
  source_file,
  external_code,
  medicine_name,
  model,
  secondary_name,
  presentation,
  stock_qty,
  unit_cost,
  (lot_qty * unit_cost)::numeric(14,4) as stock_value,
  lot_no,
  lot_sequence,
  expires_at,
  original_lot_qty,
  lot_qty,
  case
    when expires_at is null then null
    else (expires_at - current_date)
  end as days_to_expire,
  case
    when expires_at is null then 'unknown'
    when expires_at < current_date then 'expired'
    when expires_at <= current_date + interval '30 days' then 'expires_30_days'
    when expires_at <= current_date + interval '90 days' then 'expires_90_days'
    when expires_at <= current_date + interval '180 days' then 'expires_180_days'
    else 'ok'
  end as expiration_status
from fifo_live
where lot_qty > 0;

notify pgrst, 'reload schema';
