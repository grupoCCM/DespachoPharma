-- Dashboard price/margin watch.
-- Margin is calculated on net sale price (without VAT). Reference comparison uses final sale price with VAT.

create or replace function public.rpc_dashboard_price_margin_watch(
  p_session_token text,
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_limit integer := greatest(1, least(coalesce(p_limit, 250), 500));
  v_summary jsonb;
  v_rows jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  with latest_ref as (
    select distinct on (mrp.external_code)
      mrp.external_code,
      mrp.reference_price
    from public.medicine_reference_prices mrp
    order by mrp.external_code, mrp.loaded_at desc
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
    where pi.unit_cost_estimated > 0
    order by pi.external_code, pd.purchase_date desc, pd.created_at desc
  ),
  purchase_costs as (
    select
      pi.external_code,
      avg(pi.unit_cost_estimated) filter (where pi.unit_cost_estimated > 0) as avg_cost,
      min(pi.unit_cost_estimated) filter (where pi.unit_cost_estimated > 0) as min_cost
    from public.purchase_items pi
    group by pi.external_code
  ),
  base as (
    select
      m.external_code,
      m.name as medicine_name,
      m.secondary_name,
      m.model,
      m.subgroup_name,
      coalesce(m.purchase_blocked, false) as purchase_blocked,
      m.price_1 as sale_price_net,
      round((coalesce(m.price_1, 0) * 1.13)::numeric, 2) as sale_price_gross,
      coalesce(o.reference_price, lr.reference_price) as reference_price_gross,
      case when o.id is not null then true else false end as reference_is_manual,
      lp.last_cost,
      lp.purchase_date as last_purchase_date,
      lp.supplier_name,
      pc.avg_cost,
      pc.min_cost,
      coalesce(vl.stock_qty, 0) as stock_qty
    from public.medicines m
    left join latest_ref lr on lr.external_code = m.external_code
    left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
    left join last_purchase lp on lp.external_code = m.external_code
    left join purchase_costs pc on pc.external_code = m.external_code
    left join public.vw_inventory_live vl on vl.external_code = m.external_code
    where m.active is true
  ),
  calc as (
    select
      *,
      case
        when sale_price_net > 0 and last_cost > 0
        then round(((sale_price_net - last_cost) / sale_price_net * 100)::numeric, 2)
      end as margin_net_pct,
      case when last_cost > 0 then round((last_cost / 0.80)::numeric, 2) end as suggested_20_net,
      case when last_cost > 0 then round((last_cost / 0.75)::numeric, 2) end as suggested_25_net,
      case when last_cost > 0 then round((last_cost / 0.80 * 1.13)::numeric, 2) end as suggested_20_gross,
      case when last_cost > 0 then round((last_cost / 0.75 * 1.13)::numeric, 2) end as suggested_25_gross
    from base
    where coalesce(purchase_blocked, false) is false
      and coalesce(last_cost, 0) > 0
      and coalesce(sale_price_net, 0) > 0
  ),
  flagged as (
    select
      *,
      case
        when margin_net_pct < 20 then 'critical'
        when margin_net_pct < 25 then 'review'
        else 'ok'
      end as margin_status,
      case
        when margin_net_pct < 20 then 'Subir precio: bajo minimo 20%'
        when margin_net_pct < 25 then 'Revisar precio: bajo deseado 25%'
        else 'OK'
      end as recommendation,
      case
        when reference_price_gross is not null and suggested_25_gross > reference_price_gross then true
        else false
      end as negotiation_risk,
      case
        when reference_price_gross is not null then round((reference_price_gross - sale_price_gross)::numeric, 2)
      end as reference_vs_current_gross,
      case
        when reference_price_gross is not null then round((reference_price_gross - suggested_25_gross)::numeric, 2)
      end as reference_vs_suggested_25_gross
    from calc
  ),
  rows_base as (
    select *
    from flagged
    where margin_status in ('critical', 'review')
    order by
      case margin_status when 'critical' then 0 when 'review' then 1 else 2 end,
      negotiation_risk desc,
      margin_net_pct asc,
      stock_qty desc,
      medicine_name
    limit v_limit
  )
  select jsonb_build_object(
    'total_review_items', count(*) filter (where margin_status in ('critical', 'review')),
    'critical_items', count(*) filter (where margin_status = 'critical'),
    'desired_gap_items', count(*) filter (where margin_status = 'review'),
    'negotiation_risk_items', count(*) filter (where margin_status in ('critical','review') and negotiation_risk),
    'avg_margin_net_pct', round(avg(margin_net_pct) filter (where margin_status in ('critical','review'))::numeric, 2),
    'desired_margin_pct', 25,
    'minimum_margin_pct', 20,
    'vat_pct', 13
  ) into v_summary
  from flagged;

  select coalesce(jsonb_agg(to_jsonb(rows_base)), '[]'::jsonb) into v_rows
  from rows_base;

  return jsonb_build_object('summary', coalesce(v_summary, '{}'::jsonb), 'rows', v_rows);
end;
$$;

grant execute on function public.rpc_dashboard_price_margin_watch(text, integer) to anon, authenticated;
