create or replace view public.vw_expiration_risk_latest as
with latest_snapshot as (
  select id, snapshot_date, source_file, created_at
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
),
latest_items as (
  select
    i.*,
    s.snapshot_date,
    s.source_file
  from latest_snapshot s
  join public.inventory_snapshot_items i on i.snapshot_id = s.id
),
lot_fifo as (
  select
    li.snapshot_date,
    li.source_file,
    li.external_code,
    coalesce(m.name, li.description_snapshot) as medicine_name,
    m.model,
    m.secondary_name,
    li.presentation,
    li.stock_qty,
    li.unit_cost,
    li.stock_value,
    il.lot_no,
    il.lot_sequence,
    il.expires_at,
    il.qty as original_lot_qty,
    case
      when il.id is null then li.stock_qty
      else greatest(
        0,
        least(
          coalesce(il.qty, 0),
          li.stock_qty - coalesce(
            sum(coalesce(il.qty, 0)) over (
              partition by li.id
              order by il.lot_sequence desc nulls last, il.id desc
              rows between unbounded preceding and 1 preceding
            ),
            0
          )
        )
      )
    end as live_lot_qty
  from latest_items li
  left join public.inventory_lots il on il.inventory_snapshot_item_id = li.id
  left join public.medicines m on m.id = li.medicine_id
  where coalesce(m.active, true) = true
    and li.stock_qty > 0
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
  stock_value,
  lot_no,
  lot_sequence,
  expires_at,
  original_lot_qty,
  live_lot_qty as lot_qty,
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
from lot_fifo
where live_lot_qty > 0;

notify pgrst, 'reload schema';
