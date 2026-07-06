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

  with latest_ref as (
    select distinct on (mrp.external_code)
      mrp.external_code,
      mrp.reference_price
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
    select
      pi.external_code,
      min(pi.unit_cost_estimated) filter (where pi.unit_cost_estimated > 0) as min_cost,
      avg(pi.unit_cost_estimated) filter (where pi.unit_cost_estimated > 0) as avg_cost,
      count(*) as purchase_lines
    from public.purchase_items pi
    group by pi.external_code
  ),
  last_purchase as (
    select distinct on (pi.external_code)
      pi.external_code,
      pd.purchase_date,
      s.name as supplier_name,
      pi.unit_cost_estimated as last_cost
    from public.purchase_items pi
    join public.purchase_documents pd on pd.id = pi.purchase_document_id
    left join public.suppliers s on s.id = pd.supplier_id
    order by pi.external_code, pd.purchase_date desc, pd.created_at desc
  ),
  min_purchase as (
    select distinct on (pi.external_code)
      pi.external_code,
      pd.purchase_date as min_cost_date,
      pi.unit_cost_estimated as min_cost_exact
    from public.purchase_items pi
    join public.purchase_documents pd on pd.id = pi.purchase_document_id
    where pi.unit_cost_estimated > 0
    order by pi.external_code, pi.unit_cost_estimated asc, pd.purchase_date asc
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
      m.price_1 as current_price,
      coalesce(i.stock_qty, 0) as stock_qty,
      coalesce(i.stock_value, 0) as stock_value,
      coalesce(o.reference_price, lr.reference_price) as reference_price,
      case when o.id is not null then true else false end as reference_is_manual,
      rm.abc_rotation,
      rm.monthly_rotation,
      rm.current_stock,
      rm.coverage_months,
      rm.last_sale_date,
      pr.suggested_qty,
      pr.estimated_purchase_value,
      pr.action,
      pr.expiration_risk,
      lp.last_cost,
      pc.avg_cost,
      pc.min_cost,
      mp.min_cost_date,
      lp.supplier_name,
      lp.purchase_date as last_purchase_date
    from public.medicines m
    left join public.vw_inventory_live i on i.external_code = m.external_code
    left join latest_ref lr on lr.external_code = m.external_code
    left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
    left join latest_rotation r on true
    left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
    left join public.purchase_recommendations pr on pr.rotation_run_id = r.id and pr.external_code = m.external_code
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
  )
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows
  from (
    select
      *,
      case
        when action ilike 'Pedir ya%' then 'Pedir'
        when suggested_qty > 0 then 'Vigilar'
        when stock_qty <= 0 and monthly_rotation > 0 then 'Pedir'
        else 'Esperar'
      end as decision,
      case
        when reference_price is not null and last_cost is not null and reference_price > 0
        then round(((reference_price - last_cost) / reference_price) * 100, 2)
      end as ref_margin_vs_last_cost_pct,
      case
        when reference_price is not null and avg_cost is not null and reference_price > 0
        then round(((reference_price - avg_cost) / reference_price) * 100, 2)
      end as ref_margin_vs_avg_cost_pct
    from base
    order by
      case when action ilike 'Pedir ya%' then 0 when suggested_qty > 0 then 1 else 2 end,
      suggested_qty desc nulls last,
      medicine_name
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) x;

  return jsonb_build_object('rows', v_rows);
end;
$$;

grant execute on function public.rpc_purchasing_support(text, text, integer) to anon, authenticated;
