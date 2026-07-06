create or replace function public.rpc_inventory_variance_control(
  p_session_token text,
  p_query text default '',
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_limit integer := greatest(10, least(coalesce(p_limit, 100), 300));
  v_query text := trim(coalesce(p_query, ''));
  v_payload jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
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
  ),
  previous_items as (
    select
      i.external_code,
      i.stock_qty as previous_qty,
      i.unit_cost as previous_unit_cost
    from public.inventory_snapshot_items i
    join previous p on p.id = i.snapshot_id
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
    where im.external_code is not null
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
        'latest_snapshot_date', l.snapshot_date,
        'latest_source_file', l.source_file,
        'latest_created_at', l.created_at,
        'previous_snapshot_date', p.snapshot_date,
        'previous_source_file', p.source_file,
        'previous_created_at', p.created_at,
        'has_previous', p.id is not null
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

  return coalesce(v_payload, jsonb_build_object(
    'snapshot', jsonb_build_object('has_previous', false),
    'summary', jsonb_build_object(),
    'rows', '[]'::jsonb
  ));
end;
$$;

grant execute on function public.rpc_inventory_variance_control(text, text, integer) to anon, authenticated;
