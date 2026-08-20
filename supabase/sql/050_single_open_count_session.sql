-- Prevent more than one open physical count session.
-- If a session is already open, the create RPC returns it instead of creating another.

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
  v_existing_session_id uuid;
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

  perform pg_advisory_xact_lock(hashtextextended('inventory_count_session_open', 0));

  select id into v_existing_session_id
  from public.inventory_count_sessions
  where status = 'open'
  order by started_at desc
  limit 1
  for update;

  if v_existing_session_id is not null then
    return public.inventory_count_session_payload(v_existing_session_id)
      || jsonb_build_object('reused_open_session', true);
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
    session_id,
    medicine_id,
    external_code,
    expected_qty,
    expected_unit_cost,
    metadata
  )
  select
    v_session_id,
    m.id,
    m.external_code,
    trunc(coalesce(vl.stock_qty, 0)),
    coalesce(vl.unit_cost, 0),
    jsonb_build_object(
      'medicine_name', m.name,
      'model', m.model,
      'barcode', m.barcode,
      'expected_qty_frozen', trunc(coalesce(vl.stock_qty, 0)),
      'expected_unit_cost_frozen', coalesce(vl.unit_cost, 0),
      'frozen_at', now()
    )
  from public.medicines m
  left join public.vw_inventory_live vl on vl.external_code = m.external_code
  where m.active is true
    and (v_scope <> 'active_with_stock' or coalesce(vl.stock_qty, 0) > 0)
  order by m.name;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'INVENTORY_COUNT_SESSION_CREATE',
    v_user_id,
    jsonb_build_object(
      'session_id', v_session_id,
      'scope', v_scope,
      'frozen_fields', jsonb_build_array('expected_qty','expected_unit_cost')
    )
  );

  return public.inventory_count_session_payload(v_session_id)
    || jsonb_build_object('reused_open_session', false);
end;
$$;

grant execute on function public.rpc_inventory_count_session_create(text, text, text) to anon, authenticated;
