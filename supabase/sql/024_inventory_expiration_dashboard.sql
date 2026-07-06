create or replace function public.parse_inventory_lot_expiry(p_value text)
returns date
language plpgsql
immutable
as $$
declare
  v_parts text[];
  v_day integer;
  v_month integer;
  v_year integer;
  v_last_day integer;
  v_mon text;
begin
  if p_value is null or trim(p_value) = '' then
    return null;
  end if;

  v_parts := regexp_split_to_array(trim(p_value), '/');
  if array_length(v_parts, 1) <> 3 then
    return null;
  end if;

  v_day := nullif(regexp_replace(v_parts[1], '[^0-9]', '', 'g'), '')::integer;
  v_mon := lower(left(trim(v_parts[2]), 3));
  v_year := nullif(regexp_replace(v_parts[3], '[^0-9]', '', 'g'), '')::integer;

  v_month := case v_mon
    when 'ene' then 1
    when 'feb' then 2
    when 'mar' then 3
    when 'abr' then 4
    when 'may' then 5
    when 'jun' then 6
    when 'jul' then 7
    when 'ago' then 8
    when 'sep' then 9
    when 'oct' then 10
    when 'nov' then 11
    when 'dic' then 12
    else null
  end;

  if v_day is null or v_month is null or v_year is null then
    return null;
  end if;

  v_last_day := extract(day from (date_trunc('month', make_date(v_year, v_month, 1)) + interval '1 month - 1 day'))::integer;
  return make_date(v_year, v_month, least(v_day, v_last_day));
exception when others then
  return null;
end;
$$;

create or replace function public.refresh_inventory_lots_from_snapshots()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  alter table public.inventory_lots
  add column if not exists lot_sequence integer;

  delete from public.inventory_lots
  where inventory_snapshot_item_id in (select id from public.inventory_snapshot_items);

  insert into public.inventory_lots(
    inventory_snapshot_item_id,
    medicine_id,
    lot_no,
    expires_at,
    qty,
    lot_sequence,
    source_detail
  )
  select
    i.id,
    i.medicine_id,
    nullif(trim(rx.m[1]), '') as lot_no,
    public.parse_inventory_lot_expiry(rx.m[2]) as expires_at,
    nullif(replace(rx.m[3], ',', ''), '')::numeric as qty,
    rx.ord::integer as lot_sequence,
    'Lote: ' || rx.m[1] || ', Vence: ' || rx.m[2] || ', Cantidad: ' || rx.m[3] as source_detail
  from public.inventory_snapshot_items i
  cross join lateral regexp_matches(
    coalesce(i.detail_raw, ''),
    'Lote:\s*([^,]+),\s*Vence:\s*([^,]+),\s*Cantidad:\s*([-0-9.,]+)',
    'g'
  ) with ordinality as rx(m, ord)
  where coalesce(i.detail_raw, '') ilike '%Lote:%';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

select public.refresh_inventory_lots_from_snapshots();

drop view if exists public.vw_expiration_risk_latest;

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
)
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
  il.qty as lot_qty,
  case
    when il.expires_at is null then null
    else (il.expires_at - current_date)
  end as days_to_expire,
  case
    when il.expires_at is null then 'unknown'
    when il.expires_at < current_date then 'expired'
    when il.expires_at <= current_date + interval '30 days' then 'expires_30_days'
    when il.expires_at <= current_date + interval '90 days' then 'expires_90_days'
    when il.expires_at <= current_date + interval '180 days' then 'expires_180_days'
    else 'ok'
  end as expiration_status
from latest_items li
left join public.inventory_lots il on il.inventory_snapshot_item_id = li.id
left join public.medicines m on m.id = li.medicine_id
where coalesce(m.active, true) = true
  and li.stock_qty > 0;

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
        'snapshot_date', max(snapshot_date),
        'source_file', max(source_file)
      )
      from public.vw_expiration_risk_latest
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
        'risk_stock_value', coalesce(sum(stock_value) filter (
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
          lot_qty,
          days_to_expire,
          expiration_status
        from public.vw_expiration_risk_latest
        where (
            expiration_status = 'expired'
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
        order by expires_at nulls last, medicine_name, lot_sequence, lot_no
        limit v_limit
      ) x
    )
  );
end;
$$;

grant execute on function public.parse_inventory_lot_expiry(text) to anon, authenticated;
grant execute on function public.refresh_inventory_lots_from_snapshots() to anon, authenticated;
grant execute on function public.rpc_inventory_expiration_dashboard(text, text, integer, integer) to anon, authenticated;
