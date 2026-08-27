-- Semantic inventory state layer.
-- This migration is intentionally additive: it does not replace existing
-- inventory views or change any consumer. It introduces explicit names for
-- physical, expired, reserved, quarantine, not-sellable and sellable stock.

create or replace view public.vw_lot_stock_state as
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
    s.created_at as snapshot_created_at,
    vl.lot_id,
    vl.inventory_snapshot_item_id,
    vl.external_code,
    vl.medicine_id,
    vl.barcode,
    vl.medicine_name,
    vl.model,
    vl.secondary_name,
    vl.presentation,
    greatest(coalesce(vi.stock_qty, 0), 0)::numeric(14,4) as product_physical_qty,
    coalesce(vi.unit_cost, vl.unit_cost, 0)::numeric(14,6) as unit_cost,
    vl.lot_no,
    vl.lot_sequence,
    vl.expires_at,
    vl.original_lot_qty,
    greatest(coalesce(vl.lot_qty, 0), 0)::numeric(14,4) as raw_lot_qty,
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
capped_lots as (
  select
    *,
    greatest(
      0,
      least(
        raw_lot_qty,
        product_physical_qty - newer_lot_qty
      )
    )::numeric(14,4) as physical_lot_qty
  from live_lots
),
state_rows as (
  select
    *,
    case
      when expires_at is null then null
      else (expires_at - current_date)
    end as days_to_expire,
    case
      when expires_at is null then 'unknown'
      when expires_at <= current_date then 'expired'
      when expires_at <= current_date + interval '30 days' then 'expires_30_days'
      when expires_at <= current_date + interval '90 days' then 'expires_90_days'
      when expires_at <= current_date + interval '180 days' then 'expires_180_days'
      else 'ok'
    end as expiration_status
  from capped_lots
  where physical_lot_qty > 0
)
select
  snapshot_date,
  source_file,
  snapshot_created_at,
  lot_id,
  inventory_snapshot_item_id,
  external_code,
  medicine_id,
  barcode,
  medicine_name,
  model,
  secondary_name,
  presentation,
  product_physical_qty,
  unit_cost,
  lot_no,
  lot_sequence,
  expires_at,
  days_to_expire,
  expiration_status,
  original_lot_qty,
  raw_lot_qty,
  physical_lot_qty,
  case when expiration_status = 'expired' then physical_lot_qty else 0::numeric end::numeric(14,4) as expired_lot_qty,
  0::numeric(14,4) as reserved_lot_qty,
  0::numeric(14,4) as quarantine_lot_qty,
  0::numeric(14,4) as not_sellable_lot_qty,
  greatest(
    physical_lot_qty
      - case when expiration_status = 'expired' then physical_lot_qty else 0::numeric end
      - 0::numeric
      - 0::numeric
      - 0::numeric,
    0
  )::numeric(14,4) as sellable_lot_qty,
  (
    physical_lot_qty > 0
    and expiration_status <> 'expired'
  ) as is_sellable,
  (physical_lot_qty * unit_cost)::numeric(14,4) as physical_lot_value
from state_rows;

grant select on public.vw_lot_stock_state to anon, authenticated;

create or replace view public.vw_product_stock_state as
with lot_totals as (
  select
    external_code,
    sum(expired_lot_qty)::numeric(14,4) as expired_qty,
    sum(reserved_lot_qty)::numeric(14,4) as reserved_qty,
    sum(quarantine_lot_qty)::numeric(14,4) as quarantine_qty,
    sum(not_sellable_lot_qty)::numeric(14,4) as not_sellable_qty,
    min(expires_at) filter (where physical_lot_qty > 0) as nearest_expiration,
    min(expires_at) filter (where sellable_lot_qty > 0) as nearest_sellable_expiration
  from public.vw_lot_stock_state
  group by external_code
)
select
  live.external_code,
  live.medicine_id,
  live.barcode,
  live.description_snapshot,
  live.model,
  live.presentation,
  greatest(coalesce(live.snapshot_stock_qty, 0), 0)::numeric(14,4) as snapshot_physical_qty,
  coalesce(live.movement_qty, 0)::numeric(14,4) as movement_qty,
  greatest(coalesce(live.stock_qty, 0), 0)::numeric(14,4) as physical_qty,
  coalesce(lt.expired_qty, 0)::numeric(14,4) as expired_qty,
  coalesce(lt.reserved_qty, 0)::numeric(14,4) as reserved_qty,
  coalesce(lt.quarantine_qty, 0)::numeric(14,4) as quarantine_qty,
  coalesce(lt.not_sellable_qty, 0)::numeric(14,4) as not_sellable_qty,
  greatest(
    coalesce(live.stock_qty, 0)
      - coalesce(lt.expired_qty, 0)
      - coalesce(lt.reserved_qty, 0)
      - coalesce(lt.quarantine_qty, 0)
      - coalesce(lt.not_sellable_qty, 0),
    0
  )::numeric(14,4) as sellable_qty,
  live.unit_cost,
  live.stock_value as physical_stock_value,
  live.snapshot_created_at,
  lt.nearest_expiration,
  lt.nearest_sellable_expiration
from public.vw_inventory_live live
left join lot_totals lt on lt.external_code = live.external_code;

grant select on public.vw_product_stock_state to anon, authenticated;

notify pgrst, 'reload schema';
