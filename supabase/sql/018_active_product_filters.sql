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
  where m.active is true
    and coalesce(i.stock_qty, 0) > 0
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
      when stock_qty < 15 then 'Pocas unidades'
      else 'Disponible'
    end as availability_status
  from base
  order by
    case when stock_qty < 15 then 1 else 0 end,
    medicine_name
  limit greatest(1, least(coalesce(p_limit, 30), 100))
) x;
$$;

grant execute on function public.rpc_public_availability_search(text, integer) to anon, authenticated;

create or replace function public.rpc_inventory_variance_control(
  p_session_token text,
  p_query text default '',
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
  v_payload jsonb;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');

  select u.role into v_user_role
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active is true
  limit 1;

  if v_user_role is distinct from 'admin'::public.user_role then
    raise exception 'No autorizado para control de inventario';
  end if;

  with snapshots as (
    select
      id,
      snapshot_date,
      source_file,
      created_at,
      row_number() over (order by snapshot_date desc, created_at desc) as rn
    from public.inventory_snapshots
  ),
  latest as (
    select * from snapshots where rn = 1
  ),
  previous as (
    select * from snapshots where rn = 2
  ),
  latest_items as (
    select
      i.external_code,
      i.medicine_id,
      i.description_snapshot,
      i.model,
      i.stock_qty as physical_qty,
      i.unit_cost,
      i.stock_value
    from public.inventory_snapshot_items i
    join latest l on l.id = i.snapshot_id
    left join public.medicines m on m.id = i.medicine_id
    where coalesce(m.active, true) is true
  ),
  previous_items as (
    select
      i.external_code,
      i.stock_qty as previous_qty,
      i.unit_cost as previous_unit_cost
    from public.inventory_snapshot_items i
    join previous p on p.id = i.snapshot_id
    left join public.medicines m on m.id = i.medicine_id
    where coalesce(m.active, true) is true
  ),
  movements_between as (
    select
      im.external_code,
      coalesce(sum(im.qty_delta), 0) as movement_qty,
      coalesce(sum(im.qty_delta) filter (where im.qty_delta > 0), 0) as in_qty,
      abs(coalesce(sum(im.qty_delta) filter (where im.qty_delta < 0), 0)) as out_qty,
      count(*) as movement_count,
      max(im.created_at) as last_movement_at,
      bool_or(im.movement_type = 'purchase_in') as has_purchase,
      bool_or(im.movement_type = 'dispatch_out') as has_dispatch,
      bool_or(im.movement_type like '%return%' or im.movement_type like '%void%') as has_return
    from public.inventory_movements im
    cross join previous p
    cross join latest l
    left join public.medicines m on m.external_code = im.external_code
    where im.external_code is not null
      and coalesce(m.active, true) is true
      and im.created_at > p.created_at
      and im.created_at <= l.created_at
    group by im.external_code
  ),
  universe as (
    select external_code from latest_items
    union
    select external_code from previous_items
    union
    select external_code from movements_between
  ),
  variance_rows as (
    select
      u.external_code,
      coalesce(m.name, li.description_snapshot, 'Sin catalogo') as medicine_name,
      coalesce(m.model, li.model) as model,
      m.secondary_name,
      coalesce(pi.previous_qty, 0) as previous_qty,
      coalesce(mb.movement_qty, 0) as movement_qty,
      coalesce(mb.in_qty, 0) as in_qty,
      coalesce(mb.out_qty, 0) as out_qty,
      coalesce(pi.previous_qty, 0) + coalesce(mb.movement_qty, 0) as expected_qty,
      coalesce(li.physical_qty, 0) as physical_qty,
      coalesce(li.physical_qty, 0) - (coalesce(pi.previous_qty, 0) + coalesce(mb.movement_qty, 0)) as variance_qty,
      coalesce(li.unit_cost, pi.previous_unit_cost, 0) as unit_cost,
      (coalesce(li.physical_qty, 0) - (coalesce(pi.previous_qty, 0) + coalesce(mb.movement_qty, 0))) * coalesce(li.unit_cost, pi.previous_unit_cost, 0) as variance_value,
      coalesce(mb.movement_count, 0) as movement_count,
      mb.last_movement_at,
      case
        when li.external_code is null then 'No aparece en ultima foto'
        when pi.external_code is null and coalesce(mb.movement_qty, 0) = 0 then 'Nuevo en foto'
        when coalesce(mb.has_purchase, false) and not coalesce(mb.has_dispatch, false) then 'Revisar compra/carga'
        when coalesce(mb.has_dispatch, false) and not coalesce(mb.has_purchase, false) then 'Revisar despacho/anulacion'
        when coalesce(mb.has_purchase, false) and coalesce(mb.has_dispatch, false) then 'Revisar compras y despachos'
        when coalesce(mb.has_return, false) then 'Revisar anulacion/devolucion'
        else 'Revisar conteo o cruce'
      end as probable_cause
    from universe u
    left join latest_items li on li.external_code = u.external_code
    left join previous_items pi on pi.external_code = u.external_code
    left join movements_between mb on mb.external_code = u.external_code
    left join public.medicines m on m.external_code = u.external_code
    where coalesce(m.active, true) is true
  ),
  filtered as (
    select *
    from variance_rows
    where variance_qty <> 0
      and (
        v_query = ''
        or external_code::text = v_query
        or coalesce(medicine_name, '') ilike '%' || v_query || '%'
        or coalesce(model, '') ilike '%' || v_query || '%'
        or coalesce(secondary_name, '') ilike '%' || v_query || '%'
      )
  )
  select jsonb_build_object(
    'snapshot', (
      select jsonb_build_object(
        'latest_date', l.snapshot_date,
        'latest_file', l.source_file,
        'previous_date', p.snapshot_date,
        'previous_file', p.source_file
      )
      from latest l
      left join previous p on true
    ),
    'summary', (
      select jsonb_build_object(
        'variance_items', count(*),
        'shortage_items', count(*) filter (where variance_qty < 0),
        'surplus_items', count(*) filter (where variance_qty > 0),
        'shortage_qty', abs(coalesce(sum(variance_qty) filter (where variance_qty < 0), 0)),
        'surplus_qty', coalesce(sum(variance_qty) filter (where variance_qty > 0), 0),
        'net_variance_qty', coalesce(sum(variance_qty), 0),
        'variance_abs_value', coalesce(sum(abs(variance_value)), 0),
        'shortage_value', abs(coalesce(sum(variance_value) filter (where variance_value < 0), 0)),
        'surplus_value', coalesce(sum(variance_value) filter (where variance_value > 0), 0)
      )
      from filtered
    ),
    'rows', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
      from (
        select *
        from filtered
        order by abs(variance_value) desc, abs(variance_qty) desc, medicine_name
        limit v_limit
      ) x
    )
  )
  into v_payload;

  return v_payload;
end;
$$;

grant execute on function public.rpc_inventory_variance_control(text, text, integer) to anon, authenticated;
