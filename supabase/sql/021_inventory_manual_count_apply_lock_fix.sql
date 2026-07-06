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
  for update of c;

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
