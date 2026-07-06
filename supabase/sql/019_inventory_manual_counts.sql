create table if not exists public.inventory_manual_counts (
  id uuid primary key default gen_random_uuid(),
  medicine_id uuid references public.medicines(id),
  external_code integer not null,
  expected_qty numeric(14,4) not null default 0,
  counted_qty numeric(14,4) not null default 0,
  variance_qty numeric(14,4) generated always as (counted_qty - expected_qty) stored,
  note text,
  status text not null default 'pending' check (status in ('pending','applied','voided')),
  counted_by uuid references public.app_users(id),
  counted_at timestamptz not null default now(),
  applied_by uuid references public.app_users(id),
  applied_at timestamptz,
  adjustment_movement_id uuid references public.inventory_movements(id),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists ix_inventory_manual_counts_external_created
on public.inventory_manual_counts(external_code, counted_at desc);

alter table public.inventory_manual_counts enable row level security;

create or replace function public.rpc_inventory_count_search(p_session_token text, p_query text default '', p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 80));
  v_rows jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para conteo de inventario';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows
  from (
    select
      m.id as medicine_id,
      m.external_code,
      m.barcode,
      m.name as medicine_name,
      m.secondary_name,
      m.model,
      m.presentation_name,
      coalesce(vl.stock_qty, 0) as expected_qty,
      coalesce(vl.unit_cost, 0) as unit_cost
    from public.medicines m
    left join public.vw_inventory_live vl on vl.external_code = m.external_code
    where m.active is true
      and (
        v_query = ''
        or m.external_code::text = v_query
        or coalesce(m.barcode, '') ilike '%' || v_query || '%'
        or m.name ilike '%' || v_query || '%'
        or coalesce(m.secondary_name, '') ilike '%' || v_query || '%'
        or coalesce(m.model, '') ilike '%' || v_query || '%'
      )
    order by
      case
        when m.external_code::text = v_query or coalesce(m.barcode, '') = v_query then 0
        when m.name ilike v_query || '%' then 1
        else 2
      end,
      m.name
    limit v_limit
  ) x;

  return v_rows;
end;
$$;

grant execute on function public.rpc_inventory_count_search(text, text, integer) to anon, authenticated;

create or replace function public.rpc_inventory_manual_count_create(
  p_session_token text,
  p_external_code integer,
  p_counted_qty numeric,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_medicine record;
  v_expected numeric;
  v_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para registrar conteos';
  end if;

  if p_external_code is null then
    raise exception 'Debe seleccionar un producto';
  end if;

  if p_counted_qty is null or p_counted_qty < 0 then
    raise exception 'El conteo no puede ser negativo';
  end if;

  if p_counted_qty <> trunc(p_counted_qty) then
    raise exception 'El conteo debe ser entero';
  end if;

  select id, external_code, name, barcode
    into v_medicine
  from public.medicines
  where external_code = p_external_code
    and active is true
  limit 1;

  if v_medicine.id is null then
    raise exception 'Producto activo no encontrado';
  end if;

  select coalesce(stock_qty, 0)
    into v_expected
  from public.vw_inventory_live
  where external_code = p_external_code;

  v_expected := coalesce(v_expected, 0);

  insert into public.inventory_manual_counts(
    medicine_id, external_code, expected_qty, counted_qty, note, counted_by, metadata
  )
  values (
    v_medicine.id,
    p_external_code,
    trunc(v_expected),
    trunc(p_counted_qty),
    nullif(trim(coalesce(p_note, '')), ''),
    v_user_id,
    jsonb_build_object('medicine_name', v_medicine.name, 'barcode', v_medicine.barcode)
  )
  returning id into v_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'INVENTORY_MANUAL_COUNT_CREATE',
    v_user_id,
    jsonb_build_object('count_id', v_id, 'external_code', p_external_code, 'expected_qty', trunc(v_expected), 'counted_qty', trunc(p_counted_qty))
  );

  return (
    select to_jsonb(x)
    from (
      select
        c.id,
        c.external_code,
        m.name as medicine_name,
        c.expected_qty,
        c.counted_qty,
        c.variance_qty,
        c.status,
        c.counted_at,
        u.display_name as counted_by_name,
        c.note
      from public.inventory_manual_counts c
      join public.medicines m on m.id = c.medicine_id
      left join public.app_users u on u.id = c.counted_by
      where c.id = v_id
    ) x
  );
end;
$$;

grant execute on function public.rpc_inventory_manual_count_create(text, integer, numeric, text) to anon, authenticated;

create or replace function public.rpc_inventory_manual_count_apply(p_session_token text, p_count_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_count record;
  v_movement_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Solo admin puede aplicar ajustes';
  end if;

  select c.*, m.name as medicine_name, m.barcode, coalesce(vl.unit_cost, 0) as unit_cost
    into v_count
  from public.inventory_manual_counts c
  join public.medicines m on m.id = c.medicine_id
  left join public.vw_inventory_live vl on vl.external_code = c.external_code
  where c.id = p_count_id
  for update;

  if v_count.id is null then
    raise exception 'Conteo no encontrado';
  end if;

  if v_count.status <> 'pending' then
    raise exception 'Este conteo ya fue procesado';
  end if;

  if coalesce(v_count.variance_qty, 0) <> 0 then
    insert into public.inventory_movements(
      movement_type,
      source_type,
      source_id,
      source_event_key,
      medicine_id,
      external_code,
      barcode,
      qty_delta,
      unit_cost,
      note,
      created_by,
      metadata
    )
    values (
      case when v_count.variance_qty > 0 then 'manual_count_adjust_in' else 'manual_count_adjust_out' end,
      'manual_count',
      v_count.id,
      'manual_count:' || v_count.id::text,
      v_count.medicine_id,
      v_count.external_code,
      v_count.barcode,
      v_count.variance_qty,
      v_count.unit_cost,
      'Ajuste aplicado desde conteo manual',
      v_user_id,
      jsonb_build_object(
        'medicine_name', v_count.medicine_name,
        'expected_qty', v_count.expected_qty,
        'counted_qty', v_count.counted_qty,
        'variance_qty', v_count.variance_qty,
        'count_note', v_count.note
      )
    )
    on conflict (source_event_key) where source_event_key is not null do nothing
    returning id into v_movement_id;
  end if;

  update public.inventory_manual_counts
     set status = 'applied',
         applied_by = v_user_id,
         applied_at = now(),
         adjustment_movement_id = v_movement_id
   where id = v_count.id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'INVENTORY_MANUAL_COUNT_APPLY',
    v_user_id,
    jsonb_build_object('count_id', v_count.id, 'external_code', v_count.external_code, 'variance_qty', v_count.variance_qty, 'movement_id', v_movement_id)
  );

  return (
    select to_jsonb(x)
    from (
      select
        c.id,
        c.external_code,
        m.name as medicine_name,
        c.expected_qty,
        c.counted_qty,
        c.variance_qty,
        c.status,
        c.counted_at,
        c.applied_at,
        u.display_name as counted_by_name,
        au.display_name as applied_by_name,
        c.adjustment_movement_id
      from public.inventory_manual_counts c
      join public.medicines m on m.id = c.medicine_id
      left join public.app_users u on u.id = c.counted_by
      left join public.app_users au on au.id = c.applied_by
      where c.id = v_count.id
    ) x
  );
end;
$$;

grant execute on function public.rpc_inventory_manual_count_apply(text, uuid) to anon, authenticated;

create or replace function public.rpc_inventory_manual_count_list(
  p_session_token text,
  p_status text default null,
  p_limit integer default 40
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_limit integer := greatest(1, least(coalesce(p_limit, 40), 200));
  v_rows jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para consultar conteos';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows
  from (
    select
      c.id,
      c.external_code,
      m.name as medicine_name,
      m.model,
      c.expected_qty,
      c.counted_qty,
      c.variance_qty,
      c.status,
      c.note,
      c.counted_at,
      c.applied_at,
      u.display_name as counted_by_name,
      au.display_name as applied_by_name
    from public.inventory_manual_counts c
    join public.medicines m on m.id = c.medicine_id
    left join public.app_users u on u.id = c.counted_by
    left join public.app_users au on au.id = c.applied_by
    where (p_status is null or p_status = '' or c.status = p_status)
    order by c.counted_at desc
    limit v_limit
  ) x;

  return v_rows;
end;
$$;

grant execute on function public.rpc_inventory_manual_count_list(text, text, integer) to anon, authenticated;
