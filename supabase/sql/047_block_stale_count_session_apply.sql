-- Prevent applying inventory count adjustments from stale or non-open sessions.
-- The UI warns after 1 day; the database blocks application after 3 days.

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

  select
    i.*,
    s.status as session_status,
    s.started_at as session_started_at,
    m.name as medicine_name,
    m.barcode,
    coalesce(vl.unit_cost, 0) as unit_cost
    into v_item
  from public.inventory_count_session_items i
  join public.inventory_count_sessions s on s.id = i.session_id
  join public.medicines m on m.id = i.medicine_id
  left join public.vw_inventory_live vl on vl.external_code = i.external_code
  where i.id = p_item_id
  for update of i;

  if v_item.id is null then
    raise exception 'Producto de conteo no encontrado';
  end if;

  if v_item.session_status <> 'open' then
    raise exception 'Solo se pueden aplicar ajustes de una sesion abierta';
  end if;

  if v_item.session_started_at < now() - interval '3 days' then
    raise exception 'Este conteo fue creado hace mas de 3 dias. Crea un nuevo conteo para aplicar diferencias actuales.';
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
      jsonb_build_object(
        'medicine_name', v_item.medicine_name,
        'expected_qty', v_item.expected_qty,
        'counted_qty', v_item.counted_qty,
        'variance_qty', v_item.variance_qty,
        'count_note', v_item.note,
        'session_started_at', v_item.session_started_at
      )
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
  values (
    'INVENTORY_COUNT_ITEM_APPLY',
    v_user_id,
    jsonb_build_object(
      'item_id', v_item.id,
      'session_id', v_item.session_id,
      'external_code', v_item.external_code,
      'variance_qty', v_item.variance_qty,
      'movement_id', v_movement_id,
      'session_started_at', v_item.session_started_at
    )
  );

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
