-- Integrate physical-count history with confirmed variance cases.
-- This migration changes function behavior only; it does not rewrite historical
-- sessions, count items, cases, resolutions, or inventory movements.

begin;

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
      coalesce(c.verified_qty, i.counted_qty) as result_counted_qty,
      coalesce(c.confirmed_variance_qty, i.variance_qty) as result_variance_qty,
      case when c.verified_qty is not null then 'verified' else 'first_count' end as result_source,
      i.status,
      i.note,
      i.condition_status,
      i.condition_qty,
      i.condition_note,
      i.counted_at,
      u.display_name as counted_by_name,
      coalesce(c.verified_at, i.counted_at) as result_counted_at,
      coalesce(vu.display_name, u.display_name) as result_counted_by_name,
      i.applied_at,
      au.display_name as applied_by_name
    from public.inventory_count_session_items i
    join public.medicines m on m.id = i.medicine_id
    left join public.inventory_variance_cases c on c.count_item_id = i.id
    left join public.app_users u on u.id = i.counted_by
    left join public.app_users vu on vu.id = c.verified_by
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
        or coalesce(i.condition_note, '') ilike '%' || v_query || '%'
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

create or replace function public.rpc_inventory_count_session_finish(
  p_session_token text,
  p_session_id uuid,
  p_action text,
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
  v_status text;
  v_action text := lower(trim(coalesce(p_action, '')));
  v_event public.audit_event_type;
  v_applied_cases integer := 0;
  v_resolutions integer := 0;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'No autorizado para finalizar conteos';
  end if;

  if v_action not in ('close','cancel') then
    raise exception 'Accion invalida';
  end if;

  select status into v_status
  from public.inventory_count_sessions
  where id = p_session_id
  for update;

  if v_status is null then
    raise exception 'Sesion de conteo no encontrada';
  end if;

  if v_status <> 'open' then
    raise exception 'La sesion ya no esta abierta';
  end if;

  if v_action = 'cancel' then
    select
      count(*) filter (where c.stock_adjustment_status = 'applied'),
      count(r.id)
      into v_applied_cases, v_resolutions
    from public.inventory_variance_cases c
    left join public.inventory_variance_resolutions r on r.case_id = c.id
    where c.count_session_id = p_session_id;

    if v_applied_cases > 0 or v_resolutions > 0 then
      raise exception 'No se puede cancelar: el conteo ya tiene ajustes o resoluciones aplicadas';
    end if;

    update public.inventory_variance_cases
       set stock_adjustment_status = case
             when stock_adjustment_status = 'pending' then 'not_required'
             else stock_adjustment_status
           end,
           investigation_status = 'resolved',
           resolved_by = coalesce(resolved_by, v_user_id),
           resolved_at = coalesce(resolved_at, now()),
           resolution_note = coalesce(
             resolution_note,
             'Conteo cancelado; expediente cerrado sin movimiento de inventario'
           )
     where count_session_id = p_session_id;
  end if;

  update public.inventory_count_sessions
     set status = case when v_action = 'close' then 'closed' else 'cancelled' end,
         closed_by = v_user_id,
         closed_at = now(),
         note = nullif(trim(coalesce(p_note, note, '')), '')
   where id = p_session_id;

  v_event := case
    when v_action = 'close' then 'INVENTORY_COUNT_SESSION_CLOSE'::public.audit_event_type
    else 'INVENTORY_COUNT_SESSION_CANCEL'::public.audit_event_type
  end;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    v_event,
    v_user_id,
    jsonb_build_object(
      'session_id', p_session_id,
      'action', v_action,
      'note', p_note,
      'cancelled_variance_cases_closed', case when v_action = 'cancel' then true else false end
    )
  );

  return public.inventory_count_session_payload(p_session_id);
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

  select c.*, m.barcode, m.name as medicine_name, s.status as session_status
    into v_case
  from public.inventory_variance_cases c
  join public.medicines m on m.id = c.medicine_id
  join public.inventory_count_sessions s on s.id = c.count_session_id
  where c.id = p_case_id
  for update of c;

  if v_case.id is null then raise exception 'Expediente de diferencia no encontrado'; end if;
  if v_case.session_status = 'cancelled' then raise exception 'No se puede ajustar inventario desde un conteo cancelado'; end if;
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

  select c.*, m.barcode, s.status as session_status into v_case
  from public.inventory_variance_cases c
  join public.medicines m on m.id = c.medicine_id
  join public.inventory_count_sessions s on s.id = c.count_session_id
  where c.id = p_case_id
  for update of c;

  if v_case.id is null then raise exception 'Expediente no encontrado'; end if;
  if v_case.session_status = 'cancelled' then raise exception 'No se puede resolver una diferencia de un conteo cancelado'; end if;
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

revoke execute on function public.rpc_inventory_count_session_items(text, uuid, text, text, integer) from public;
revoke execute on function public.rpc_inventory_count_session_finish(text, uuid, text, text) from public;
revoke execute on function public.rpc_inventory_variance_apply_stock(text, uuid) from public;
revoke execute on function public.rpc_inventory_variance_resolve(text, uuid, text, numeric, numeric, text, text) from public;

grant execute on function public.rpc_inventory_count_session_items(text, uuid, text, text, integer) to anon, authenticated;
grant execute on function public.rpc_inventory_count_session_finish(text, uuid, text, text) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_apply_stock(text, uuid) to anon, authenticated;
grant execute on function public.rpc_inventory_variance_resolve(text, uuid, text, numeric, numeric, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

commit;

