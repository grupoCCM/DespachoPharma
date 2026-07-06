-- Pharma core schema for Supabase
-- Generated: 2026-07-01
-- Purpose: create new integration tables in parallel with existing DespachoPharma tables.
-- Safe design: no DROP statements, no changes to existing dispatch/app tables.

create extension if not exists pgcrypto;

-- =========================================================
-- Utility
-- =========================================================

create or replace function public.pharma_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================================================
-- Catalog
-- =========================================================

create table if not exists public.medicines (
  id uuid primary key default gen_random_uuid(),
  external_code integer not null unique,
  name text not null,
  secondary_name text,
  model text,
  group_code integer,
  group_name text,
  subgroup_code integer,
  subgroup_name text,
  brand_code integer,
  brand_name text,
  presentation_code integer,
  presentation_name text,
  min_stock numeric(14,4),
  max_stock numeric(14,4),
  price_1 numeric(14,4),
  price_2 numeric(14,4),
  price_3 numeric(14,4),
  price_4 numeric(14,4),
  active boolean not null default true,
  inventory_item boolean not null default true,
  requires_serial boolean not null default false,
  requires_expiration boolean not null default false,
  barcode text,
  dispatch_days integer,
  last_cost numeric(14,4),
  source_file text,
  source_loaded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_medicines_barcode on public.medicines (barcode);
create index if not exists idx_medicines_active on public.medicines (active);
create index if not exists idx_medicines_subgroup on public.medicines (subgroup_name);

drop trigger if exists trg_medicines_updated_at on public.medicines;
create trigger trg_medicines_updated_at
before update on public.medicines
for each row execute function public.pharma_touch_updated_at();

create table if not exists public.medicine_reference_prices (
  id uuid primary key default gen_random_uuid(),
  medicine_id uuid references public.medicines(id) on delete cascade,
  external_code integer not null,
  reference_price numeric(14,4),
  source_file text,
  loaded_at timestamptz not null default now(),
  unique (external_code, source_file)
);

create index if not exists idx_medicine_reference_prices_medicine
on public.medicine_reference_prices (medicine_id);

create table if not exists public.medicine_reference_price_overrides (
  id uuid primary key default gen_random_uuid(),
  medicine_id uuid references public.medicines(id) on delete cascade,
  external_code integer not null unique,
  reference_price numeric(14,4) not null,
  note text,
  updated_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_medicine_reference_price_overrides_updated_at on public.medicine_reference_price_overrides;
create trigger trg_medicine_reference_price_overrides_updated_at
before update on public.medicine_reference_price_overrides
for each row execute function public.pharma_touch_updated_at();

-- =========================================================
-- Suppliers and purchases
-- =========================================================

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  external_code integer,
  name text not null,
  normalized_name text generated always as (lower(trim(name))) stored,
  source_file text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (external_code),
  unique (normalized_name)
);

drop trigger if exists trg_suppliers_updated_at on public.suppliers;
create trigger trg_suppliers_updated_at
before update on public.suppliers
for each row execute function public.pharma_touch_updated_at();

create table if not exists public.purchase_documents (
  id uuid primary key default gen_random_uuid(),
  external_purchase_no integer,
  voucher_no text,
  purchase_date date not null,
  supplier_id uuid references public.suppliers(id),
  source_file text,
  created_at timestamptz not null default now(),
  unique (external_purchase_no, voucher_no)
);

create index if not exists idx_purchase_documents_date
on public.purchase_documents (purchase_date);

create index if not exists idx_purchase_documents_supplier
on public.purchase_documents (supplier_id);

create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_document_id uuid not null references public.purchase_documents(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  source_row_number integer,
  external_code integer not null,
  description_snapshot text,
  qty numeric(14,4) not null default 0,
  line_total numeric(14,4) not null default 0,
  unit_cost_estimated numeric(14,6) generated always as (
    case when qty <> 0 then line_total / qty else null end
  ) stored,
  source_file text,
  created_at timestamptz not null default now(),
  unique (source_file, source_row_number)
);

alter table public.purchase_items
add column if not exists source_row_number integer;

alter table public.purchase_items
drop constraint if exists purchase_items_purchase_document_id_external_code_description_snapshot_key;

alter table public.purchase_items
drop constraint if exists purchase_items_purchase_document_id_external_code_descripti_key;

create unique index if not exists purchase_items_source_row_key
on public.purchase_items (source_file, source_row_number);

create index if not exists idx_purchase_items_medicine
on public.purchase_items (medicine_id);

create index if not exists idx_purchase_items_external_code
on public.purchase_items (external_code);

-- =========================================================
-- Patients, sales and profit
-- =========================================================

create table if not exists public.patients (
  id uuid primary key default gen_random_uuid(),
  external_client_code integer not null unique,
  display_name text,
  normalized_name text generated always as (lower(trim(coalesce(display_name, '')))) stored,
  source_first_seen text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_patients_updated_at on public.patients;
create trigger trg_patients_updated_at
before update on public.patients
for each row execute function public.pharma_touch_updated_at();

create table if not exists public.sales_documents (
  id uuid primary key default gen_random_uuid(),
  external_sale_no integer not null,
  voucher_no text,
  sale_date date not null,
  patient_id uuid references public.patients(id),
  source_file text,
  created_at timestamptz not null default now(),
  unique (external_sale_no, voucher_no)
);

create index if not exists idx_sales_documents_date
on public.sales_documents (sale_date);

create index if not exists idx_sales_documents_patient
on public.sales_documents (patient_id);

create table if not exists public.sales_items (
  id uuid primary key default gen_random_uuid(),
  sales_document_id uuid not null references public.sales_documents(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  source_row_number integer,
  external_code integer not null,
  description_snapshot text,
  qty numeric(14,4) not null default 0,
  unit_net_price numeric(14,6),
  net_sale numeric(14,4) not null default 0,
  unit_cost numeric(14,6),
  cost_total numeric(14,4) not null default 0,
  profit numeric(14,4) not null default 0,
  profit_on_sale_pct numeric(14,4),
  profit_on_cost_pct numeric(14,4),
  needs_review boolean generated always as (profit < 0) stored,
  source_file text,
  created_at timestamptz not null default now(),
  unique (source_file, source_row_number)
);

alter table public.sales_items
add column if not exists source_row_number integer;

alter table public.sales_items
drop constraint if exists sales_items_sales_document_id_external_code_description_snapshot_qty_net_sale_key;

alter table public.sales_items
drop constraint if exists sales_items_sales_document_id_external_code_description_sna_key;

create unique index if not exists sales_items_source_row_key
on public.sales_items (source_file, source_row_number);

create index if not exists idx_sales_items_medicine
on public.sales_items (medicine_id);

create index if not exists idx_sales_items_external_code
on public.sales_items (external_code);

create index if not exists idx_sales_items_needs_review
on public.sales_items (needs_review);

-- =========================================================
-- Consultations and penetration
-- =========================================================

create table if not exists public.consultation_visits (
  id uuid primary key default gen_random_uuid(),
  source_row_number integer,
  external_article_code integer,
  service_name text,
  external_sale_no integer,
  voucher_no text,
  visit_date date not null,
  patient_id uuid references public.patients(id),
  patient_name_snapshot text,
  source_file text,
  created_at timestamptz not null default now(),
  unique (source_file, source_row_number)
);

alter table public.consultation_visits
add column if not exists source_row_number integer;

alter table public.consultation_visits
drop constraint if exists consultation_visits_external_sale_no_voucher_no_patient_id_key;

create unique index if not exists consultation_visits_source_row_key
on public.consultation_visits (source_file, source_row_number);

create index if not exists idx_consultation_visits_date
on public.consultation_visits (visit_date);

create index if not exists idx_consultation_visits_patient
on public.consultation_visits (patient_id);

-- =========================================================
-- Inventory snapshots and lots
-- =========================================================

create table if not exists public.inventory_snapshots (
  id uuid primary key default gen_random_uuid(),
  snapshot_date date not null,
  source_file text,
  total_units numeric(14,4),
  total_value numeric(14,4),
  created_at timestamptz not null default now(),
  unique (snapshot_date, source_file)
);

create table if not exists public.inventory_snapshot_items (
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references public.inventory_snapshots(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  external_code integer not null,
  description_snapshot text,
  model text,
  presentation text,
  stock_qty numeric(14,4) not null default 0,
  unit_cost numeric(14,6),
  stock_value numeric(14,4),
  detail_raw text,
  created_at timestamptz not null default now(),
  unique (snapshot_id, external_code)
);

create index if not exists idx_inventory_snapshot_items_snapshot
on public.inventory_snapshot_items (snapshot_id);

create index if not exists idx_inventory_snapshot_items_medicine
on public.inventory_snapshot_items (medicine_id);

create table if not exists public.inventory_lots (
  id uuid primary key default gen_random_uuid(),
  inventory_snapshot_item_id uuid references public.inventory_snapshot_items(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  lot_no text,
  expires_at date,
  qty numeric(14,4),
  source_detail text,
  created_at timestamptz not null default now()
);

create index if not exists idx_inventory_lots_medicine
on public.inventory_lots (medicine_id);

create index if not exists idx_inventory_lots_expires_at
on public.inventory_lots (expires_at);

-- =========================================================
-- Rotation, recommended purchases and dashboard goals
-- =========================================================

create table if not exists public.rotation_runs (
  id uuid primary key default gen_random_uuid(),
  cutoff_date date,
  period_start date,
  period_end date,
  months_used integer,
  source_file text,
  created_at timestamptz not null default now(),
  unique (cutoff_date, source_file)
);

create table if not exists public.rotation_metrics (
  id uuid primary key default gen_random_uuid(),
  rotation_run_id uuid not null references public.rotation_runs(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  external_code integer not null,
  abc_rotation text,
  abc_value text,
  monthly_rotation numeric(14,4),
  last_3m_avg numeric(14,4),
  trend text,
  units_11m numeric(14,4),
  net_sales_11m numeric(14,4),
  last_sale_date date,
  current_stock numeric(14,4),
  coverage_months numeric(14,4),
  reorder_point numeric(14,4),
  target_stock numeric(14,4),
  months_with_sales integer,
  june_2026_partial numeric(14,4),
  created_at timestamptz not null default now(),
  unique (rotation_run_id, external_code)
);

create index if not exists idx_rotation_metrics_run
on public.rotation_metrics (rotation_run_id);

create index if not exists idx_rotation_metrics_medicine
on public.rotation_metrics (medicine_id);

create table if not exists public.purchase_recommendations (
  id uuid primary key default gen_random_uuid(),
  rotation_run_id uuid not null references public.rotation_runs(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  external_code integer not null,
  suggested_qty numeric(14,4) not null default 0,
  unit_cost numeric(14,6),
  estimated_purchase_value numeric(14,4),
  action text,
  expiration_risk text,
  nearest_expiration date,
  comment text,
  created_at timestamptz not null default now(),
  unique (rotation_run_id, external_code)
);

create index if not exists idx_purchase_recommendations_run
on public.purchase_recommendations (rotation_run_id);

create index if not exists idx_purchase_recommendations_action
on public.purchase_recommendations (action);

create table if not exists public.sales_goals (
  id uuid primary key default gen_random_uuid(),
  goal_month date not null unique,
  sales_goal numeric(14,4) not null default 0,
  source_file text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_sales_goals_updated_at on public.sales_goals;
create trigger trg_sales_goals_updated_at
before update on public.sales_goals
for each row execute function public.pharma_touch_updated_at();

create table if not exists public.holidays (
  holiday_date date primary key,
  name text,
  source_file text,
  created_at timestamptz not null default now()
);

-- =========================================================
-- Views
-- =========================================================

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

create or replace view public.vw_top_medicines_by_units as
select
  m.external_code,
  coalesce(m.name, si.description_snapshot) as medicine_name,
  sum(si.qty) as units,
  sum(si.net_sale) as net_sales,
  sum(si.profit) as profit
from public.sales_items si
left join public.medicines m on m.id = si.medicine_id
group by m.external_code, coalesce(m.name, si.description_snapshot)
order by units desc;

create or replace view public.vw_top_medicines_by_profit as
select
  m.external_code,
  coalesce(m.name, si.description_snapshot) as medicine_name,
  sum(si.qty) as units,
  sum(si.net_sale) as net_sales,
  sum(si.profit) as profit,
  case when sum(si.net_sale) <> 0 then round((sum(si.profit) / sum(si.net_sale)) * 100, 2) end as margin_pct
from public.sales_items si
left join public.medicines m on m.id = si.medicine_id
group by m.external_code, coalesce(m.name, si.description_snapshot)
order by profit desc;

create or replace view public.vw_negative_margin_lines as
select
  sd.sale_date,
  sd.external_sale_no,
  sd.voucher_no,
  p.external_client_code,
  p.display_name as patient_name,
  si.external_code,
  coalesce(m.name, si.description_snapshot) as medicine_name,
  si.qty,
  si.net_sale,
  si.cost_total,
  si.profit
from public.sales_items si
join public.sales_documents sd on sd.id = si.sales_document_id
left join public.patients p on p.id = sd.patient_id
left join public.medicines m on m.id = si.medicine_id
where si.profit < 0
order by sd.sale_date desc;

create or replace view public.vw_inventory_latest as
with latest as (
  select id
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
)
select
  i.snapshot_id,
  m.external_code,
  coalesce(m.name, i.description_snapshot) as medicine_name,
  i.model,
  i.presentation,
  i.stock_qty,
  i.unit_cost,
  i.stock_value,
  i.detail_raw
from public.inventory_snapshot_items i
join latest l on l.id = i.snapshot_id
left join public.medicines m on m.id = i.medicine_id;

create or replace view public.vw_purchase_recommendations_latest as
with latest as (
  select id
  from public.rotation_runs
  order by cutoff_date desc nulls last, created_at desc
  limit 1
)
select
  pr.rotation_run_id,
  m.external_code,
  coalesce(m.name, rm.external_code::text) as medicine_name,
  rm.abc_rotation,
  rm.monthly_rotation,
  rm.current_stock,
  rm.coverage_months,
  pr.suggested_qty,
  pr.estimated_purchase_value,
  pr.action,
  pr.expiration_risk,
  pr.nearest_expiration,
  pr.comment
from public.purchase_recommendations pr
join latest l on l.id = pr.rotation_run_id
left join public.rotation_metrics rm
  on rm.rotation_run_id = pr.rotation_run_id
 and rm.external_code = pr.external_code
left join public.medicines m on m.id = pr.medicine_id
order by pr.suggested_qty desc, pr.estimated_purchase_value desc nulls last;

create or replace view public.vw_patient_pharma_penetration_monthly as
with consults as (
  select
    date_trunc('month', visit_date)::date as month,
    count(distinct patient_id) as consulted_patients
  from public.consultation_visits
  where patient_id is not null
  group by 1
),
pharma as (
  select
    date_trunc('month', sale_date)::date as month,
    count(distinct patient_id) as pharma_patients
  from public.sales_documents
  where patient_id is not null
  group by 1
),
converted as (
  select
    date_trunc('month', c.visit_date)::date as month,
    count(distinct c.patient_id) as converted_patients
  from public.consultation_visits c
  join public.sales_documents s
    on s.patient_id = c.patient_id
   and date_trunc('month', s.sale_date)::date = date_trunc('month', c.visit_date)::date
  where c.patient_id is not null
  group by 1
)
select
  coalesce(c.month, p.month, cv.month) as month,
  coalesce(c.consulted_patients, 0) as consulted_patients,
  coalesce(p.pharma_patients, 0) as pharma_patients,
  coalesce(cv.converted_patients, 0) as converted_patients,
  case
    when coalesce(c.consulted_patients, 0) > 0
    then round((coalesce(cv.converted_patients, 0)::numeric / c.consulted_patients) * 100, 2)
  end as penetration_pct
from consults c
full join pharma p on p.month = c.month
full join converted cv on cv.month = coalesce(c.month, p.month)
order by month;

create or replace view public.vw_expiration_risk_latest as
select
  il.expires_at,
  il.lot_no,
  il.qty,
  m.external_code,
  m.name as medicine_name,
  case
    when il.expires_at is null then 'unknown'
    when il.expires_at < current_date then 'expired'
    when il.expires_at <= current_date + interval '90 days' then 'expires_90_days'
    when il.expires_at <= current_date + interval '180 days' then 'expires_180_days'
    else 'ok'
  end as expiration_status
from public.inventory_lots il
left join public.medicines m on m.id = il.medicine_id
order by il.expires_at nulls last;

-- =========================================================
-- Validation view with the expected totals from the reviewed files.
-- Load scripts should compare against these figures after import.
-- =========================================================

create or replace view public.vw_pharma_import_expected_totals as
select 'medicines_total' as metric, 100::numeric as expected_value
union all select 'medicines_active', 97
union all select 'medicines_inactive', 3
union all select 'sales_units', 2234
union all select 'sales_net', 58992.07
union all select 'sales_profit', 14973.81
union all select 'negative_profit_lines', 10
union all select 'purchase_rows', 273
union all select 'purchase_total', 54353.54
union all select 'inventory_units', 424
union all select 'inventory_value', 9374.94
union all select 'consultation_rows', 5001
union all select 'consultation_unique_patients', 1811;

-- =========================================================
-- Import control and validation audit
-- =========================================================

create table if not exists public.source_files (
  id uuid primary key default gen_random_uuid(),
  source_type text not null,
  original_filename text not null,
  original_path text,
  sha256 text not null,
  size_bytes bigint,
  modified_at timestamptz,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (source_type, sha256)
);

create index if not exists idx_source_files_type_seen
on public.source_files (source_type, last_seen_at desc);

create table if not exists public.import_batches (
  id uuid primary key default gen_random_uuid(),
  batch_key text not null unique,
  mode text not null check (mode in ('dry-run', 'apply')),
  status text not null check (status in ('started', 'completed', 'failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  source_summary jsonb not null default '{}'::jsonb,
  notes text
);

create table if not exists public.import_batch_files (
  id uuid primary key default gen_random_uuid(),
  batch_key text not null references public.import_batches(batch_key) on delete cascade,
  source_file_id uuid references public.source_files(id),
  source_type text not null,
  sha256 text not null,
  row_count integer,
  min_source_date date,
  max_source_date date,
  duplicate_rows_detected integer not null default 0,
  unique (batch_key, source_type)
);

create table if not exists public.import_validation_issues (
  id uuid primary key default gen_random_uuid(),
  batch_key text not null references public.import_batches(batch_key) on delete cascade,
  severity text not null check (severity in ('info', 'warning', 'error')),
  issue_code text not null,
  source_type text,
  message text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (batch_key, issue_code, source_type, message)
);

create or replace view public.vw_import_batch_latest as
select
  b.batch_key,
  b.mode,
  b.status,
  b.started_at,
  b.finished_at,
  count(distinct i.id) filter (where i.severity = 'error') as errors,
  count(distinct i.id) filter (where i.severity = 'warning') as warnings,
  count(distinct f.id) as files_seen
from public.import_batches b
left join public.import_validation_issues i on i.batch_key = b.batch_key
left join public.import_batch_files f on f.batch_key = b.batch_key
group by b.batch_key, b.mode, b.status, b.started_at, b.finished_at
order by b.started_at desc;

create or replace function public.rpc_import_overview(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_batch_key text;
  v_user_role public.user_role;
  v_latest jsonb;
  v_files jsonb;
  v_issues jsonb;
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
    raise exception 'No autorizado para consultar importaciones';
  end if;

  select batch_key into v_batch_key
  from public.import_batches
  order by started_at desc
  limit 1;

  if v_batch_key is null then
    return jsonb_build_object(
      'latest', null,
      'files', '[]'::jsonb,
      'issues', '[]'::jsonb
    );
  end if;

  select to_jsonb(x) into v_latest
  from (
    select batch_key, mode, status, started_at, finished_at, warnings, errors, files_seen
    from public.vw_import_batch_latest
    where batch_key = v_batch_key
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.source_type), '[]'::jsonb) into v_files
  from (
    select source_type, row_count, min_source_date, max_source_date, duplicate_rows_detected, sha256
    from public.import_batch_files
    where batch_key = v_batch_key
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.severity, x.issue_code), '[]'::jsonb) into v_issues
  from (
    select severity, issue_code, source_type, message, details, created_at
    from public.import_validation_issues
    where batch_key = v_batch_key
  ) x;

  return jsonb_build_object(
    'latest', v_latest,
    'files', v_files,
    'issues', v_issues
  );
end;
$$;

grant execute on function public.rpc_import_overview(text) to anon, authenticated;

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
    m.active,
    coalesce(i.stock_qty, 0) as stock_qty,
    coalesce(i.stock_value, 0) as stock_value,
    coalesce(o.reference_price, lr.reference_price) as reference_price,
    rm.monthly_rotation,
    rm.coverage_months,
    pr.action,
    pr.suggested_qty,
    rm.last_sale_date
  from public.medicines m
  left join public.vw_inventory_latest i on i.external_code = m.external_code
  left join latest_ref lr on lr.external_code = m.external_code
  left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
  left join latest_rotation r on true
  left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
  left join public.purchase_recommendations pr on pr.rotation_run_id = r.id and pr.external_code = m.external_code
  where coalesce(trim(p_query), '') = ''
     or m.external_code::text = trim(p_query)
     or m.name ilike '%' || trim(p_query) || '%'
     or coalesce(m.secondary_name, '') ilike '%' || trim(p_query) || '%'
     or coalesce(m.model, '') ilike '%' || trim(p_query) || '%'
     or coalesce(m.brand_name, '') ilike '%' || trim(p_query) || '%'
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
    active,
    stock_qty,
    reference_price,
    monthly_rotation,
    coverage_months,
    last_sale_date,
    case
      when stock_qty > 0 then 'Disponible'
      when active is false then 'Inactivo'
      else 'Sin existencia'
    end as availability_status,
    case
      when action ilike 'Pedir ya%' then 'Pedir'
      when action is null then 'Sin senal'
      else 'Esperar'
    end as operational_signal
  from base
  order by
    case when stock_qty > 0 then 0 else 1 end,
    medicine_name
  limit greatest(1, least(coalesce(p_limit, 30), 100))
) x;
$$;

grant execute on function public.rpc_public_availability_search(text, integer) to anon, authenticated;

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
    left join public.vw_inventory_latest i on i.external_code = m.external_code
    left join latest_ref lr on lr.external_code = m.external_code
    left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
    left join latest_rotation r on true
    left join public.rotation_metrics rm on rm.rotation_run_id = r.id and rm.external_code = m.external_code
    left join public.purchase_recommendations pr on pr.rotation_run_id = r.id and pr.external_code = m.external_code
    left join purchase_costs pc on pc.external_code = m.external_code
    left join last_purchase lp on lp.external_code = m.external_code
    left join min_purchase mp on mp.external_code = m.external_code
    where coalesce(trim(p_query), '') = ''
       or m.external_code::text = trim(p_query)
       or m.name ilike '%' || trim(p_query) || '%'
       or coalesce(m.secondary_name, '') ilike '%' || trim(p_query) || '%'
       or coalesce(m.model, '') ilike '%' || trim(p_query) || '%'
       or coalesce(m.brand_name, '') ilike '%' || trim(p_query) || '%'
       or coalesce(lp.supplier_name, '') ilike '%' || trim(p_query) || '%'
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

create or replace function public.rpc_reference_price_set(
  p_session_token text,
  p_external_code integer,
  p_reference_price numeric,
  p_note text default null
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
  v_medicine_id uuid;
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
    raise exception 'No autorizado para editar precio de referencia';
  end if;

  if p_reference_price is null or p_reference_price < 0 then
    raise exception 'Precio de referencia invalido';
  end if;

  select id into v_medicine_id
  from public.medicines
  where external_code = p_external_code;

  if v_medicine_id is null then
    raise exception 'Medicamento no encontrado';
  end if;

  insert into public.medicine_reference_price_overrides(
    medicine_id, external_code, reference_price, note, updated_by
  )
  values (v_medicine_id, p_external_code, p_reference_price, p_note, v_user_id)
  on conflict (external_code) do update
    set reference_price = excluded.reference_price,
        note = excluded.note,
        updated_by = excluded.updated_by,
        updated_at = now();

  return jsonb_build_object('ok', true, 'external_code', p_external_code, 'reference_price', p_reference_price);
end;
$$;

grant execute on function public.rpc_reference_price_set(text, integer, numeric, text) to anon, authenticated;

-- =========================================================
-- Row Level Security baseline
-- =========================================================
-- Enable RLS now. No public policies are created here.
-- Access should initially happen through service role scripts or future controlled RPCs.

alter table public.medicines enable row level security;
alter table public.medicine_reference_prices enable row level security;
alter table public.medicine_reference_price_overrides enable row level security;
alter table public.suppliers enable row level security;
alter table public.purchase_documents enable row level security;
alter table public.purchase_items enable row level security;
alter table public.patients enable row level security;
alter table public.sales_documents enable row level security;
alter table public.sales_items enable row level security;
alter table public.consultation_visits enable row level security;
alter table public.inventory_snapshots enable row level security;
alter table public.inventory_snapshot_items enable row level security;
alter table public.inventory_lots enable row level security;
alter table public.rotation_runs enable row level security;
alter table public.rotation_metrics enable row level security;
alter table public.purchase_recommendations enable row level security;
alter table public.sales_goals enable row level security;
alter table public.holidays enable row level security;
alter table public.source_files enable row level security;
alter table public.import_batches enable row level security;
alter table public.import_batch_files enable row level security;
alter table public.import_validation_issues enable row level security;
