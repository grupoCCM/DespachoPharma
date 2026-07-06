create or replace function public.rpc_public_availability_search(p_query text, p_limit integer default 30)
returns jsonb
language sql
security definer
set search_path = public
as $$
with query_input as (
  select lower(trim(coalesce(p_query, ''))) as q
),
latest_ref as (
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
    rm.last_sale_date,
    case
      when qi.q = '' then 10
      when m.external_code::text = qi.q or lower(coalesce(m.barcode, '')) = qi.q then 0
      when lower(m.name) like qi.q || '%' then 1
      when lower(m.name) like '%' || qi.q || '%' then 2
      when lower(coalesce(m.secondary_name, '')) like qi.q || '%' then 3
      when lower(coalesce(m.secondary_name, '')) like '%' || qi.q || '%' then 4
      when lower(coalesce(m.model, '')) like qi.q || '%' then 5
      when lower(coalesce(m.model, '')) like '%' || qi.q || '%' then 6
      else 7
    end as search_rank
  from public.medicines m
  cross join query_input qi
  left join public.vw_inventory_live i on i.external_code = m.external_code
  left join latest_ref lr on lr.external_code = m.external_code
  left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
  left join latest_rotation r on true
  left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
  where qi.q = ''
     or m.external_code::text = qi.q
     or lower(coalesce(m.barcode, '')) like '%' || qi.q || '%'
     or lower(m.name) like '%' || qi.q || '%'
     or lower(coalesce(m.secondary_name, '')) like '%' || qi.q || '%'
     or lower(coalesce(m.model, '')) like '%' || qi.q || '%'
     or lower(coalesce(m.brand_name, '')) like '%' || qi.q || '%'
     or lower(coalesce(m.presentation_name, '')) like '%' || qi.q || '%'
     or lower(coalesce(m.subgroup_name, '')) like '%' || qi.q || '%'
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
      when stock_qty <= 0 then 'Agotado'
      when stock_qty < 15 then 'Pocas unidades'
      else 'Disponible'
    end as availability_status
  from base
  order by
    case
      when active is false then 3
      when stock_qty <= 0 then 2
      when stock_qty < 15 then 1
      else 0
    end,
    search_rank,
    medicine_name
  limit greatest(1, least(coalesce(p_limit, 30), 200))
) x;
$$;

grant execute on function public.rpc_public_availability_search(text, integer) to anon, authenticated;
