do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_COUNT_SESSION_CREATE';
exception when duplicate_object then null;
end $$;

do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_COUNT_ITEM_SAVE';
exception when duplicate_object then null;
end $$;

do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_COUNT_ITEM_APPLY';
exception when duplicate_object then null;
end $$;

create table if not exists public.inventory_count_sessions (
  id uuid primary key default gen_random_uuid(),
  title text,
  scope text not null default 'all_active' check (scope in ('all_active','active_with_stock','variance_only')),
  status text not null default 'open' check (status in ('open','closed','cancelled')),
  started_by uuid references public.app_users(id),
  started_at timestamptz not null default now(),
  closed_by uuid references public.app_users(id),
  closed_at timestamptz,
  note text,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.inventory_count_session_items (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.inventory_count_sessions(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  external_code integer not null,
  expected_qty numeric(14,4) not null default 0,
  counted_qty numeric(14,4),
  variance_qty numeric(14,4) generated always as (counted_qty - expected_qty) stored,
  status text not null default 'pending' check (status in ('pending','counted','applied')),
  counted_by uuid references public.app_users(id),
  counted_at timestamptz,
  applied_by uuid references public.app_users(id),
  applied_at timestamptz,
  adjustment_movement_id uuid references public.inventory_movements(id),
  note text,
  metadata jsonb not null default '{}'::jsonb,
  unique(session_id, external_code)
);

create index if not exists ix_inventory_count_session_items_status
on public.inventory_count_session_items(session_id, status, external_code);

alter table public.inventory_count_sessions enable row level security;
alter table public.inventory_count_session_items enable row level security;

create or replace function public.inventory_count_session_payload(p_session_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
select to_jsonb(x)
from (
  select
    s.id,
    s.title,
    s.scope,
    s.status,
    s.started_at,
    s.closed_at,
    u.display_name as started_by_name,
    count(i.id) as total_items,
    count(i.id) filter (where i.status = 'pending') as pending_items,
    count(i.id) filter (where i.status in ('counted','applied')) as counted_items,
    count(i.id) filter (where i.status = 'applied') as applied_items,
    max(i.counted_at) as last_counted_at,
    max(i.external_code) filter (where i.counted_at = (select max(i2.counted_at) from public.inventory_count_session_items i2 where i2.session_id = s.id)) as last_counted_code
  from public.inventory_count_sessions s
  left join public.inventory_count_session_items i on i.session_id = s.id
  left join public.app_users u on u.id = s.started_by
  where s.id = p_session_id
  group by s.id, u.display_name
) x;
$$;

create or replace function public.rpc_inventory_count_session_create(
  p_session_token text,
  p_title text default null,
  p_scope text default 'all_active'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_session_id uuid;
  v_scope text := coalesce(nullif(trim(p_scope), ''), 'all_active');
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para crear conteos';
  end if;

  if v_scope not in ('all_active','active_with_stock') then
    v_scope := 'all_active';
  end if;

  insert into public.inventory_count_sessions(title, scope, started_by, note)
  values (
    coalesce(nullif(trim(p_title), ''), 'Conteo fisico ' || to_char(now(), 'YYYY-MM-DD HH24:MI')),
    v_scope,
    v_user_id,
    'Sesion de conteo creada desde Inventario'
  )
  returning id into v_session_id;

  insert into public.inventory_count_session_items(
    session_id, medicine_id, external_code, expected_qty, metadata
  )
  select
    v_session_id,
    m.id,
    m.external_code,
    trunc(coalesce(vl.stock_qty, 0)),
    jsonb_build_object('medicine_name', m.name, 'model', m.model, 'barcode', m.barcode)
  from public.medicines m
  left join public.vw_inventory_live vl on vl.external_code = m.external_code
  where m.active is true
    and (v_scope <> 'active_with_stock' or coalesce(vl.stock_qty, 0) > 0)
  order by m.name;

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_SESSION_CREATE', v_user_id, jsonb_build_object('session_id', v_session_id, 'scope', v_scope));

  return public.inventory_count_session_payload(v_session_id);
end;
$$;

grant execute on function public.rpc_inventory_count_session_create(text, text, text) to anon, authenticated;

create or replace function public.rpc_inventory_count_session_current(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_session_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para consultar conteos';
  end if;

  select id into v_session_id
  from public.inventory_count_sessions
  where status = 'open'
  order by started_at desc
  limit 1;

  if v_session_id is null then
    return null;
  end if;

  return public.inventory_count_session_payload(v_session_id);
end;
$$;

grant execute on function public.rpc_inventory_count_session_current(text) to anon, authenticated;

create or replace function public.rpc_inventory_count_session_items(
  p_session_token text,
  p_session_id uuid,
  p_query text default '',
  p_status text default 'all',
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_status text := coalesce(nullif(trim(p_status), ''), 'all');
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 1000));
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
      i.id,
      i.session_id,
      i.external_code,
      m.name as medicine_name,
      m.secondary_name,
      m.model,
      m.barcode,
      i.expected_qty,
      i.counted_qty,
      i.variance_qty,
      i.status,
      i.note,
      i.counted_at,
      u.display_name as counted_by_name,
      i.applied_at,
      au.display_name as applied_by_name
    from public.inventory_count_session_items i
    join public.medicines m on m.id = i.medicine_id
    left join public.app_users u on u.id = i.counted_by
    left join public.app_users au on au.id = i.applied_by
    where i.session_id = p_session_id
      and (v_status = 'all' or i.status = v_status)
      and (
        v_query = ''
        or i.external_code::text = v_query
        or coalesce(m.barcode, '') ilike '%' || v_query || '%'
        or m.name ilike '%' || v_query || '%'
        or coalesce(m.secondary_name, '') ilike '%' || v_query || '%'
        or coalesce(m.model, '') ilike '%' || v_query || '%'
      )
    order by
      case i.status when 'pending' then 0 when 'counted' then 1 else 2 end,
      m.name
    limit v_limit
  ) x;

  return jsonb_build_object(
    'session', public.inventory_count_session_payload(p_session_id),
    'rows', v_rows
  );
end;
$$;

grant execute on function public.rpc_inventory_count_session_items(text, uuid, text, text, integer) to anon, authenticated;

create or replace function public.rpc_inventory_count_session_item_save(
  p_session_token text,
  p_item_id uuid,
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
  v_item record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para guardar conteos';
  end if;

  if p_counted_qty is null or p_counted_qty < 0 or p_counted_qty <> trunc(p_counted_qty) then
    raise exception 'El conteo debe ser entero y mayor o igual a 0';
  end if;

  select i.*, s.status as session_status
    into v_item
  from public.inventory_count_session_items i
  join public.inventory_count_sessions s on s.id = i.session_id
  where i.id = p_item_id
  for update of i;

  if v_item.id is null then
    raise exception 'Producto de conteo no encontrado';
  end if;

  if v_item.session_status <> 'open' then
    raise exception 'La sesion de conteo no esta abierta';
  end if;

  if v_item.status = 'applied' then
    raise exception 'Este producto ya tiene ajuste aplicado';
  end if;

  update public.inventory_count_session_items
     set counted_qty = trunc(p_counted_qty),
         status = 'counted',
         counted_by = v_user_id,
         counted_at = now(),
         note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_item_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_ITEM_SAVE', v_user_id, jsonb_build_object('item_id', p_item_id, 'session_id', v_item.session_id, 'external_code', v_item.external_code, 'counted_qty', trunc(p_counted_qty)));

  return (
    select to_jsonb(x)
    from (
      select
        i.id,
        i.session_id,
        i.external_code,
        m.name as medicine_name,
        i.expected_qty,
        i.counted_qty,
        i.variance_qty,
        i.status,
        i.counted_at,
        u.display_name as counted_by_name,
        i.note
      from public.inventory_count_session_items i
      join public.medicines m on m.id = i.medicine_id
      left join public.app_users u on u.id = i.counted_by
      where i.id = p_item_id
    ) x
  );
end;
$$;

grant execute on function public.rpc_inventory_count_session_item_save(text, uuid, numeric, text) to anon, authenticated;

create or replace function public.rpc_inventory_count_session_item_apply(p_session_token text, p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_item record;
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

  select i.*, m.name as medicine_name, m.barcode, coalesce(vl.unit_cost, 0) as unit_cost
    into v_item
  from public.inventory_count_session_items i
  join public.medicines m on m.id = i.medicine_id
  left join public.vw_inventory_live vl on vl.external_code = i.external_code
  where i.id = p_item_id
  for update of i;

  if v_item.id is null then
    raise exception 'Producto de conteo no encontrado';
  end if;

  if v_item.status <> 'counted' then
    raise exception 'Solo se aplican productos contados y pendientes de ajuste';
  end if;

  if coalesce(v_item.variance_qty, 0) <> 0 then
    insert into public.inventory_movements(
      movement_type, source_type, source_id, source_item_id, source_event_key,
      medicine_id, external_code, barcode, qty_delta, unit_cost, note, created_by, metadata
    )
    values (
      case when v_item.variance_qty > 0 then 'manual_count_adjust_in' else 'manual_count_adjust_out' end,
      'count_session',
      v_item.session_id,
      v_item.id,
      'count_session_item:' || v_item.id::text,
      v_item.medicine_id,
      v_item.external_code,
      v_item.barcode,
      v_item.variance_qty,
      v_item.unit_cost,
      'Ajuste aplicado desde sesion de conteo',
      v_user_id,
      jsonb_build_object('medicine_name', v_item.medicine_name, 'expected_qty', v_item.expected_qty, 'counted_qty', v_item.counted_qty, 'variance_qty', v_item.variance_qty, 'count_note', v_item.note)
    )
    on conflict (source_event_key) where source_event_key is not null do nothing
    returning id into v_movement_id;
  end if;

  update public.inventory_count_session_items
     set status = 'applied',
         applied_by = v_user_id,
         applied_at = now(),
         adjustment_movement_id = v_movement_id
   where id = v_item.id;

  insert into public.audit_log(event_type, user_id, metadata)
  values ('INVENTORY_COUNT_ITEM_APPLY', v_user_id, jsonb_build_object('item_id', v_item.id, 'session_id', v_item.session_id, 'external_code', v_item.external_code, 'variance_qty', v_item.variance_qty, 'movement_id', v_movement_id));

  return (
    select to_jsonb(x)
    from (
      select
        i.id,
        i.session_id,
        i.external_code,
        m.name as medicine_name,
        i.expected_qty,
        i.counted_qty,
        i.variance_qty,
        i.status,
        i.applied_at,
        au.display_name as applied_by_name,
        i.adjustment_movement_id
      from public.inventory_count_session_items i
      join public.medicines m on m.id = i.medicine_id
      left join public.app_users au on au.id = i.applied_by
      where i.id = v_item.id
    ) x
  );
end;
$$;

grant execute on function public.rpc_inventory_count_session_item_apply(text, uuid) to anon, authenticated;
