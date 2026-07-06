-- Pharma import validation queries
-- Run after:
--   001_pharma_core_schema.sql
--   002_load_excel_csv_to_supabase.py

-- =========================================================
-- Expected vs actual summary
-- =========================================================

with actual as (
  select 'medicines_total' as metric, count(*)::numeric as actual_value from public.medicines
  union all select 'medicines_active', count(*)::numeric from public.medicines where active is true
  union all select 'medicines_inactive', count(*)::numeric from public.medicines where active is false
  union all select 'sales_units', coalesce(sum(qty), 0)::numeric from public.sales_items
  union all select 'sales_net', round(coalesce(sum(net_sale), 0)::numeric, 2) from public.sales_items
  union all select 'sales_profit', round(coalesce(sum(profit), 0)::numeric, 2) from public.sales_items
  union all select 'negative_profit_lines', count(*)::numeric from public.sales_items where profit < 0
  union all select 'purchase_rows', count(*)::numeric from public.purchase_items
  union all select 'purchase_total', round(coalesce(sum(line_total), 0)::numeric, 2) from public.purchase_items
  union all select 'inventory_units', round(coalesce(sum(stock_qty), 0)::numeric, 2) from public.inventory_snapshot_items
  union all select 'inventory_value', round(coalesce(sum(stock_value), 0)::numeric, 2) from public.inventory_snapshot_items
  union all select 'consultation_rows', count(*)::numeric from public.consultation_visits
  union all select 'consultation_unique_patients', count(distinct patient_id)::numeric from public.consultation_visits
)
select
  e.metric,
  e.expected_value,
  a.actual_value,
  round(a.actual_value - e.expected_value, 2) as diff,
  case
    when abs(a.actual_value - e.expected_value) <= 0.10 then 'OK'
    else 'REVIEW'
  end as status
from public.vw_pharma_import_expected_totals e
left join actual a using (metric)
order by e.metric;

-- =========================================================
-- Data quality checks
-- =========================================================

-- Medicines without barcode.
select external_code, name, active
from public.medicines
where nullif(trim(coalesce(barcode, '')), '') is null
order by external_code;

-- Duplicate non-empty barcodes.
select barcode, count(*) as rows, array_agg(external_code order by external_code) as medicine_codes
from public.medicines
where nullif(trim(coalesce(barcode, '')), '') is not null
group by barcode
having count(*) > 1
order by rows desc, barcode;

-- Sales lines that did not match a medicine.
select external_code, description_snapshot, count(*) as rows, sum(qty) as units, sum(net_sale) as net_sales
from public.sales_items
where medicine_id is null
group by external_code, description_snapshot
order by rows desc, external_code;

-- Purchase lines that did not match a medicine.
select external_code, description_snapshot, count(*) as rows, sum(qty) as units, sum(line_total) as total
from public.purchase_items
where medicine_id is null
group by external_code, description_snapshot
order by rows desc, external_code;

-- Inventory rows that did not match a medicine.
select external_code, description_snapshot, stock_qty, stock_value
from public.inventory_snapshot_items
where medicine_id is null
order by external_code;

-- Patients with conflicting names.
select external_client_code, count(distinct normalized_name) as names, array_agg(distinct display_name) as display_names
from public.patients
where external_client_code is not null
group by external_client_code
having count(distinct normalized_name) > 1
order by names desc, external_client_code;

-- Negative margin lines.
select *
from public.vw_negative_margin_lines
order by sale_date, external_code;

-- =========================================================
-- Business KPI checks
-- =========================================================

select *
from public.vw_monthly_sales_profit
order by month;

select *
from public.vw_patient_pharma_penetration_monthly
order by month;

select *
from public.vw_purchase_recommendations_latest
where suggested_qty > 0
order by suggested_qty desc, estimated_purchase_value desc nulls last;

select *
from public.vw_inventory_latest
order by stock_value desc nulls last
limit 25;

