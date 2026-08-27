-- UI support for supplier returns.
-- Additive helpers: inspect a document and void a draft without touching
-- inventory already applied.

create or replace function public.rpc_supplier_return_document_detail(
  p_session_token text,
  p_document_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_doc jsonb;
  v_items jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  select to_jsonb(d)
    into v_doc
  from public.vw_supplier_return_documents d
  where d.id = p_document_id;

  if v_doc is null then
    raise exception 'No se encontro la devolucion';
  end if;

  select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at, i.id), '[]'::jsonb)
    into v_items
  from (
    select
      id,
      document_id,
      external_code,
      barcode,
      medicine_name_snapshot,
      lot_id,
      lot_no,
      expires_at,
      qty,
      unit_cost,
      reason,
      note,
      inventory_movement_id,
      lot_movement_id,
      created_at
    from public.supplier_return_items
    where document_id = p_document_id
    order by created_at, id
  ) i;

  return jsonb_build_object('document', v_doc, 'items', v_items);
end;
$$;

create or replace function public.rpc_supplier_return_draft_void(
  p_session_token text,
  p_document_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_doc record;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  select *
    into v_doc
  from public.supplier_return_documents
  where id = p_document_id
  for update;

  if v_doc.id is null then
    raise exception 'No se encontro la devolucion';
  end if;

  if v_doc.status <> 'draft' then
    raise exception 'Solo se pueden anular borradores. Las devoluciones aplicadas requieren reverso controlado.';
  end if;

  update public.supplier_return_documents
     set status = 'voided',
         voided_by = v_user_id,
         voided_at = now(),
         void_reason = coalesce(v_reason, 'Borrador anulado')
   where id = p_document_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'SUPPLIER_RETURN',
    v_user_id,
    jsonb_build_object(
      'document_id', p_document_id,
      'return_sheet_no', v_doc.return_sheet_no,
      'status', 'voided',
      'reason', coalesce(v_reason, 'Borrador anulado'),
      'inventory_moved', false
    )
  );

  return jsonb_build_object('document_id', p_document_id, 'status', 'voided', 'inventory_moved', false);
end;
$$;

grant execute on function public.rpc_supplier_return_document_detail(text, uuid) to anon, authenticated;
grant execute on function public.rpc_supplier_return_draft_void(text, uuid, text) to anon, authenticated;
