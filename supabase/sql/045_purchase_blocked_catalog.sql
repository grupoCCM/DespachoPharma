-- Add catalog-level purchase block flag and make purchasing respect it.

alter table public.medicines
add column if not exists purchase_blocked boolean not null default false;

comment on column public.medicines.purchase_blocked is
  'When true, the medicine remains active for operational lookup/dispatch but is blocked from purchase orders.';

-- Search catalog including purchase block flag.
drop function if exists public.rpc_pharma_catalog_search(text, text, text, boolean, integer, integer);

create or replace function public.rpc_pharma_catalog_search(
  p_session_token text,
  p_q text default null,
  p_barcode text default null,
  p_active boolean default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table(
  external_code integer,
  barcode text,
  product_name text,
  secondary_name text,
  model text,
  group_name text,
  subgroup_name text,
  price_1 numeric,
  reference_price numeric,
  active boolean,
  purchase_blocked boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_role public.user_role;
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
    raise exception 'No autorizado para consultar catalogo';
  end if;

  return query
  with latest_ref as (
    select distinct on (mrp.external_code)
      mrp.external_code,
      mrp.reference_price
    from public.medicine_reference_prices mrp
    order by mrp.external_code, mrp.loaded_at desc
  )
  select
    m.external_code,
    m.barcode,
    m.name as product_name,
    m.secondary_name,
    m.model,
    m.group_name,
    m.subgroup_name,
    m.price_1,
    coalesce(o.reference_price, lr.reference_price) as reference_price,
    m.active,
    coalesce(m.purchase_blocked, false) as purchase_blocked
  from public.medicines m
  left join latest_ref lr on lr.external_code = m.external_code
  left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
  where (p_active is null or m.active = p_active)
    and (nullif(trim(coalesce(p_barcode, '')), '') is null or m.barcode = trim(p_barcode))
    and (
      nullif(trim(coalesce(p_q, '')), '') is null
      or m.name ilike '%' || trim(p_q) || '%'
      or coalesce(m.secondary_name, '') ilike '%' || trim(p_q) || '%'
      or coalesce(m.model, '') ilike '%' || trim(p_q) || '%'
      or coalesce(m.subgroup_name, '') ilike '%' || trim(p_q) || '%'
      or coalesce(m.barcode, '') ilike '%' || trim(p_q) || '%'
      or m.external_code::text ilike '%' || trim(p_q) || '%'
    )
  order by m.name
  limit greatest(1, least(coalesce(p_limit, 100), 500))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

grant execute on function public.rpc_pharma_catalog_search(text, text, text, boolean, integer, integer) to anon, authenticated;

-- Upsert catalog article including purchase block flag.
drop function if exists public.rpc_pharma_catalog_upsert(text, text, text, boolean, integer, text, text, text, text, numeric, numeric);
drop function if exists public.rpc_pharma_catalog_upsert(text, text, text, boolean, integer, text, text, text, text, numeric, numeric, boolean);

create or replace function public.rpc_pharma_catalog_upsert(
  p_session_token text,
  p_barcode text default null,
  p_product_name text default null,
  p_active boolean default true,
  p_external_code integer default null,
  p_secondary_name text default null,
  p_model text default null,
  p_group_name text default null,
  p_subgroup_name text default null,
  p_price_1 numeric default null,
  p_reference_price numeric default null,
  p_purchase_blocked boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_id uuid;
  v_user_role public.user_role;
  v_id uuid;
  v_external_code integer;
  v_barcode text;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');

  select u.id, u.role into v_user_id, v_user_role
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active is true
  limit 1;

  if v_user_role is distinct from 'admin'::public.user_role then
    raise exception 'No autorizado para guardar articulo';
  end if;

  if nullif(trim(coalesce(p_product_name, '')), '') is null then
    raise exception 'Nombre del articulo requerido';
  end if;

  if p_price_1 is not null and p_price_1 < 0 then
    raise exception 'Precio de venta invalido';
  end if;

  if p_reference_price is not null and p_reference_price < 0 then
    raise exception 'Precio de referencia invalido';
  end if;

  v_barcode := nullif(regexp_replace(coalesce(p_barcode, ''), '\D', '', 'g'), '');

  if v_barcode is not null then
    select id, external_code into v_id, v_external_code
    from public.medicines
    where barcode = v_barcode
    limit 1;
  end if;

  if v_id is null and p_external_code is not null then
    select id, external_code into v_id, v_external_code
    from public.medicines
    where external_code = p_external_code
    limit 1;
  end if;

  if v_id is null then
    if p_external_code is not null then
      v_external_code := p_external_code;
    else
      select coalesce(max(external_code), 0) + 1 into v_external_code
      from public.medicines;
    end if;

    insert into public.medicines(
      external_code, barcode, name, secondary_name, model, group_name, subgroup_name,
      price_1, active, purchase_blocked, inventory_item, source_file, source_loaded_at
    )
    values (
      v_external_code, v_barcode, trim(p_product_name), nullif(trim(coalesce(p_secondary_name, '')), ''),
      nullif(trim(coalesce(p_model, '')), ''), nullif(trim(coalesce(p_group_name, '')), ''),
      nullif(trim(coalesce(p_subgroup_name, '')), ''), p_price_1, coalesce(p_active, true),
      coalesce(p_purchase_blocked, false), true, 'manual_catalog', now()
    )
    returning id into v_id;
  else
    if p_external_code is not null and p_external_code <> v_external_code then
      if exists (select 1 from public.medicines where external_code = p_external_code and id <> v_id) then
        raise exception 'Ya existe otro articulo con codigo %', p_external_code;
      end if;
      v_external_code := p_external_code;
    end if;

    update public.medicines
       set external_code = v_external_code,
           barcode = v_barcode,
           name = trim(p_product_name),
           secondary_name = nullif(trim(coalesce(p_secondary_name, '')), ''),
           model = nullif(trim(coalesce(p_model, '')), ''),
           group_name = nullif(trim(coalesce(p_group_name, '')), ''),
           subgroup_name = nullif(trim(coalesce(p_subgroup_name, '')), ''),
           price_1 = p_price_1,
           active = coalesce(p_active, true),
           purchase_blocked = coalesce(p_purchase_blocked, false),
           inventory_item = true,
           source_file = coalesce(source_file, 'manual_catalog'),
           source_loaded_at = now()
     where id = v_id;
  end if;

  if p_reference_price is not null then
    insert into public.medicine_reference_price_overrides(
      medicine_id, external_code, reference_price, note, updated_by
    )
    values (v_id, v_external_code, p_reference_price, 'Editado desde catalogo manual', v_user_id)
    on conflict (external_code) do update
      set medicine_id = excluded.medicine_id,
          reference_price = excluded.reference_price,
          note = excluded.note,
          updated_by = excluded.updated_by,
          updated_at = now();
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'external_code', v_external_code,
    'barcode', v_barcode,
    'purchase_blocked', coalesce(p_purchase_blocked, false)
  );
end;
$$;

grant execute on function public.rpc_pharma_catalog_upsert(text, text, text, boolean, integer, text, text, text, text, numeric, numeric, boolean) to anon, authenticated;

-- Purchasing support: blocked catalog items remain visible when searched, but cannot be ordered.
create or replace function public.rpc_purchasing_support(p_session_token text, p_query text default '', p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_id uuid;
  v_user_role public.user_role;
  v_rows jsonb;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');

  select u.id, u.role into v_user_id, v_user_role
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active is true
  limit 1;

  if v_user_role is distinct from 'admin'::public.user_role then
    raise exception 'No autorizado para apoyo de compras';
  end if;

  with sales_bounds as (
    select max(sd.sale_date) as max_sale_date, min(sd.sale_date) as min_sale_date
    from public.sales_documents sd
  ),
  sales_window as (
    select
      coalesce(max_sale_date, current_date) as max_sale_date,
      greatest(coalesce(max_sale_date, current_date) - 89, coalesce(min_sale_date, coalesce(max_sale_date, current_date) - 89)) as start_90,
      greatest(coalesce(max_sale_date, current_date) - 29, coalesce(min_sale_date, coalesce(max_sale_date, current_date) - 29)) as start_30
    from sales_bounds
  ),
  sales_rotation as (
    select
      si.external_code,
      coalesce(sum(si.qty) filter (where sd.sale_date between sw.start_90 and sw.max_sale_date), 0)::numeric as units_90d,
      coalesce(sum(si.qty) filter (where sd.sale_date between sw.start_30 and sw.max_sale_date), 0)::numeric as units_30d,
      max(sd.sale_date) as last_sale_date,
      greatest((sw.max_sale_date - sw.start_90 + 1), 1)::numeric as sales_days_used,
      round(coalesce(sum(si.qty) filter (where sd.sale_date between sw.start_90 and sw.max_sale_date), 0)::numeric / greatest((sw.max_sale_date - sw.start_90 + 1), 1)::numeric, 4) as avg_daily_sales,
      round((coalesce(sum(si.qty) filter (where sd.sale_date between sw.start_90 and sw.max_sale_date), 0)::numeric / greatest((sw.max_sale_date - sw.start_90 + 1), 1)::numeric) * 30, 2) as monthly_rotation_live
    from sales_window sw
    join public.sales_documents sd on sd.sale_date between sw.start_90 and sw.max_sale_date
    join public.sales_items si on si.sales_document_id = sd.id
    group by si.external_code, sw.max_sale_date, sw.start_90
  ),
  latest_ref as (
    select distinct on (mrp.external_code) mrp.external_code, mrp.reference_price
    from public.medicine_reference_prices mrp
    order by mrp.external_code, mrp.loaded_at desc
  ),
  latest_rotation as (
    select rr.id
    from public.rotation_runs rr
    order by rr.cutoff_date desc nulls last, rr.created_at desc
    limit 1
  ),
  purchase_costs as (
    select pi.external_code,
      min(pi.unit_cost_estimated) filter (where pi.unit_cost_estimated > 0) as min_cost,
      avg(pi.unit_cost_estimated) filter (where pi.unit_cost_estimated > 0) as avg_cost,
      count(*) as purchase_lines
    from public.purchase_items pi
    group by pi.external_code
  ),
  last_purchase as (
    select distinct on (pi.external_code)
      pi.external_code, pd.purchase_date, s.name as supplier_name, pi.unit_cost_estimated as last_cost
    from public.purchase_items pi
    join public.purchase_documents pd on pd.id = pi.purchase_document_id
    left join public.suppliers s on s.id = pd.supplier_id
    order by pi.external_code, pd.purchase_date desc, pd.created_at desc
  ),
  min_purchase as (
    select distinct on (pi.external_code)
      pi.external_code, pd.purchase_date as min_cost_date, pi.unit_cost_estimated as min_cost_exact
    from public.purchase_items pi
    join public.purchase_documents pd on pd.id = pi.purchase_document_id
    where pi.unit_cost_estimated > 0
    order by pi.external_code, pi.unit_cost_estimated asc, pd.purchase_date asc
  ),
  expiration as (
    select distinct on (er.external_code)
      er.external_code, er.expires_at as nearest_expiration, er.days_to_expire, er.expiration_status
    from public.vw_expiration_risk_latest er
    where er.lot_qty > 0
    order by er.external_code, er.expires_at nulls last, er.days_to_expire nulls last
  ),
  base as (
    select
      m.external_code,
      m.name as medicine_name,
      m.secondary_name,
      m.brand_name,
      m.presentation_name,
      m.model,
      m.active,
      coalesce(m.purchase_blocked, false) as purchase_blocked,
      m.price_1 as current_price,
      coalesce(i.stock_qty, 0)::numeric as stock_qty,
      coalesce(i.stock_value, 0) as stock_value,
      coalesce(o.reference_price, lr.reference_price) as reference_price,
      case when o.id is not null then true else false end as reference_is_manual,
      rm.abc_rotation,
      coalesce(sr.monthly_rotation_live, rm.monthly_rotation, 0)::numeric as monthly_rotation,
      sr.monthly_rotation_live,
      sr.avg_daily_sales,
      sr.units_90d,
      sr.units_30d,
      sr.sales_days_used,
      coalesce(sr.last_sale_date, rm.last_sale_date) as last_sale_date,
      case when coalesce(sr.avg_daily_sales, 0) > 0 then round(coalesce(i.stock_qty, 0)::numeric / sr.avg_daily_sales, 1) else null end as coverage_days,
      ceil(coalesce(sr.avg_daily_sales, 0) * 30)::numeric as reorder_point,
      ceil(coalesce(sr.avg_daily_sales, 0) * 45)::numeric as target_stock_qty,
      pr.suggested_qty as imported_suggested_qty,
      pr.estimated_purchase_value as imported_estimated_purchase_value,
      pr.action as imported_action,
      pr.expiration_risk as imported_expiration_risk,
      e.nearest_expiration,
      e.days_to_expire,
      e.expiration_status,
      lp.last_cost,
      pc.avg_cost,
      pc.min_cost,
      mp.min_cost_date,
      lp.supplier_name,
      lp.purchase_date as last_purchase_date
    from public.medicines m
    left join public.vw_inventory_live i on i.external_code = m.external_code
    left join sales_rotation sr on sr.external_code = m.external_code
    left join latest_ref lr on lr.external_code = m.external_code
    left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
    left join latest_rotation r on true
    left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
    left join public.purchase_recommendations pr on pr.rotation_run_id = r.id and pr.external_code = m.external_code
    left join expiration e on e.external_code = m.external_code
    left join purchase_costs pc on pc.external_code = m.external_code
    left join last_purchase lp on lp.external_code = m.external_code
    left join min_purchase mp on mp.external_code = m.external_code
    where m.active is true
      and (
        coalesce(trim(p_query), '') = ''
        or m.external_code::text = trim(p_query)
        or m.name ilike '%' || trim(p_query) || '%'
        or coalesce(m.secondary_name, '') ilike '%' || trim(p_query) || '%'
        or coalesce(m.model, '') ilike '%' || trim(p_query) || '%'
        or coalesce(m.brand_name, '') ilike '%' || trim(p_query) || '%'
        or coalesce(lp.supplier_name, '') ilike '%' || trim(p_query) || '%'
      )
  ),
  adjusted as (
    select
      *,
      case when purchase_blocked then 0::numeric else greatest(ceil(target_stock_qty - stock_qty), 0)::numeric end as suggested_qty,
      case
        when purchase_blocked then 'No comprar: bloqueado en catalogo'
        when expiration_status in ('expired', 'expires_30_days') and stock_qty > 0 then 'Vigilar: revisar vencimiento antes de comprar'
        when coalesce(avg_daily_sales, 0) <= 0 and stock_qty <= 0 then 'Esperar: sin ventas recientes ni existencia'
        when stock_qty <= 0 and coalesce(avg_daily_sales, 0) > 0 then 'Pedir ya: sin existencia y con rotacion'
        when stock_qty <= reorder_point and coalesce(avg_daily_sales, 0) > 0 then 'Pedir: cobertura baja'
        when stock_qty < target_stock_qty and coalesce(avg_daily_sales, 0) > 0 then 'Vigilar: cerca del punto de pedido'
        else 'Esperar: cobertura suficiente'
      end as action,
      case
        when purchase_blocked then 'No comprar'
        when expiration_status in ('expired', 'expires_30_days') and stock_qty > 0 then 'Vigilar'
        when stock_qty <= 0 and coalesce(avg_daily_sales, 0) > 0 then 'Pedir'
        when stock_qty <= reorder_point and coalesce(avg_daily_sales, 0) > 0 then 'Pedir'
        when stock_qty < target_stock_qty and coalesce(avg_daily_sales, 0) > 0 then 'Vigilar'
        else 'Esperar'
      end as decision
    from base
  )
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows
  from (
    select
      *,
      case when purchase_blocked then 0 else round((greatest(suggested_qty, 0) * coalesce(last_cost, avg_cost, min_cost, 0))::numeric, 2) end as estimated_purchase_value,
      case
        when expiration_status = 'expired' then 'Vencido'
        when expiration_status = 'expires_30_days' then 'Vence en 30 dias'
        when expiration_status = 'expires_90_days' then 'Vence en 90 dias'
        when expiration_status = 'expires_180_days' then 'Vence en 180 dias'
        when expiration_status = 'unknown' then 'Lote sin vencimiento'
        else null
      end as expiration_risk,
      case when reference_price is not null and last_cost is not null and reference_price > 0 then round(((reference_price - last_cost) / reference_price) * 100, 2) end as ref_margin_vs_last_cost_pct,
      case when reference_price is not null and avg_cost is not null and reference_price > 0 then round(((reference_price - avg_cost) / reference_price) * 100, 2) end as ref_margin_vs_avg_cost_pct
    from adjusted
    order by
      case when decision = 'Pedir' then 0 when decision = 'Vigilar' then 1 when decision = 'Esperar' then 2 else 3 end,
      suggested_qty desc nulls last,
      coalesce(monthly_rotation, 0) desc,
      medicine_name
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) x;

  return jsonb_build_object('rows', v_rows);
end;
$$;

grant execute on function public.rpc_purchasing_support(text, text, integer) to anon, authenticated;
