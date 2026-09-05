-- Keep expiration and inventory state stable when an inventory upload is partial.
-- A partial snapshot updates only the products it contains; it must not become
-- the only source for the expiration dashboard or live stock views.

create or replace view public.vw_inventory_snapshot_classification as
with active_catalog as (
  select greatest(count(*), 1)::numeric as active_count
  from public.medicines
  where active is true
),
snapshot_counts as (
  select
    s.id,
    s.snapshot_date,
    s.source_file,
    s.total_units,
    s.total_value,
    s.created_at,
    count(i.id)::integer as item_count
  from public.inventory_snapshots s
  left join public.inventory_snapshot_items i on i.snapshot_id = s.id
  group by s.id, s.snapshot_date, s.source_file, s.total_units, s.total_value, s.created_at
)
select
  sc.id,
  sc.snapshot_date,
  sc.source_file,
  sc.total_units,
  sc.total_value,
  sc.created_at,
  sc.item_count,
  ac.active_count::integer as active_catalog_count,
  (sc.item_count::numeric >= ac.active_count * 0.75) as is_complete_snapshot,
  case
    when sc.item_count::numeric >= ac.active_count * 0.75 then 'foto_completa'
    else 'actualizacion_parcial'
  end as inventory_scope
from snapshot_counts sc
cross join active_catalog ac;

grant select on public.vw_inventory_snapshot_classification to anon, authenticated;

create or replace view public.vw_inventory_live as
with current_snapshot_item as (
  select
    i.external_code,
    i.medicine_id,
    m.barcode,
    i.description_snapshot,
    i.model,
    i.presentation,
    i.stock_qty,
    i.unit_cost,
    i.stock_value,
    s.created_at as snapshot_created_at,
    row_number() over (
      partition by i.external_code
      order by s.snapshot_date desc, s.created_at desc, i.created_at desc, i.id desc
    ) as rn
  from public.inventory_snapshot_items i
  join public.inventory_snapshots s on s.id = i.snapshot_id
  left join public.medicines m on m.id = i.medicine_id
  where i.external_code is not null
    and coalesce(m.active, true) = true
),
snapshot_stock as (
  select *
  from current_snapshot_item
  where rn = 1
),
movement_stock as (
  select
    ss.external_code,
    sum(im.qty_delta) as movement_qty
  from snapshot_stock ss
  join public.inventory_movements im on im.external_code = ss.external_code
  where im.created_at > ss.snapshot_created_at
  group by ss.external_code
)
select
  ss.external_code,
  ss.medicine_id,
  ss.barcode,
  ss.description_snapshot,
  ss.model,
  ss.presentation,
  ss.stock_qty as snapshot_stock_qty,
  coalesce(ms.movement_qty, 0) as movement_qty,
  ss.stock_qty + coalesce(ms.movement_qty, 0) as stock_qty,
  ss.unit_cost,
  case
    when ss.unit_cost is null then ss.stock_value
    else (ss.stock_qty + coalesce(ms.movement_qty, 0)) * ss.unit_cost
  end as stock_value,
  ss.snapshot_created_at
from snapshot_stock ss
left join movement_stock ms on ms.external_code = ss.external_code;

grant select on public.vw_inventory_live to anon, authenticated;

create or replace view public.vw_inventory_lot_live as
with current_snapshot_item as (
  select
    i.id as inventory_snapshot_item_id,
    i.external_code,
    i.medicine_id,
    i.presentation,
    i.stock_qty,
    i.unit_cost,
    i.stock_value,
    s.created_at as snapshot_created_at,
    row_number() over (
      partition by i.external_code
      order by s.snapshot_date desc, s.created_at desc, i.created_at desc, i.id desc
    ) as rn
  from public.inventory_snapshot_items i
  join public.inventory_snapshots s on s.id = i.snapshot_id
  left join public.medicines m on m.id = i.medicine_id
  where i.external_code is not null
    and coalesce(m.active, true) = true
),
latest_lots as (
  select
    il.id as lot_id,
    ci.inventory_snapshot_item_id,
    ci.medicine_id,
    ci.external_code,
    m.barcode,
    coalesce(m.name, i.description_snapshot) as medicine_name,
    m.model,
    m.secondary_name,
    ci.presentation,
    ci.stock_qty,
    ci.unit_cost,
    ci.stock_value,
    il.lot_no,
    il.lot_sequence,
    il.expires_at,
    il.qty as original_lot_qty,
    ci.snapshot_created_at
  from current_snapshot_item ci
  join public.inventory_snapshot_items i on i.id = ci.inventory_snapshot_item_id
  join public.inventory_lots il on il.inventory_snapshot_item_id = ci.inventory_snapshot_item_id
  left join public.medicines m on m.id = ci.medicine_id
  where ci.rn = 1
),
lot_movements as (
  select
    ll.lot_id,
    sum(lm.qty_delta) as movement_qty
  from latest_lots ll
  join public.inventory_lot_movements lm on lm.lot_id = ll.lot_id
  where lm.created_at > ll.snapshot_created_at
  group by ll.lot_id
)
select
  ll.*,
  coalesce(lm.movement_qty, 0) as movement_qty,
  ll.original_lot_qty + coalesce(lm.movement_qty, 0) as lot_qty
from latest_lots ll
left join lot_movements lm on lm.lot_id = ll.lot_id;

grant select on public.vw_inventory_lot_live to anon, authenticated;

create or replace view public.vw_lot_stock_state as
with live_lots as (
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
  from public.vw_inventory_lot_live vl
  join public.inventory_snapshot_items i on i.id = vl.inventory_snapshot_item_id
  join public.inventory_snapshots s on s.id = i.snapshot_id
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

create or replace view public.vw_expiration_risk_latest as
select
  snapshot_date,
  source_file,
  external_code,
  medicine_name,
  model,
  secondary_name,
  presentation,
  product_physical_qty::numeric(14,4) as stock_qty,
  unit_cost::numeric(14,6) as unit_cost,
  physical_lot_value::numeric(14,4) as stock_value,
  lot_no,
  lot_sequence,
  expires_at,
  original_lot_qty::numeric(14,4) as original_lot_qty,
  physical_lot_qty::numeric as lot_qty,
  days_to_expire,
  expiration_status
from public.vw_lot_stock_state
where physical_lot_qty > 0;

grant select on public.vw_expiration_risk_latest to anon, authenticated;

create or replace function public.rpc_inventory_expiration_dashboard(
  p_session_token text,
  p_query text default '',
  p_days integer default 180,
  p_limit integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_days integer := greatest(0, least(coalesce(p_days, 180), 730));
  v_limit integer := greatest(20, least(coalesce(p_limit, 120), 500));
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  return jsonb_build_object(
    'snapshot', (
      select jsonb_build_object(
        'snapshot_date', fs.snapshot_date,
        'source_file', fs.source_file,
        'latest_update_date', us.snapshot_date,
        'latest_update_source_file', us.source_file,
        'latest_update_scope', us.inventory_scope,
        'products_considered', ps.products_considered,
        'full_snapshot_products', fs.item_count,
        'latest_update_products', us.item_count
      )
      from (
        select *
        from public.vw_inventory_snapshot_classification
        where is_complete_snapshot is true
        order by snapshot_date desc, created_at desc
        limit 1
      ) fs
      full join (
        select *
        from public.vw_inventory_snapshot_classification
        order by snapshot_date desc, created_at desc
        limit 1
      ) us on true
      cross join (
        select count(distinct external_code) as products_considered
        from public.vw_inventory_live
      ) ps
    ),
    'summary', (
      select jsonb_build_object(
        'products_with_stock', count(distinct external_code),
        'products_with_lots', count(distinct external_code) filter (where lot_no is not null),
        'lots_total', count(*) filter (where lot_no is not null),
        'expired_lots', count(*) filter (where expiration_status = 'expired'),
        'expires_30_days', count(*) filter (where expiration_status = 'expires_30_days'),
        'expires_90_days', count(*) filter (where expiration_status = 'expires_90_days'),
        'expires_180_days', count(*) filter (where expiration_status = 'expires_180_days'),
        'unknown_lots', count(*) filter (where expiration_status = 'unknown'),
        'risk_stock_value', coalesce(sum((lot_qty * coalesce(unit_cost, 0))) filter (
          where expiration_status in ('expired', 'expires_30_days', 'expires_90_days', 'expires_180_days')
        ), 0)
      )
      from public.vw_expiration_risk_latest
    ),
    'rows', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
      from (
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
          lot_qty,
          days_to_expire,
          expiration_status
        from public.vw_expiration_risk_latest
        where (
            v_query <> ''
            or expiration_status = 'expired'
            or expires_at <= current_date + (v_days || ' days')::interval
            or lot_no is null
          )
          and (
            v_query = ''
            or external_code::text = v_query
            or coalesce(medicine_name, '') ilike '%' || v_query || '%'
            or coalesce(model, '') ilike '%' || v_query || '%'
            or coalesce(secondary_name, '') ilike '%' || v_query || '%'
            or coalesce(lot_no, '') ilike '%' || v_query || '%'
          )
        order by
          case when expiration_status = 'expired' then 0 else 1 end,
          expires_at nulls last,
          medicine_name,
          lot_sequence,
          lot_no
        limit v_limit
      ) x
    )
  );
end;
$$;

grant execute on function public.rpc_inventory_expiration_dashboard(text, text, integer, integer) to anon, authenticated;

notify pgrst, 'reload schema';
