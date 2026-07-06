create or replace function public.rpc_public_availability_search(p_query text, p_limit integer default 30)
returns jsonb
language sql
security definer
set search_path = public
as $$
with latest_ref as (
  select distinct on (external_code)
    external_code,
    reference_price
  from public.medicine_reference_prices
  order by external_code, loaded_at desc
),
latest_rotation as (
  select rr.id
  from public.rotation_runs rr
  order by rr.cutoff_date desc nulls last, rr.created_at desc
  limit 1
),
base as (
  select
    m.external_code,
    m.name as medicine_name,
    m.secondary_name,
    m.brand_name,
    m.presentation_name,
    m.model,
    m.subgroup_name,
    m.barcode,
    m.active,
    m.price_1 as sale_price,
    coalesce(i.stock_qty, 0) as stock_qty,
    coalesce(i.stock_value, 0) as stock_value,
    coalesce(o.reference_price, lr.reference_price) as reference_price,
    rm.monthly_rotation,
    rm.coverage_months,
    rm.last_sale_date
  from public.medicines m
  left join public.vw_inventory_live i on i.external_code = m.external_code
  left join latest_ref lr on lr.external_code = m.external_code
  left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
  left join latest_rotation r on true
  left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
  where coalesce(i.stock_qty, 0) > 0
    and (
      coalesce(trim(p_query), '') = ''
      or m.external_code::text = trim(p_query)
      or coalesce(m.barcode, '') ilike '%' || trim(p_query) || '%'
      or m.name ilike '%' || trim(p_query) || '%'
      or coalesce(m.secondary_name, '') ilike '%' || trim(p_query) || '%'
      or coalesce(m.model, '') ilike '%' || trim(p_query) || '%'
      or coalesce(m.brand_name, '') ilike '%' || trim(p_query) || '%'
      or coalesce(m.presentation_name, '') ilike '%' || trim(p_query) || '%'
      or coalesce(m.subgroup_name, '') ilike '%' || trim(p_query) || '%'
    )
)
select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
from (
  select
    external_code,
    medicine_name,
    secondary_name,
    brand_name,
    presentation_name,
    model,
    subgroup_name,
    barcode,
    active,
    stock_qty,
    sale_price,
    reference_price,
    monthly_rotation,
    coverage_months,
    last_sale_date,
    case
      when active is false then 'Inactivo'
      when stock_qty < 15 then 'Pocas unidades'
      else 'Disponible'
    end as availability_status
  from base
  order by
    case
      when active is false then 2
      when stock_qty < 15 then 1
      else 0
    end,
    medicine_name
  limit greatest(1, least(coalesce(p_limit, 30), 100))
) x;
$$;

grant execute on function public.rpc_public_availability_search(text, integer) to anon, authenticated;
