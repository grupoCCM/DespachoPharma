-- Remove a supplier return item while the document is still a draft.
-- This does not affect inventory because draft items have not created movements.

create or replace function public.rpc_supplier_return_item_remove(
  p_session_token text,
  p_item_id uuid
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
  v_doc record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  select i.*
    into v_item
  from public.supplier_return_items i
  where i.id = p_item_id
  for update;

  if v_item.id is null then
    raise exception 'No se encontro la linea de devolucion';
  end if;

  select *
    into v_doc
  from public.supplier_return_documents
  where id = v_item.document_id
  for update;

  if v_doc.id is null then
    raise exception 'No se encontro la hoja de devolucion';
  end if;

  if v_doc.status <> 'draft' then
    raise exception 'Solo se pueden quitar lineas antes de aplicar la salida';
  end if;

  if v_item.inventory_movement_id is not null or v_item.lot_movement_id is not null then
    raise exception 'La linea ya movio inventario y no puede quitarse desde borrador';
  end if;

  delete from public.supplier_return_items
  where id = p_item_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'SUPPLIER_RETURN',
    v_user_id,
    jsonb_build_object(
      'document_id', v_doc.id,
      'return_sheet_no', v_doc.return_sheet_no,
      'removed_item_id', v_item.id,
      'external_code', v_item.external_code,
      'medicine_name', v_item.medicine_name_snapshot,
      'lot_no', v_item.lot_no,
      'qty', v_item.qty,
      'status', 'draft_item_removed',
      'inventory_moved', false
    )
  );

  return jsonb_build_object(
    'document_id', v_doc.id,
    'removed_item_id', v_item.id,
    'inventory_moved', false
  );
end;
$$;

grant execute on function public.rpc_supplier_return_item_remove(text, uuid) to anon, authenticated;
