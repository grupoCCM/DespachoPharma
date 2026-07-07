create or replace function public.rpc_dispatch_void(p_session_token text, p_dispatch_id uuid, p_reason text default null::text)
returns table(success boolean, dispatch_id uuid, previous_status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_delivery bigint;
  v_expediente text;
  v_item record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo el administrador puede anular despachos';
  end if;

  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'Debe indicar un motivo para la anulacion';
  end if;

  select dh.status, dh.delivery_no, dh.expediente
    into v_status, v_delivery, v_expediente
  from public.dispatch_header dh
  where dh.id = p_dispatch_id;

  if v_status is null then
    raise exception 'Despacho no encontrado';
  end if;

  if v_status = 'voided' then
    raise exception 'Este despacho ya fue anulado previamente';
  end if;

  if v_status = 'validated' then
    for v_item in
      select di.id, di.barcode, di.qty, di.product_name_snapshot
      from public.dispatch_items di
      where di.dispatch_id = p_dispatch_id
    loop
      perform public.inventory_insert_dispatch_movement(
        p_dispatch_id,
        v_item.id,
        v_item.barcode,
        v_item.qty,
        'dispatch_return',
        'dispatch_void',
        'dispatch_void:' || v_item.id::text,
        v_user_id,
        'Devolucion por anulacion de despacho validado',
        jsonb_build_object('product_name', v_item.product_name_snapshot, 'reason', p_reason)
      );
    end loop;
  end if;

  update public.dispatch_header dh
     set status = 'voided',
         voided_by = v_user_id,
         voided_at = now(),
         void_reason = p_reason,
         updated_at = now()
   where dh.id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_VOID',
    v_user_id,
    p_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery,
      'expediente', v_expediente,
      'previous_status', v_status::text,
      'reason', p_reason
    )
  );

  return query select true, p_dispatch_id, v_status::text;
end;
$$;

grant execute on function public.rpc_dispatch_void(text, uuid, text) to anon, authenticated;
