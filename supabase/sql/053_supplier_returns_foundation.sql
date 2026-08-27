-- Supplier returns foundation.
-- This migration is intentionally additive: it does not change current dispatch,
-- purchase import, inventory count, or availability flows.
--
-- Operational rule:
-- - "Devolucion de mercaderia" is the physical event and subtracts inventory.
-- - The later supplier credit note is financial reconciliation only and must not
--   subtract inventory again.

do $$
begin
  alter type public.audit_event_type add value if not exists 'SUPPLIER_RETURN';
exception when duplicate_object then null;
end $$;

create table if not exists public.supplier_return_documents (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid references public.suppliers(id),
  supplier_name text,
  return_sheet_no text not null,
  return_date date not null default current_date,
  status text not null default 'draft',
  credit_note_no text,
  credit_note_date date,
  credit_note_amount numeric(14,4),
  note text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  applied_by uuid references public.app_users(id),
  applied_at timestamptz,
  reconciled_by uuid references public.app_users(id),
  reconciled_at timestamptz,
  voided_by uuid references public.app_users(id),
  voided_at timestamptz,
  void_reason text,
  metadata jsonb not null default '{}'::jsonb,
  constraint supplier_return_documents_status_chk check (
    status in ('draft', 'applied_pending_credit_note', 'credit_note_reconciled', 'voided')
  )
);

create index if not exists ix_supplier_return_documents_status_date
on public.supplier_return_documents(status, return_date desc, created_at desc);

create index if not exists ix_supplier_return_documents_supplier
on public.supplier_return_documents(supplier_id, return_date desc);

create unique index if not exists ux_supplier_return_documents_open_sheet
on public.supplier_return_documents(coalesce(supplier_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(trim(return_sheet_no)))
where status <> 'voided';

create table if not exists public.supplier_return_items (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.supplier_return_documents(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  external_code integer not null,
  barcode text,
  medicine_name_snapshot text,
  lot_id uuid references public.inventory_lots(id),
  lot_no text,
  expires_at date,
  qty numeric(14,4) not null,
  unit_cost numeric(14,4),
  reason text not null,
  note text,
  inventory_movement_id uuid references public.inventory_movements(id),
  lot_movement_id uuid references public.inventory_lot_movements(id),
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint supplier_return_items_qty_chk check (qty > 0 and qty = trunc(qty))
);

create index if not exists ix_supplier_return_items_document
on public.supplier_return_items(document_id);

create index if not exists ix_supplier_return_items_product
on public.supplier_return_items(external_code, created_at desc);

create index if not exists ix_supplier_return_items_lot
on public.supplier_return_items(lot_id)
where lot_id is not null;

create unique index if not exists ux_supplier_return_items_document_lot_reason
on public.supplier_return_items(document_id, external_code, coalesce(lot_no, ''), coalesce(expires_at, '9999-12-31'::date), lower(trim(reason)))
where inventory_movement_id is null;

alter table public.supplier_return_documents enable row level security;
alter table public.supplier_return_items enable row level security;

create or replace view public.vw_supplier_return_documents as
select
  d.*,
  coalesce(s.name, d.supplier_name) as supplier_display_name,
  u.display_name as created_by_name,
  au.display_name as applied_by_name,
  ru.display_name as reconciled_by_name,
  count(i.id) as line_count,
  coalesce(sum(i.qty), 0) as total_units
from public.supplier_return_documents d
left join public.suppliers s on s.id = d.supplier_id
left join public.app_users u on u.id = d.created_by
left join public.app_users au on au.id = d.applied_by
left join public.app_users ru on ru.id = d.reconciled_by
left join public.supplier_return_items i on i.document_id = d.id
group by d.id, s.name, u.display_name, au.display_name, ru.display_name;

create or replace function public.rpc_supplier_return_lookup_lots(
  p_session_token text,
  p_query text default '',
  p_limit integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := lower(trim(coalesce(p_query, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 100));
  v_items jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('admin','dispatch','cashier') then
    raise exception 'Permiso denegado';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.medicine_name, x.expires_at nulls last, x.lot_no), '[]'::jsonb)
    into v_items
  from (
    select
      l.lot_id,
      l.external_code,
      l.barcode,
      l.medicine_id,
      l.medicine_name,
      l.model,
      l.secondary_name,
      l.presentation,
      l.lot_no,
      l.expires_at,
      l.lot_qty,
      l.stock_qty,
      l.unit_cost
    from public.vw_inventory_lot_live l
    left join public.medicines m on m.id = l.medicine_id
    where l.lot_qty > 0
      and coalesce(m.active, true) is true
      and (
        v_query = ''
        or lower(coalesce(l.medicine_name, '')) like '%' || v_query || '%'
        or lower(coalesce(l.secondary_name, '')) like '%' || v_query || '%'
        or lower(coalesce(l.model, '')) like '%' || v_query || '%'
        or lower(coalesce(l.barcode, '')) like '%' || v_query || '%'
        or l.external_code::text like '%' || v_query || '%'
        or lower(coalesce(l.lot_no, '')) like '%' || v_query || '%'
      )
    order by l.medicine_name, l.expires_at nulls last, l.lot_no
    limit v_limit
  ) x;

  return jsonb_build_object('items', v_items);
end;
$$;

create or replace function public.rpc_supplier_return_document_create(
  p_session_token text,
  p_supplier_name text,
  p_return_sheet_no text,
  p_return_date date default current_date,
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
  v_supplier_id uuid;
  v_supplier_name text := nullif(trim(coalesce(p_supplier_name, '')), '');
  v_sheet text := nullif(trim(coalesce(p_return_sheet_no, '')), '');
  v_doc_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  if v_sheet is null then
    raise exception 'Indica el numero de hoja de devolucion';
  end if;

  if v_supplier_name is not null then
    select id into v_supplier_id
    from public.suppliers
    where normalized_name = lower(v_supplier_name)
       or lower(name) = lower(v_supplier_name)
    limit 1;
  end if;

  insert into public.supplier_return_documents(
    supplier_id,
    supplier_name,
    return_sheet_no,
    return_date,
    note,
    created_by
  )
  values (
    v_supplier_id,
    v_supplier_name,
    v_sheet,
    coalesce(p_return_date, current_date),
    nullif(trim(coalesce(p_note, '')), ''),
    v_user_id
  )
  returning id into v_doc_id;

  return jsonb_build_object('document_id', v_doc_id, 'status', 'draft');
end;
$$;

create or replace function public.rpc_supplier_return_item_add(
  p_session_token text,
  p_document_id uuid,
  p_external_code integer,
  p_lot_id uuid,
  p_qty numeric,
  p_reason text,
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
  v_doc record;
  v_medicine record;
  v_lot record;
  v_qty numeric := coalesce(p_qty, 0);
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_item_id uuid;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  if v_qty <= 0 or v_qty <> trunc(v_qty) then
    raise exception 'La cantidad debe ser un entero mayor que 0';
  end if;

  if v_reason is null then
    raise exception 'Indica el motivo de retiro';
  end if;

  select * into v_doc
  from public.supplier_return_documents
  where id = p_document_id
  for update;

  if v_doc.id is null then
    raise exception 'No se encontro la devolucion';
  end if;

  if v_doc.status <> 'draft' then
    raise exception 'La devolucion ya no esta en borrador';
  end if;

  select m.id, m.external_code, m.barcode, m.name, m.model
    into v_medicine
  from public.medicines m
  where m.external_code = p_external_code
    and m.active is true
  limit 1;

  if v_medicine.id is null then
    raise exception 'Producto no encontrado o inactivo';
  end if;

  if p_lot_id is null then
    if exists (
      select 1
      from public.vw_inventory_lot_live
      where external_code = p_external_code
        and lot_qty > 0
    ) then
      raise exception 'Selecciona el lote de la devolucion para este producto';
    end if;
  else
    select * into v_lot
    from public.vw_inventory_lot_live
    where lot_id = p_lot_id
      and external_code = p_external_code;

    if v_lot.lot_id is null then
      raise exception 'Lote no encontrado para el producto';
    end if;

    if coalesce(v_lot.lot_qty, 0) < v_qty then
      raise exception 'No se puede devolver %. Disponible en lote: %.', v_qty, coalesce(v_lot.lot_qty, 0);
    end if;
  end if;

  insert into public.supplier_return_items(
    document_id,
    medicine_id,
    external_code,
    barcode,
    medicine_name_snapshot,
    lot_id,
    lot_no,
    expires_at,
    qty,
    unit_cost,
    reason,
    note
  )
  values (
    p_document_id,
    v_medicine.id,
    v_medicine.external_code,
    v_medicine.barcode,
    v_medicine.name,
    p_lot_id,
    v_lot.lot_no,
    v_lot.expires_at,
    v_qty,
    v_lot.unit_cost,
    v_reason,
    nullif(trim(coalesce(p_note, '')), '')
  )
  returning id into v_item_id;

  return jsonb_build_object('item_id', v_item_id, 'document_id', p_document_id);
end;
$$;

create or replace function public.rpc_supplier_return_apply(
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
  v_doc record;
  v_item record;
  v_lot record;
  v_inventory_movement_id uuid;
  v_lot_movement_id uuid;
  v_lines integer := 0;
  v_units numeric := 0;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  select * into v_doc
  from public.supplier_return_documents
  where id = p_document_id
  for update;

  if v_doc.id is null then
    raise exception 'No se encontro la devolucion';
  end if;

  if v_doc.status <> 'draft' then
    raise exception 'Solo se pueden aplicar devoluciones en borrador';
  end if;

  if not exists (select 1 from public.supplier_return_items where document_id = p_document_id) then
    raise exception 'Agrega al menos un producto a la devolucion';
  end if;

  for v_item in
    select *
    from public.supplier_return_items
    where document_id = p_document_id
    order by created_at, id
  loop
    if v_item.lot_id is null then
      raise exception 'El producto % requiere lote antes de aplicar la devolucion', v_item.external_code;
    end if;

    select * into v_lot
    from public.vw_inventory_lot_live
    where lot_id = v_item.lot_id
      and external_code = v_item.external_code;

    if v_lot.lot_id is null then
      raise exception 'Lote no encontrado para producto %', v_item.external_code;
    end if;

    if coalesce(v_lot.lot_qty, 0) < v_item.qty then
      raise exception 'No se puede devolver %. Disponible en lote: %.', v_item.qty, coalesce(v_lot.lot_qty, 0);
    end if;

    insert into public.inventory_movements(
      movement_type,
      source_type,
      source_id,
      source_item_id,
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
      'supplier_return_out',
      'supplier_return',
      p_document_id,
      v_item.id,
      'supplier_return:' || p_document_id::text || ':' || v_item.id::text,
      v_item.medicine_id,
      v_item.external_code,
      v_item.barcode,
      -1 * v_item.qty,
      v_item.unit_cost,
      'Salida por devolucion de mercaderia',
      v_user_id,
      jsonb_build_object(
        'return_sheet_no', v_doc.return_sheet_no,
        'return_date', v_doc.return_date,
        'reason', v_item.reason,
        'lot_no', v_item.lot_no,
        'expires_at', v_item.expires_at,
        'note', v_item.note
      )
    )
    returning id into v_inventory_movement_id;

    insert into public.inventory_lot_movements(
      lot_id,
      inventory_movement_id,
      movement_type,
      source_type,
      source_id,
      source_item_id,
      source_event_key,
      medicine_id,
      external_code,
      barcode,
      qty_delta,
      created_by,
      metadata
    )
    values (
      v_item.lot_id,
      v_inventory_movement_id,
      'supplier_return_out',
      'supplier_return',
      p_document_id,
      v_item.id,
      'supplier_return_lot:' || p_document_id::text || ':' || v_item.id::text || ':' || v_item.lot_id::text,
      v_item.medicine_id,
      v_item.external_code,
      v_item.barcode,
      -1 * v_item.qty,
      v_user_id,
      jsonb_build_object(
        'return_sheet_no', v_doc.return_sheet_no,
        'return_date', v_doc.return_date,
        'reason', v_item.reason,
        'lot_no', v_item.lot_no,
        'expires_at', v_item.expires_at,
        'note', v_item.note
      )
    )
    returning id into v_lot_movement_id;

    update public.supplier_return_items
       set inventory_movement_id = v_inventory_movement_id,
           lot_movement_id = v_lot_movement_id
     where id = v_item.id;

    v_lines := v_lines + 1;
    v_units := v_units + v_item.qty;
  end loop;

  update public.supplier_return_documents
     set status = 'applied_pending_credit_note',
         applied_by = v_user_id,
         applied_at = now()
   where id = p_document_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'SUPPLIER_RETURN',
    v_user_id,
    jsonb_build_object(
      'document_id', p_document_id,
      'return_sheet_no', v_doc.return_sheet_no,
      'status', 'applied_pending_credit_note',
      'lines', v_lines,
      'units', v_units
    )
  );

  return jsonb_build_object(
    'document_id', p_document_id,
    'status', 'applied_pending_credit_note',
    'lines', v_lines,
    'units', v_units
  );
end;
$$;

create or replace function public.rpc_supplier_return_credit_note_reconcile(
  p_session_token text,
  p_document_id uuid,
  p_credit_note_no text,
  p_credit_note_date date default null,
  p_credit_note_amount numeric default null,
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
  v_doc record;
  v_credit_note_no text := nullif(trim(coalesce(p_credit_note_no, '')), '');
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  if v_credit_note_no is null then
    raise exception 'Indica el numero de nota de credito';
  end if;

  select * into v_doc
  from public.supplier_return_documents
  where id = p_document_id
  for update;

  if v_doc.id is null then
    raise exception 'No se encontro la devolucion';
  end if;

  if v_doc.status <> 'applied_pending_credit_note' then
    raise exception 'Solo se concilian devoluciones aplicadas pendientes de nota de credito';
  end if;

  update public.supplier_return_documents
     set status = 'credit_note_reconciled',
         credit_note_no = v_credit_note_no,
         credit_note_date = coalesce(p_credit_note_date, current_date),
         credit_note_amount = p_credit_note_amount,
         reconciled_by = v_user_id,
         reconciled_at = now(),
         note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note)
   where id = p_document_id;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    'SUPPLIER_RETURN',
    v_user_id,
    jsonb_build_object(
      'document_id', p_document_id,
      'return_sheet_no', v_doc.return_sheet_no,
      'status', 'credit_note_reconciled',
      'credit_note_no', v_credit_note_no,
      'inventory_moved', false
    )
  );

  return jsonb_build_object(
    'document_id', p_document_id,
    'status', 'credit_note_reconciled',
    'inventory_moved', false
  );
end;
$$;

create or replace function public.rpc_supplier_return_list(
  p_session_token text,
  p_status text default null,
  p_query text default '',
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status text := nullif(trim(coalesce(p_status, '')), '');
  v_query text := lower(trim(coalesce(p_query, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 300));
  v_docs jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.return_date desc, x.created_at desc), '[]'::jsonb)
    into v_docs
  from (
    select
      d.id,
      d.return_sheet_no,
      d.return_date,
      d.status,
      d.supplier_display_name,
      d.credit_note_no,
      d.credit_note_date,
      d.line_count,
      d.total_units,
      d.created_at,
      d.created_by_name,
      d.applied_by_name,
      d.applied_at,
      d.reconciled_by_name,
      d.reconciled_at
    from public.vw_supplier_return_documents d
    where (v_status is null or d.status = v_status)
      and (
        v_query = ''
        or lower(coalesce(d.return_sheet_no, '')) like '%' || v_query || '%'
        or lower(coalesce(d.supplier_display_name, '')) like '%' || v_query || '%'
        or lower(coalesce(d.credit_note_no, '')) like '%' || v_query || '%'
      )
    order by d.return_date desc, d.created_at desc
    limit v_limit
  ) x;

  return jsonb_build_object('documents', v_docs);
end;
$$;

grant execute on function public.rpc_supplier_return_lookup_lots(text, text, integer) to anon, authenticated;
grant execute on function public.rpc_supplier_return_document_create(text, text, text, date, text) to anon, authenticated;
grant execute on function public.rpc_supplier_return_item_add(text, uuid, integer, uuid, numeric, text, text) to anon, authenticated;
grant execute on function public.rpc_supplier_return_apply(text, uuid) to anon, authenticated;
grant execute on function public.rpc_supplier_return_credit_note_reconcile(text, uuid, text, date, numeric, text) to anon, authenticated;
grant execute on function public.rpc_supplier_return_list(text, text, text, integer) to anon, authenticated;
