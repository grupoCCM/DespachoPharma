-- Administrative workflow for physical-count variances.
--
-- Inventory reconciliation and administrative resolution are intentionally
-- separate. Applying a stock movement never closes the investigation by
-- itself. Count observations and case events remain immutable.

begin;

create table if not exists public.inventory_variance_cases (
  id uuid primary key default gen_random_uuid(),
  count_session_id uuid not null references public.inventory_count_sessions(id) on delete restrict,
  count_item_id uuid not null unique references public.inventory_count_session_items(id) on delete restrict,
  medicine_id uuid not null references public.medicines(id) on delete restrict,
  external_code integer not null,
  -- Historical frozen expectations may be negative when the count itself is
  -- evidence of a legacy inventory defect. Preserve that observation.
  expected_qty_snapshot numeric(14,4) not null,
  first_count_qty numeric(14,4) not null check (first_count_qty >= 0),
  verified_qty numeric(14,4) check (verified_qty is null or verified_qty >= 0),
  confirmed_variance_qty numeric(14,4),
  unit_cost_snapshot numeric(14,6) not null default 0 check (unit_cost_snapshot >= 0),
  exposure_value numeric(14,4) not null default 0 check (exposure_value >= 0),
  stock_adjustment_status text not null default 'pending'
    check (stock_adjustment_status in ('pending','applied','not_required')),
  stock_adjustment_movement_id uuid references public.inventory_movements(id) on delete restrict,
  stock_adjusted_by uuid references public.app_users(id) on delete restrict,
  stock_adjusted_at timestamptz,
  investigation_status text not null default 'pending_verification'
    check (investigation_status in ('pending_verification','open','investigating','partially_resolved','resolved')),
  assigned_to uuid references public.app_users(id) on delete restrict,
  opened_by uuid not null references public.app_users(id) on delete restrict,
  opened_at timestamptz not null default now(),
  verified_by uuid references public.app_users(id) on delete restrict,
  verified_at timestamptz,
  resolved_by uuid references public.app_users(id) on delete restrict,
  resolved_at timestamptz,
  resolution_note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_variance_cases_verified_math_chk check (
    (verified_qty is null and confirmed_variance_qty is null)
    or (verified_qty is not null and confirmed_variance_qty = verified_qty - expected_qty_snapshot)
  ),
  constraint inventory_variance_cases_verifier_chk check (
    verified_by is null or verified_by <> opened_by
  )
);

create index if not exists ix_inventory_variance_cases_session_status
  on public.inventory_variance_cases(count_session_id, investigation_status, external_code);

create index if not exists ix_inventory_variance_cases_opened
  on public.inventory_variance_cases(investigation_status, opened_at desc);

create table if not exists public.inventory_variance_case_events (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.inventory_variance_cases(id) on delete restrict,
  event_type text not null check (event_type in (
    'opened','verified','stock_adjusted','comment','investigation_started',
    'resolution','reopened','legacy_backfill'
  )),
  qty numeric(14,4),
  amount numeric(14,4) check (amount is null or amount >= 0),
  reason_code text,
  note text,
  inventory_movement_id uuid references public.inventory_movements(id) on delete restrict,
  idempotency_key text unique,
  created_by uuid not null references public.app_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists ix_inventory_variance_case_events_case_created
  on public.inventory_variance_case_events(case_id, created_at, id);

create table if not exists public.inventory_variance_resolutions (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.inventory_variance_cases(id) on delete restrict,
  resolution_type text not null check (resolution_type in (
    'found_recovered','reimbursement','authorized_loss','document_error',
    'responsibility_assigned','supplier_return','other'
  )),
  qty_resolved numeric(14,4) not null check (qty_resolved > 0),
  amount_recovered numeric(14,4) not null default 0 check (amount_recovered >= 0),
  note text not null check (length(trim(note)) >= 3),
  inventory_movement_id uuid references public.inventory_movements(id) on delete restrict,
  idempotency_key text not null unique,
  created_by uuid not null references public.app_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists ix_inventory_variance_resolutions_case_created
  on public.inventory_variance_resolutions(case_id, created_at, id);

alter table public.inventory_variance_cases enable row level security;
alter table public.inventory_variance_case_events enable row level security;
alter table public.inventory_variance_resolutions enable row level security;

drop trigger if exists trg_inventory_variance_cases_updated_at on public.inventory_variance_cases;
create trigger trg_inventory_variance_cases_updated_at
before update on public.inventory_variance_cases
for each row execute function public.pharma_touch_updated_at();

create or replace function public.inventory_variance_capture_first_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_case_id uuid;
begin
  if new.counted_qty is null or coalesce(new.variance_qty, 0) = 0 then
    return new;
  end if;

  insert into public.inventory_variance_cases(
    count_session_id, count_item_id, medicine_id, external_code,
    expected_qty_snapshot, first_count_qty, unit_cost_snapshot,
    exposure_value, opened_by, metadata
  ) values (
    new.session_id, new.id, new.medicine_id, new.external_code,
    new.expected_qty, new.counted_qty, coalesce(new.expected_unit_cost, 0),
    abs(new.variance_qty) * coalesce(new.expected_unit_cost, 0),
    new.counted_by,
    jsonb_build_object('captured_from', 'count_item_first_variance')
  )
  on conflict (count_item_id) do nothing
  returning id into v_case_id;

  if v_case_id is not null then
    insert into public.inventory_variance_case_events(
      case_id, event_type, qty, note, idempotency_key, created_by, metadata
    ) values (
      v_case_id, 'opened', new.counted_qty, 'Diferencia detectada en conteo fisico',
      'variance_case_open:' || new.id::text, new.counted_by,
      jsonb_build_object('expected_qty', new.expected_qty, 'first_count_qty', new.counted_qty)
    ) on conflict (idempotency_key) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_inventory_variance_capture_first_count on public.inventory_count_session_items;
create trigger trg_inventory_variance_capture_first_count
after insert or update of counted_qty on public.inventory_count_session_items
for each row execute function public.inventory_variance_capture_first_count();

-- Backfill without changing stock or count evidence. Historical cases remain
-- visible unless their documented reason proves a data correction rather than
-- an unexplained physical loss.
with source_rows as (
  select
    i.*,
    s.started_by,
    s.started_at,
    case
      when i.external_code = 750 and s.started_at::date = date '2026-10-20' then 24::numeric
      else i.counted_qty
    end as inferred_verified_qty,
    coalesce((
      select sum(im.qty_delta)
      from public.inventory_movements im
      where im.source_item_id = i.id
        and im.source_type in ('count_session','inventory_admin_correction','inventory_reclass')
        and im.movement_type in (
          'manual_count_adjust_in','manual_count_adjust_out','manual_count_recount_in',
          'manual_count_recount_out','reclass_in','reclass_out'
        )
    ), 0) as corrective_qty,
    coalesce((
      select bool_or(im.metadata ->> 'resolution_reason' in (
        'compra_historica_duplicada','crossed_product_expiry_reclassification',
        'movimiento_de_vencimiento_asignado_a_producto_incorrecto'
      ))
      from public.inventory_movements im
      where im.source_item_id = i.id
    ), false)
      or (s.started_at::date = date '2026-10-20' and i.external_code in (730, 737))
      as documented_data_correction,
    (coalesce(i.condition_status, 'ok') <> 'ok') as condition_only_resolution
  from public.inventory_count_session_items i
  join public.inventory_count_sessions s on s.id = i.session_id
  where s.status <> 'cancelled'
    and i.counted_qty is not null
    and coalesce(i.variance_qty, 0) <> 0
), inserted as (
  insert into public.inventory_variance_cases(
    count_session_id, count_item_id, medicine_id, external_code,
    expected_qty_snapshot, first_count_qty, verified_qty,
    confirmed_variance_qty, unit_cost_snapshot, exposure_value,
    stock_adjustment_status, investigation_status, opened_by, opened_at,
    verified_by, verified_at, resolved_by, resolved_at, resolution_note, metadata
  )
  select
    sr.session_id, sr.id, sr.medicine_id, sr.external_code,
    sr.expected_qty, sr.counted_qty, sr.inferred_verified_qty,
    sr.inferred_verified_qty - sr.expected_qty,
    coalesce(sr.expected_unit_cost, 0),
    abs(sr.inferred_verified_qty - sr.expected_qty) * coalesce(sr.expected_unit_cost, 0),
    case
      when sr.inferred_verified_qty = sr.expected_qty then 'not_required'
      when sr.condition_only_resolution or sr.documented_data_correction then 'not_required'
      when sr.corrective_qty = sr.inferred_verified_qty - sr.expected_qty then 'applied'
      else 'pending'
    end,
    case
      when sr.inferred_verified_qty = sr.expected_qty then 'resolved'
      when sr.documented_data_correction or sr.condition_only_resolution then 'resolved'
      else 'open'
    end,
    coalesce(sr.counted_by, sr.started_by), coalesce(sr.counted_at, sr.started_at),
    null, coalesce(sr.counted_at, sr.started_at),
    case when sr.documented_data_correction or sr.condition_only_resolution then sr.started_by else null end,
    case when sr.documented_data_correction or sr.condition_only_resolution then now() else null end,
    case
      when sr.condition_only_resolution then 'Hallazgo de condicion; no representa diferencia patrimonial de unidades'
      when sr.documented_data_correction then 'Correccion documental historica respaldada por movimiento auditado'
      else null
    end,
    jsonb_build_object(
      'legacy_backfill', true,
      'corrective_qty', sr.corrective_qty,
      'documented_data_correction', sr.documented_data_correction,
      'condition_only_resolution', sr.condition_only_resolution,
      'verification_source', case when sr.external_code = 750 and sr.started_at::date = date '2026-10-20' then 'verified_recount_migration_091' else 'legacy_count_observation' end
    )
  from source_rows sr
  on conflict (count_item_id) do nothing
  returning id, opened_by, first_count_qty
)
insert into public.inventory_variance_case_events(
  case_id, event_type, qty, note, idempotency_key, created_by, metadata
)
select
  id, 'legacy_backfill', first_count_qty,
  'Caso creado desde diferencia historica sin alterar inventario',
  'variance_case_backfill:' || id::text, opened_by,
  jsonb_build_object('migration', '093_inventory_variance_case_workflow.sql')
from inserted
on conflict (idempotency_key) do nothing;

create or replace function public.rpc_inventory_variance_sessions(
  p_session_token text,
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede consultar expedientes de diferencias'; end if;

  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc), '[]'::jsonb)
    from (
      select
        s.id, s.title, s.status, s.started_at, s.closed_at,
        count(c.id) as case_count,
        count(c.id) filter (where c.investigation_status <> 'resolved') as open_case_count
      from public.inventory_count_sessions s
      join public.inventory_variance_cases c on c.count_session_id = s.id
      group by s.id
      order by s.started_at desc
      limit greatest(1, least(coalesce(p_limit, 20), 100))
    ) x
  );
end;
$$;

create or replace function public.rpc_inventory_variance_verification_queue(
  p_session_token text,
  p_session_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_session_id uuid := p_session_id;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role not in ('admin','dispatch','cashier') then raise exception 'Rol no autorizado para verificar conteos'; end if;

  if v_session_id is null then
    select id into v_session_id
    from public.inventory_count_sessions
    where status = 'open'
    order by started_at desc
    limit 1;
  end if;

  if v_session_id is null then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.external_code), '[]'::jsonb)
    from (
      select
        c.id as case_id,
        c.count_session_id,
        c.external_code,
        m.name as medicine_name,
        m.secondary_name,
        m.model,
        m.barcode,
        u.display_name as first_counted_by_name,
        c.opened_at
      from public.inventory_variance_cases c
      join public.inventory_count_session_items i on i.id = c.count_item_id
      join public.medicines m on m.id = c.medicine_id
      left join public.app_users u on u.id = i.counted_by
      where c.count_session_id = v_session_id
        and c.investigation_status = 'pending_verification'
        and i.counted_by <> v_user_id
    ) x
  );
end;
$$;

create or replace function public.rpc_inventory_variance_board(
  p_session_token text,
  p_session_id uuid default null,
  p_query text default '',
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_session_id uuid := p_session_id;
  v_query text := trim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede consultar expedientes de diferencias'; end if;

  if v_session_id is null then
    select s.id into v_session_id
    from public.inventory_count_sessions s
    join public.inventory_variance_cases c on c.count_session_id = s.id
    where s.status <> 'cancelled'
    order by s.started_at desc
    limit 1;
  end if;

  if v_session_id is null then
    return jsonb_build_object('session', null, 'summary', '{}'::jsonb, 'rows', '[]'::jsonb);
  end if;

  return (
    with resolution_totals as (
      select
        r.case_id,
        coalesce(sum(r.qty_resolved), 0) as resolved_qty,
        coalesce(sum(r.amount_recovered), 0) as recovered_amount
      from public.inventory_variance_resolutions r
      group by r.case_id
    ), base as (
      select
        c.id as case_id,
        c.count_session_id as session_id,
        c.count_item_id,
        c.external_code,
        m.name as medicine_name,
        m.secondary_name,
        m.model,
        m.barcode,
        c.expected_qty_snapshot as expected_qty,
        c.first_count_qty as counted_qty,
        c.first_count_qty,
        c.verified_qty,
        coalesce(c.confirmed_variance_qty, c.first_count_qty - c.expected_qty_snapshot) as variance_qty,
        c.unit_cost_snapshot as unit_cost,
        c.exposure_value as variance_value,
        i.status as count_item_status,
        coalesce(i.condition_status, 'ok') as condition_status,
        coalesce(i.condition_qty, 0) as condition_qty,
        i.condition_note,
        c.stock_adjustment_status,
        c.stock_adjusted_at,
        sa.display_name as stock_adjusted_by_name,
        c.investigation_status,
        c.opened_at,
        ou.display_name as opened_by_name,
        c.verified_at,
        vu.display_name as verified_by_name,
        c.resolved_at,
        ru.display_name as resolved_by_name,
        c.resolution_note,
        coalesce(rt.resolved_qty, 0) as resolved_qty,
        greatest(abs(coalesce(c.confirmed_variance_qty, c.first_count_qty - c.expected_qty_snapshot)) - coalesce(rt.resolved_qty, 0), 0) as pending_resolution_qty,
        coalesce(rt.recovered_amount, 0) as recovered_amount,
        c.metadata,
        (c.investigation_status = 'resolved') as is_resolved,
        case c.investigation_status
          when 'pending_verification' then 'Pendiente de verificacion'
          when 'open' then 'Investigacion abierta'
          when 'investigating' then 'En investigacion'
          when 'partially_resolved' then 'Resolucion parcial'
          when 'resolved' then 'Resuelto administrativamente'
        end as resolution_status,
        case
          when c.investigation_status = 'pending_verification' then 'Realizar segundo conteo independiente'
          when c.stock_adjustment_status = 'pending' then 'Aplicar diferencia confirmada al inventario'
          when c.investigation_status in ('open','investigating','partially_resolved') then 'Documentar investigacion o resolucion'
          else 'Caso cerrado con trazabilidad'
        end as next_step
      from public.inventory_variance_cases c
      join public.inventory_count_session_items i on i.id = c.count_item_id
      join public.medicines m on m.id = c.medicine_id
      left join public.app_users ou on ou.id = c.opened_by
      left join public.app_users vu on vu.id = c.verified_by
      left join public.app_users sa on sa.id = c.stock_adjusted_by
      left join public.app_users ru on ru.id = c.resolved_by
      left join resolution_totals rt on rt.case_id = c.id
      where c.count_session_id = v_session_id
        and (
          v_query = ''
          or c.external_code::text = v_query
          or coalesce(m.barcode, '') ilike '%' || v_query || '%'
          or coalesce(m.name, '') ilike '%' || v_query || '%'
          or coalesce(m.secondary_name, '') ilike '%' || v_query || '%'
          or coalesce(m.model, '') ilike '%' || v_query || '%'
        )
    ), limited as (
      select * from base
      order by
        case investigation_status
          when 'pending_verification' then 0
          when 'open' then 1
          when 'investigating' then 2
          when 'partially_resolved' then 3
          else 4
        end,
        case when variance_qty < 0 then 0 else 1 end,
        abs(variance_qty) desc,
        medicine_name
      limit v_limit
    )
    select jsonb_build_object(
      'session', public.inventory_count_session_payload(v_session_id),
      'summary', jsonb_build_object(
        'resolution_items', count(*),
        'open_items', count(*) filter (where investigation_status <> 'resolved'),
        'resolved_items', count(*) filter (where investigation_status = 'resolved'),
        'pending_verification_items', count(*) filter (where investigation_status = 'pending_verification'),
        'stock_pending_items', count(*) filter (where stock_adjustment_status = 'pending' and verified_qty is not null),
        'shortage_items', count(*) filter (where variance_qty < 0),
        'surplus_items', count(*) filter (where variance_qty > 0),
        'open_shortage_qty', abs(coalesce(sum(variance_qty) filter (where variance_qty < 0 and investigation_status <> 'resolved'), 0)),
        'open_surplus_qty', coalesce(sum(variance_qty) filter (where variance_qty > 0 and investigation_status <> 'resolved'), 0),
        'net_variance_qty', coalesce(sum(variance_qty) filter (where investigation_status <> 'resolved'), 0),
        'variance_abs_value', coalesce(sum(abs(variance_value)) filter (where investigation_status <> 'resolved'), 0),
        'shortage_value', abs(coalesce(sum(variance_value) filter (where variance_qty < 0 and investigation_status <> 'resolved'), 0)),
        'surplus_value', coalesce(sum(variance_value) filter (where variance_qty > 0 and investigation_status <> 'resolved'), 0)
      ),
      'rows', coalesce((select jsonb_agg(to_jsonb(limited)) from limited), '[]'::jsonb)
    )
    from base
  );
end;
$$;

create or replace function public.rpc_inventory_variance_verify(
  p_session_token text,
  p_case_id uuid,
  p_verified_qty numeric,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_case record;
  v_variance numeric;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role not in ('admin','dispatch','cashier') then raise exception 'Rol no autorizado para verificar conteos'; end if;
  if p_verified_qty is null or p_verified_qty < 0 or p_verified_qty <> trunc(p_verified_qty) then
    raise exception 'La cantidad verificada debe ser un entero mayor o igual a cero';
  end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Describe brevemente la verificacion realizada'; end if;

  select c.*, i.counted_by, s.status as session_status
    into v_case
  from public.inventory_variance_cases c
  join public.inventory_count_session_items i on i.id = c.count_item_id
  join public.inventory_count_sessions s on s.id = c.count_session_id
  where c.id = p_case_id
  for update of c;

  if v_case.id is null then raise exception 'Expediente de diferencia no encontrado'; end if;
  if v_case.verified_qty is not null then raise exception 'Este expediente ya fue verificado'; end if;
  if v_case.counted_by = v_user_id then raise exception 'El segundo conteo debe realizarlo otro usuario'; end if;
  if v_case.session_status = 'cancelled' then raise exception 'No se puede verificar un conteo cancelado'; end if;

  v_variance := p_verified_qty - v_case.expected_qty_snapshot;

  update public.inventory_variance_cases
  set verified_qty = p_verified_qty,
      confirmed_variance_qty = v_variance,
      exposure_value = abs(v_variance) * unit_cost_snapshot,
      verified_by = v_user_id,
      verified_at = now(),
      stock_adjustment_status = case when v_variance = 0 then 'not_required' else 'pending' end,
      investigation_status = case when v_variance = 0 then 'resolved' else 'open' end,
      resolved_by = case when v_variance = 0 then v_user_id else null end,
      resolved_at = case when v_variance = 0 then now() else null end,
      resolution_note = case when v_variance = 0 then 'Segundo conteo sin diferencia' else null end
  where id = p_case_id;

  insert into public.inventory_variance_case_events(
    case_id, event_type, qty, note, idempotency_key, created_by,
    metadata
  ) values (
    p_case_id, 'verified', p_verified_qty, trim(p_note),
    'variance_case_verify:' || p_case_id::text, v_user_id,
    jsonb_build_object('expected_qty', v_case.expected_qty_snapshot, 'confirmed_variance_qty', v_variance)
  );

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_ITEM_SAVE', v_user_id, jsonb_build_object('audit_action', 'variance_case_verify', 'case_id', p_case_id, 'verified_qty', p_verified_qty, 'confirmed_variance_qty', v_variance));

  return (select to_jsonb(c) from public.inventory_variance_cases c where c.id = p_case_id);
end;
$$;

create or replace function public.rpc_inventory_variance_apply_stock(
  p_session_token text,
  p_case_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_case record;
  v_movement_id uuid;
  v_live_qty numeric;
  v_restricted_qty numeric;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede aplicar diferencias al inventario'; end if;

  select c.*, m.barcode, m.name as medicine_name
    into v_case
  from public.inventory_variance_cases c
  join public.medicines m on m.id = c.medicine_id
  where c.id = p_case_id
  for update of c;

  if v_case.id is null then raise exception 'Expediente de diferencia no encontrado'; end if;
  if v_case.verified_qty is null then raise exception 'La diferencia requiere un segundo conteo antes de ajustar'; end if;
  if v_case.stock_adjustment_status <> 'pending' then raise exception 'El ajuste de inventario ya fue procesado'; end if;
  if coalesce(v_case.confirmed_variance_qty, 0) = 0 then raise exception 'No existe diferencia confirmada para aplicar'; end if;

  perform pg_advisory_xact_lock(93093, v_case.external_code);

  select
    coalesce(physical_qty, 0),
    coalesce(reserved_qty, 0) + coalesce(expired_qty, 0) +
      coalesce(quarantine_qty, 0) + coalesce(not_sellable_qty, 0)
    into v_live_qty, v_restricted_qty
  from public.vw_product_stock_state
  where external_code = v_case.external_code;

  if coalesce(v_live_qty, 0) + v_case.confirmed_variance_qty < 0 then
    raise exception 'El ajuste dejaria inventario negativo. Actualiza y revisa el producto.';
  end if;

  if v_case.confirmed_variance_qty < 0
     and coalesce(v_live_qty, 0) + v_case.confirmed_variance_qty < coalesce(v_restricted_qty, 0) then
    raise exception 'El faltante compromete unidades reservadas o no vendibles. Concilia primero esos estados.';
  end if;

  insert into public.inventory_movements(
    movement_type, source_type, source_id, source_item_id, source_event_key,
    medicine_id, external_code, barcode, qty_delta, unit_cost, note, created_by, metadata
  ) values (
    case when v_case.confirmed_variance_qty > 0 then 'variance_case_adjust_in' else 'variance_case_adjust_out' end,
    'inventory_variance_case', v_case.id, v_case.count_item_id,
    'variance_case_stock:' || v_case.id::text,
    v_case.medicine_id, v_case.external_code, v_case.barcode,
    v_case.confirmed_variance_qty, v_case.unit_cost_snapshot,
    'Ajuste por diferencia confirmada de conteo fisico', v_user_id,
    jsonb_build_object(
      'case_id', v_case.id,
      'expected_qty', v_case.expected_qty_snapshot,
      'first_count_qty', v_case.first_count_qty,
      'verified_qty', v_case.verified_qty,
      'confirmed_variance_qty', v_case.confirmed_variance_qty
    )
  )
  on conflict (source_event_key) where source_event_key is not null do nothing
  returning id into v_movement_id;

  if v_movement_id is null then
    select id into v_movement_id from public.inventory_movements
    where source_event_key = 'variance_case_stock:' || v_case.id::text;
  end if;

  update public.inventory_variance_cases
  set stock_adjustment_status = 'applied', stock_adjustment_movement_id = v_movement_id,
      stock_adjusted_by = v_user_id, stock_adjusted_at = now()
  where id = p_case_id;

  update public.inventory_count_session_items
  set status = 'applied', applied_by = v_user_id, applied_at = now(), adjustment_movement_id = v_movement_id
  where id = v_case.count_item_id and status <> 'applied';

  insert into public.inventory_variance_case_events(
    case_id, event_type, qty, note, inventory_movement_id, idempotency_key, created_by
  ) values (
    p_case_id, 'stock_adjusted', v_case.confirmed_variance_qty,
    'Inventario conciliado con el segundo conteo', v_movement_id,
    'variance_case_stock_event:' || p_case_id::text, v_user_id
  ) on conflict (idempotency_key) do nothing;

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_ITEM_APPLY', v_user_id, jsonb_build_object('audit_action', 'variance_case_stock_apply', 'case_id', p_case_id, 'movement_id', v_movement_id, 'qty_delta', v_case.confirmed_variance_qty));

  return (select to_jsonb(c) from public.inventory_variance_cases c where c.id = p_case_id);
end;
$$;

-- Preserve the legacy RPC contract but prevent bypassing independent
-- verification. Existing clients receive the case payload after the safe apply.
create or replace function public.rpc_inventory_count_session_item_apply(
  p_session_token text,
  p_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_case_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede aplicar ajustes'; end if;

  select id into v_case_id
  from public.inventory_variance_cases
  where count_item_id = p_item_id;

  if v_case_id is null then
    raise exception 'La diferencia no tiene expediente. Guarda nuevamente el conteo antes de aplicar.';
  end if;

  return public.rpc_inventory_variance_apply_stock(p_session_token, v_case_id);
end;
$$;

create or replace function public.rpc_inventory_variance_add_event(
  p_session_token text,
  p_case_id uuid,
  p_note text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_event_id uuid;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede documentar la investigacion'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Escribe el seguimiento realizado'; end if;
  if not exists (select 1 from public.inventory_variance_cases where id = p_case_id) then raise exception 'Expediente no encontrado'; end if;

  insert into public.inventory_variance_case_events(case_id, event_type, note, idempotency_key, created_by)
  values (p_case_id, 'comment', trim(p_note), nullif(trim(p_idempotency_key), ''), v_user_id)
  on conflict (idempotency_key) do nothing
  returning id into v_event_id;

  update public.inventory_variance_cases
  set investigation_status = case when investigation_status = 'open' then 'investigating' else investigation_status end
  where id = p_case_id and investigation_status <> 'resolved';

  return jsonb_build_object('event_id', v_event_id, 'case_id', p_case_id);
end;
$$;

create or replace function public.rpc_inventory_variance_resolve(
  p_session_token text,
  p_case_id uuid,
  p_resolution_type text,
  p_qty_resolved numeric,
  p_amount_recovered numeric,
  p_note text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_case record;
  v_already_resolved numeric;
  v_pending numeric;
  v_movement_id uuid;
  v_key text := nullif(trim(p_idempotency_key), '');
  v_existing_case_id uuid;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede resolver expedientes de diferencias'; end if;
  if p_resolution_type not in ('found_recovered','reimbursement','authorized_loss','document_error','responsibility_assigned','supplier_return','other') then raise exception 'Tipo de resolucion invalido'; end if;
  if p_qty_resolved is null or p_qty_resolved <= 0 or p_qty_resolved <> trunc(p_qty_resolved) then raise exception 'La cantidad resuelta debe ser un entero mayor que cero'; end if;
  if coalesce(p_amount_recovered, 0) < 0 then raise exception 'El monto recuperado no puede ser negativo'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Describe la resolucion'; end if;
  if v_key is null then raise exception 'Falta identificador de operacion'; end if;

  select case_id into v_existing_case_id
  from public.inventory_variance_resolutions
  where idempotency_key = v_key;

  if v_existing_case_id is not null then
    select greatest(
      abs(c.confirmed_variance_qty) - coalesce((
        select sum(r.qty_resolved) from public.inventory_variance_resolutions r where r.case_id = c.id
      ), 0),
      0
    ) into v_pending
    from public.inventory_variance_cases c
    where c.id = v_existing_case_id;

    return (
      select to_jsonb(c) || jsonb_build_object('pending_resolution_qty', v_pending, 'idempotent_replay', true)
      from public.inventory_variance_cases c
      where c.id = v_existing_case_id
    );
  end if;

  select c.*, m.barcode into v_case
  from public.inventory_variance_cases c
  join public.medicines m on m.id = c.medicine_id
  where c.id = p_case_id
  for update of c;

  if v_case.id is null then raise exception 'Expediente no encontrado'; end if;
  if v_case.verified_qty is null then raise exception 'Verifica primero el segundo conteo'; end if;
  if v_case.stock_adjustment_status = 'pending' then raise exception 'Primero aplica la diferencia confirmada al inventario'; end if;
  if v_case.investigation_status = 'resolved' then raise exception 'Este expediente ya esta resuelto'; end if;

  select coalesce(sum(qty_resolved), 0) into v_already_resolved
  from public.inventory_variance_resolutions where case_id = p_case_id;
  v_pending := abs(v_case.confirmed_variance_qty) - v_already_resolved;

  if p_qty_resolved > v_pending then raise exception 'La cantidad excede las unidades pendientes del expediente'; end if;
  if p_resolution_type = 'found_recovered' and v_case.confirmed_variance_qty >= 0 then
    raise exception 'La recuperacion fisica solo aplica a faltantes';
  end if;

  if p_resolution_type = 'found_recovered' then
    perform pg_advisory_xact_lock(93093, v_case.external_code);
    insert into public.inventory_movements(
      movement_type, source_type, source_id, source_item_id, source_event_key,
      medicine_id, external_code, barcode, qty_delta, unit_cost, note, created_by, metadata
    ) values (
      'variance_case_recovery_in', 'inventory_variance_case', v_case.id, v_case.count_item_id,
      'variance_case_recovery:' || v_key,
      v_case.medicine_id, v_case.external_code, v_case.barcode, p_qty_resolved,
      v_case.unit_cost_snapshot, 'Producto recuperado durante investigacion de diferencia',
      v_user_id, jsonb_build_object('case_id', v_case.id, 'resolution_type', p_resolution_type)
    ) returning id into v_movement_id;
  end if;

  insert into public.inventory_variance_resolutions(
    case_id, resolution_type, qty_resolved, amount_recovered, note,
    inventory_movement_id, idempotency_key, created_by
  ) values (
    p_case_id, p_resolution_type, p_qty_resolved, coalesce(p_amount_recovered, 0),
    trim(p_note), v_movement_id, v_key, v_user_id
  );

  insert into public.inventory_variance_case_events(
    case_id, event_type, qty, amount, reason_code, note,
    inventory_movement_id, idempotency_key, created_by
  ) values (
    p_case_id, 'resolution', p_qty_resolved, coalesce(p_amount_recovered, 0),
    p_resolution_type, trim(p_note), v_movement_id,
    'variance_case_resolution_event:' || v_key, v_user_id
  );

  v_pending := v_pending - p_qty_resolved;
  update public.inventory_variance_cases
  set investigation_status = case when v_pending = 0 then 'resolved' else 'partially_resolved' end,
      resolved_by = case when v_pending = 0 then v_user_id else null end,
      resolved_at = case when v_pending = 0 then now() else null end,
      resolution_note = case when v_pending = 0 then trim(p_note) else resolution_note end
  where id = p_case_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_ITEM_APPLY', v_user_id, jsonb_build_object('audit_action', 'variance_case_resolve', 'case_id', p_case_id, 'resolution_type', p_resolution_type, 'qty_resolved', p_qty_resolved, 'remaining_qty', v_pending, 'movement_id', v_movement_id));

  return (select to_jsonb(c) || jsonb_build_object('pending_resolution_qty', v_pending) from public.inventory_variance_cases c where c.id = p_case_id);
end;
$$;

revoke all on public.inventory_variance_cases from anon, authenticated;
revoke all on public.inventory_variance_case_events from anon, authenticated;
revoke all on public.inventory_variance_resolutions from anon, authenticated;

revoke execute on function public.rpc_inventory_variance_sessions(text, integer) from public;
revoke execute on function public.rpc_inventory_variance_verification_queue(text, uuid) from public;
revoke execute on function public.rpc_inventory_variance_board(text, uuid, text, integer) from public;
revoke execute on function public.rpc_inventory_variance_verify(text, uuid, numeric, text) from public;
revoke execute on function public.rpc_inventory_variance_apply_stock(text, uuid) from public;
revoke execute on function public.rpc_inventory_variance_add_event(text, uuid, text, text) from public;
revoke execute on function public.rpc_inventory_variance_resolve(text, uuid, text, numeric, numeric, text, text) from public;

grant execute on function public.rpc_inventory_variance_sessions(text, integer) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_verification_queue(text, uuid) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_board(text, uuid, text, integer) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_verify(text, uuid, numeric, text) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_apply_stock(text, uuid) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_add_event(text, uuid, text, text) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_resolve(text, uuid, text, numeric, numeric, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

commit;

-- Rollback is logical: disable the UI/RPCs, preserve cases and events, and
-- reverse inventory movements with new audited movements. Never delete them.
