create or replace view public.vw_monthly_sales_profit as
select
  date_trunc('month', sd.sale_date)::date as month,
  count(distinct sd.id) as sales_documents,
  count(distinct sd.patient_id) as patients,
  count(*) as sales_lines,
  sum(si.qty) as units,
  sum(si.net_sale) as net_sales,
  sum(si.cost_total) as cost_total,
  sum(si.profit) as profit,
  case when sum(si.net_sale) <> 0 then round((sum(si.profit) / sum(si.net_sale)) * 100, 2) end as margin_pct,
  count(distinct sd.sale_date) as sales_days,
  count(si.id) filter (where si.profit < 0) as negative_profit_lines
from public.sales_documents sd
join public.sales_items si on si.sales_document_id = sd.id
group by 1;

create or replace function public.rpc_dashboard_overview(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_role public.user_role;
  v_summary jsonb;
  v_monthly jsonb;
  v_penetration jsonb;
  v_top_units jsonb;
  v_top_profit jsonb;
  v_negative jsonb;
  v_recommendations jsonb;
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

  if v_user_role is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  select jsonb_build_object(
    'sales_documents', coalesce(count(distinct sd.id), 0),
    'patients_with_sales', coalesce(count(distinct sd.patient_id), 0),
    'sales_days', coalesce(count(distinct sd.sale_date), 0),
    'sales_lines', coalesce(count(si.id), 0),
    'units', coalesce(round(sum(si.qty), 2), 0),
    'net_sales', coalesce(round(sum(si.net_sale), 2), 0),
    'cost_total', coalesce(round(sum(si.cost_total), 2), 0),
    'profit', coalesce(round(sum(si.profit), 2), 0),
    'margin_pct', case when coalesce(sum(si.net_sale), 0) <> 0 then round((sum(si.profit) / sum(si.net_sale)) * 100, 2) else null end,
    'negative_profit_lines', count(si.id) filter (where si.profit < 0),
    'first_sale_date', min(sd.sale_date),
    'last_sale_date', max(sd.sale_date)
  ) into v_summary
  from public.sales_documents sd
  join public.sales_items si on si.sales_document_id = sd.id;

  v_summary := v_summary || (
    select jsonb_build_object(
      'inventory_units', coalesce(round(sum(stock_qty), 2), 0),
      'inventory_value', coalesce(round(sum(stock_value), 2), 0),
      'inventory_items', count(*),
      'inventory_positive_items', count(*) filter (where stock_qty > 0)
    )
    from public.vw_inventory_latest
  );

  v_summary := v_summary || (
    select jsonb_build_object(
      'consultation_visits', count(*),
      'consulted_patients', count(distinct patient_id),
      'last_consultation_date', max(visit_date)
    )
    from public.consultation_visits
  );

  v_summary := v_summary || (
    select jsonb_build_object(
      'recommended_items', count(*),
      'recommended_now_items', count(*) filter (where action ilike 'Pedir ya%'),
      'recommended_qty', coalesce(round(sum(suggested_qty), 2), 0),
      'recommended_value', coalesce(round(sum(estimated_purchase_value), 2), 0)
    )
    from public.vw_purchase_recommendations_latest
  );

  select coalesce(jsonb_agg(to_jsonb(x) order by x.month), '[]'::jsonb) into v_monthly
  from (
    select month, sales_documents, patients, sales_days, sales_lines, units, round(net_sales, 2) as net_sales,
           negative_profit_lines,
           round(profit, 2) as profit, margin_pct
    from public.vw_monthly_sales_profit
    order by month desc
    limit 12
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.month), '[]'::jsonb) into v_penetration
  from (
    select month, consulted_patients, pharma_patients, converted_patients, penetration_pct
    from public.vw_patient_pharma_penetration_monthly
    order by month desc
    limit 12
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_top_units
  from (
    select external_code, medicine_name, round(units, 2) as units, round(net_sales, 2) as net_sales
    from public.vw_top_medicines_by_units
    limit 10
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_top_profit
  from (
    select external_code, medicine_name, round(units, 2) as units, round(profit, 2) as profit, margin_pct
    from public.vw_top_medicines_by_profit
    limit 10
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_negative
  from (
    select sale_date, external_sale_no, voucher_no, external_code, medicine_name, qty,
           round(net_sale, 2) as net_sale, round(cost_total, 2) as cost_total, round(profit, 2) as profit
    from public.vw_negative_margin_lines
    order by sale_date desc
    limit 10
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_recommendations
  from (
    select external_code, medicine_name, abc_rotation, monthly_rotation, current_stock,
           coverage_months, suggested_qty, round(estimated_purchase_value, 2) as estimated_purchase_value,
           action, expiration_risk
    from public.vw_purchase_recommendations_latest
    where suggested_qty > 0 or action ilike 'Pedir ya%'
    order by suggested_qty desc, estimated_purchase_value desc nulls last
    limit 15
  ) x;

  return jsonb_build_object(
    'summary', v_summary,
    'monthly_sales', v_monthly,
    'penetration', v_penetration,
    'top_units', v_top_units,
    'top_profit', v_top_profit,
    'negative_margin', v_negative,
    'recommendations', v_recommendations
  );
end;
$$;

grant execute on function public.rpc_dashboard_overview(text) to anon, authenticated;
