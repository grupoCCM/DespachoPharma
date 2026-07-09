create or replace function public.dispatch_stock_check(
  p_barcode text,
  p_requested_qty numeric,
  p_exclude_dispatch_id uuid default null
)
returns table(
  external_code integer,
  medicine_name text,
  stock_qty numeric,
  reserved_qty numeric,
  available_qty numeric,
  requested_qty numeric,
  ok boolean
)
language sql
security definer
set search_path = public
as $$
with matched as (
  select apm.barcode, apm.product_name
  from public.app_pharma_match(p_barcode) apm
  where apm.active is true
  limit 1
),
med as (
  select m.external_code, coalesce(m.name, matched.product_name) as medicine_name
  from matched
  join public.medicines m on m.barcode = matched.barcode
  order by m.active desc, m.external_code
  limit 1
),
live_stock as (
  select coalesce(vl.stock_qty, 0)::numeric as qty
  from med
  left join public.vw_inventory_live vl on vl.external_code = med.external_code
)
select
  med.external_code,
  med.medicine_name,
  live_stock.qty as stock_qty,
  0::numeric as reserved_qty,
  greatest(live_stock.qty, 0) as available_qty,
  coalesce(p_requested_qty, 0)::numeric as requested_qty,
  med.external_code is not null
    and coalesce(p_requested_qty, 0) > 0
    and greatest(live_stock.qty, 0) >= coalesce(p_requested_qty, 0)::numeric as ok
from med
cross join live_stock;
$$;

grant execute on function public.dispatch_stock_check(text, numeric, uuid) to anon, authenticated;
