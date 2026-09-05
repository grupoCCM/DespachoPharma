-- Represent external sales in pharmacy history without duplicating inventory movements.

alter table public.dispatch_header
  add column if not exists source_kind text not null default 'internal_dispatch',
  add column if not exists inventory_effect text not null default 'cashier_validation',
  add column if not exists sales_document_id uuid references public.sales_documents(id),
  add column if not exists external_sale_no integer,
  add column if not exists external_voucher_no text,
  add column if not exists external_sale_date date;

alter table public.dispatch_header
  drop constraint if exists dispatch_header_source_kind_check,
  add constraint dispatch_header_source_kind_check
    check (source_kind in ('internal_dispatch', 'external_sale'));

alter table public.dispatch_header
  drop constraint if exists dispatch_header_inventory_effect_check,
  add constraint dispatch_header_inventory_effect_check
    check (inventory_effect in ('cashier_validation', 'already_reconciled'));

create index if not exists idx_dispatch_header_sales_document
  on public.dispatch_header(sales_document_id)
  where sales_document_id is not null;

create index if not exists idx_dispatch_header_external_sale
  on public.dispatch_header(external_sale_no, external_voucher_no)
  where external_sale_no is not null;

drop function if exists public.rpc_dispatch_search(
  text,
  timestamp with time zone,
  timestamp with time zone,
  public.dispatch_status,
  text,
  bigint,
  uuid,
  integer,
  integer
);

create or replace function public.rpc_dispatch_search(
  p_session_token text,
  p_date_from timestamp with time zone default null::timestamp with time zone,
  p_date_to timestamp with time zone default null::timestamp with time zone,
  p_status public.dispatch_status default null::public.dispatch_status,
  p_expediente text default null::text,
  p_delivery_no bigint default null::bigint,
  p_created_by uuid default null::uuid,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(
  dispatch_id uuid,
  delivery_no bigint,
  expediente text,
  status public.dispatch_status,
  created_at timestamp with time zone,
  confirmed_at timestamp with time zone,
  created_by uuid,
  created_by_name text,
  validated_at timestamp with time zone,
  observed_at timestamp with time zone,
  items_count integer,
  total_units integer,
  source_kind text,
  inventory_effect text,
  sales_document_id uuid,
  external_sale_no integer,
  external_voucher_no text,
  external_sale_date date
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  return query
  with base as (
    select
      h.id as dispatch_id,
      h.delivery_no,
      h.expediente,
      h.status,
      h.created_at,
      h.confirmed_at,
      h.created_by,
      u.display_name as created_by_name,
      h.validated_at,
      h.observed_at,
      (select count(*)::int from public.dispatch_items i where i.dispatch_id = h.id) as items_count,
      (select coalesce(sum(i.qty),0)::int from public.dispatch_items i where i.dispatch_id = h.id) as total_units,
      h.source_kind,
      h.inventory_effect,
      h.sales_document_id,
      h.external_sale_no,
      h.external_voucher_no,
      h.external_sale_date
    from public.dispatch_header h
    join public.app_users u on u.id = h.created_by
    where (p_delivery_no is null or h.delivery_no = p_delivery_no)
      and (p_expediente is null or h.expediente ilike '%' || p_expediente || '%')
      and (p_status is null or h.status = p_status)
      and (p_created_by is null or h.created_by = p_created_by)
      and (p_date_from is null or h.created_at >= p_date_from)
      and (p_date_to is null or h.created_at <= p_date_to)
      and (
        v_role = 'admin'
        or (v_role = 'dispatch' and h.created_by = v_user_id)
        or (v_role = 'cashier' and h.status in ('confirmed','validated','observed') and h.source_kind = 'internal_dispatch')
      )
  )
  select *
  from base
  order by created_at desc
  limit greatest(1, least(p_limit, 200))
  offset greatest(p_offset, 0);
end;
$$;

drop function if exists public.rpc_dispatch_get(text, uuid);

create or replace function public.rpc_dispatch_get(p_session_token text, p_dispatch_id uuid)
returns table(header jsonb, items jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_h public.dispatch_header%rowtype;
  v_created_by_name text;
  v_voided_by_name text;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  select * into v_h
  from public.dispatch_header
  where id = p_dispatch_id;

  if not found then
    raise exception 'Entrega/Despacho no existe';
  end if;

  if v_role = 'dispatch' and v_h.created_by <> v_user_id then
    raise exception 'Permiso denegado';
  end if;

  if v_role = 'cashier' and (v_h.status not in ('confirmed','validated','observed') or v_h.source_kind <> 'internal_dispatch') then
    raise exception 'Permiso denegado';
  end if;

  select display_name into v_created_by_name
  from public.app_users
  where id = v_h.created_by;

  if v_h.voided_by is not null then
    select display_name into v_voided_by_name
    from public.app_users
    where id = v_h.voided_by;
  end if;

  return query
  select
    jsonb_build_object(
      'dispatch_id', v_h.id,
      'delivery_no', v_h.delivery_no,
      'expediente', v_h.expediente,
      'status', v_h.status,
      'created_at', v_h.created_at,
      'created_by', v_h.created_by,
      'created_by_name', v_created_by_name,
      'confirmed_at', v_h.confirmed_at,
      'validated_by', v_h.validated_by,
      'validated_at', v_h.validated_at,
      'observed_by', v_h.observed_by,
      'observed_at', v_h.observed_at,
      'observation_note', v_h.observation_note,
      'voided_by', v_h.voided_by,
      'voided_at', v_h.voided_at,
      'void_reason', v_h.void_reason,
      'voided_by_name', v_voided_by_name,
      'source_kind', v_h.source_kind,
      'inventory_effect', v_h.inventory_effect,
      'sales_document_id', v_h.sales_document_id,
      'external_sale_no', v_h.external_sale_no,
      'external_voucher_no', v_h.external_voucher_no,
      'external_sale_date', v_h.external_sale_date,
      'items_count', (select count(*)::int from public.dispatch_items i where i.dispatch_id = v_h.id),
      'total_units', (select coalesce(sum(i.qty),0)::int from public.dispatch_items i where i.dispatch_id = v_h.id)
    ) as header,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'barcode', i.barcode,
            'product_name', i.product_name_snapshot,
            'qty', i.qty
          )
          order by i.product_name_snapshot
        )
        from public.dispatch_items i
        where i.dispatch_id = v_h.id
      ),
      '[]'::jsonb
    ) as items;
end;
$$;

create or replace function public.rpc_dispatch_get_by_delivery_no(p_session_token text, p_delivery_no bigint)
returns table(header jsonb, items jsonb)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id
  from public.dispatch_header
  where delivery_no = p_delivery_no
  limit 1;

  if v_id is null then
    raise exception 'Entrega # no encontrada';
  end if;

  return query
  select * from public.rpc_dispatch_get(p_session_token, v_id);
end;
$$;

drop function if exists public.rpc_cashier_validate(text, uuid);

create or replace function public.rpc_cashier_validate(p_session_token text, p_dispatch_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_source_kind text;
  v_inventory_effect text;
  v_item record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role not in ('cashier','admin') then
    raise exception 'Permiso denegado';
  end if;

  select status, source_kind, inventory_effect
    into v_status, v_source_kind, v_inventory_effect
  from public.dispatch_header
  where id = p_dispatch_id;

  if v_status <> 'confirmed' then
    raise exception 'Solo se puede validar si está confirmed';
  end if;

  if v_source_kind <> 'internal_dispatch' or v_inventory_effect <> 'cashier_validation' then
    raise exception 'Esta entrega corresponde a una venta externa conciliada; no requiere validación de Caja';
  end if;

  for v_item in
    select barcode, sum(qty)::numeric as qty
    from public.dispatch_items
    where dispatch_id = p_dispatch_id
    group by barcode
  loop
    perform public.dispatch_raise_if_stock_insufficient(v_item.barcode, v_item.qty, p_dispatch_id);
  end loop;

  update public.dispatch_header
     set status = 'validated',
         validated_by = v_user_id,
         validated_at = now()
   where id = p_dispatch_id;

  for v_item in
    select id, barcode, qty, product_name_snapshot
    from public.dispatch_items
    where dispatch_id = p_dispatch_id
  loop
    perform public.inventory_insert_dispatch_movement(
      p_dispatch_id,
      v_item.id,
      v_item.barcode,
      -1 * v_item.qty,
      'dispatch_out',
      'dispatch_validate',
      'dispatch_validate:' || v_item.id::text,
      v_user_id,
      'Descuento por despacho validado',
      jsonb_build_object('product_name', v_item.product_name_snapshot)
    );
  end loop;

  insert into public.audit_log(event_type, user_id, dispatch_id)
  values ('CASHIER_VALIDATE', v_user_id, p_dispatch_id);
end;
$$;

drop function if exists public.rpc_dispatch_void(text, uuid, text);

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
  v_source_kind text;
  v_inventory_effect text;
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

  select dh.status, dh.delivery_no, dh.expediente, dh.source_kind, dh.inventory_effect
    into v_status, v_delivery, v_expediente, v_source_kind, v_inventory_effect
  from public.dispatch_header dh
  where dh.id = p_dispatch_id;

  if v_status is null then
    raise exception 'Despacho no encontrado';
  end if;

  if v_status = 'voided' then
    raise exception 'Este despacho ya fue anulado previamente';
  end if;

  if v_status = 'validated'
     and v_source_kind = 'internal_dispatch'
     and v_inventory_effect = 'cashier_validation' then
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
      'source_kind', v_source_kind,
      'inventory_effect', v_inventory_effect,
      'reason', p_reason
    )
  );

  return query select true, p_dispatch_id, v_status::text;
end;
$$;

create or replace function public.rpc_dispatch_register_external_sale(
  p_session_token text,
  p_external_sale_no integer,
  p_voucher_no text,
  p_delivery_no bigint default null::bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_doc public.sales_documents%rowtype;
  v_patient_code text;
  v_dispatch_id uuid;
  v_delivery_no bigint;
  v_existing_status public.dispatch_status;
  v_item_count integer;
  v_total_units integer;
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
  from public.sales_documents sd
  where sd.external_sale_no = p_external_sale_no
    and sd.voucher_no = p_voucher_no
  limit 1;

  if v_doc.id is null then
    raise exception 'Venta externa no encontrada';
  end if;

  if exists (
    select 1
    from public.dispatch_header dh
    where dh.sales_document_id = v_doc.id
      and dh.source_kind = 'external_sale'
  ) then
    select dh.id, dh.delivery_no
      into v_dispatch_id, v_delivery_no
    from public.dispatch_header dh
    where dh.sales_document_id = v_doc.id
      and dh.source_kind = 'external_sale'
    order by dh.created_at desc
    limit 1;

    return jsonb_build_object(
      'ok', true,
      'already_registered', true,
      'dispatch_id', v_dispatch_id,
      'delivery_no', v_delivery_no
    );
  end if;

  select coalesce(p.external_client_code::text, 'SIN EXP')
    into v_patient_code
  from public.patients p
  where p.id = v_doc.patient_id;

  v_patient_code := coalesce(nullif(v_patient_code, ''), 'SIN EXP');

  perform pg_advisory_xact_lock(hashtext('dispatch_external_sale_register'));

  if p_delivery_no is not null then
    select dh.id, dh.status
      into v_dispatch_id, v_existing_status
    from public.dispatch_header dh
    where dh.delivery_no = p_delivery_no
    for update;

    if v_dispatch_id is null then
      raise exception 'Entrega # no encontrada';
    end if;

    if exists (
      select 1
      from public.inventory_movements im
      where im.source_id = v_dispatch_id
        and im.source_type in ('dispatch_validate', 'dispatch_void', 'dispatch_adjust')
    ) then
      raise exception 'No se puede convertir una entrega con movimientos de inventario en venta externa conciliada';
    end if;

    update public.dispatch_header dh
       set expediente = v_patient_code,
           status = 'validated',
           created_by = v_user_id,
           created_at = (v_doc.sale_date::timestamp at time zone 'America/El_Salvador'),
           confirmed_at = (v_doc.sale_date::timestamp at time zone 'America/El_Salvador'),
           validated_by = v_user_id,
           validated_at = (v_doc.sale_date::timestamp at time zone 'America/El_Salvador'),
           observed_by = null,
           observed_at = null,
           observation_note = null,
           voided_by = null,
           voided_at = null,
           void_reason = null,
           source_kind = 'external_sale',
           inventory_effect = 'already_reconciled',
           sales_document_id = v_doc.id,
           external_sale_no = v_doc.external_sale_no,
           external_voucher_no = v_doc.voucher_no,
           external_sale_date = v_doc.sale_date,
           updated_at = now()
     where dh.id = v_dispatch_id;

    delete from public.dispatch_items di
    where di.dispatch_id = v_dispatch_id;

    v_delivery_no := p_delivery_no;
  else
    select coalesce(max(delivery_no), 0) + 1
      into v_delivery_no
    from public.dispatch_header;

    insert into public.dispatch_header(
      delivery_no,
      expediente,
      status,
      created_by,
      created_at,
      confirmed_at,
      validated_by,
      validated_at,
      source_kind,
      inventory_effect,
      sales_document_id,
      external_sale_no,
      external_voucher_no,
      external_sale_date
    )
    values (
      v_delivery_no,
      v_patient_code,
      'validated',
      v_user_id,
      (v_doc.sale_date::timestamp at time zone 'America/El_Salvador'),
      (v_doc.sale_date::timestamp at time zone 'America/El_Salvador'),
      v_user_id,
      (v_doc.sale_date::timestamp at time zone 'America/El_Salvador'),
      'external_sale',
      'already_reconciled',
      v_doc.id,
      v_doc.external_sale_no,
      v_doc.voucher_no,
      v_doc.sale_date
    )
    returning id into v_dispatch_id;
  end if;

  insert into public.dispatch_items(dispatch_id, barcode, product_name_snapshot, qty)
  select
    v_dispatch_id,
    m.barcode,
    coalesce(m.name, si.description_snapshot),
    sum(si.qty)::integer
  from public.sales_items si
  join public.medicines m on m.id = si.medicine_id
  where si.sales_document_id = v_doc.id
    and m.active is true
    and nullif(trim(m.barcode), '') is not null
  group by m.barcode, coalesce(m.name, si.description_snapshot);

  get diagnostics v_item_count = row_count;

  if v_item_count = 0 then
    raise exception 'La venta externa no tiene productos activos con codigo de barra para registrar en historico';
  end if;

  select coalesce(sum(qty), 0)::int
    into v_total_units
  from public.dispatch_items
  where dispatch_id = v_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'EXTERNAL_SALE_RECONCILED',
    v_user_id,
    v_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery_no,
      'external_sale_no', v_doc.external_sale_no,
      'voucher_no', v_doc.voucher_no,
      'sale_date', v_doc.sale_date,
      'inventory_effect', 'already_reconciled'
    )
  );

  return jsonb_build_object(
    'ok', true,
    'already_registered', false,
    'dispatch_id', v_dispatch_id,
    'delivery_no', v_delivery_no,
    'items_count', v_item_count,
    'total_units', v_total_units
  );
end;
$$;

grant execute on function public.rpc_dispatch_search(text, timestamp with time zone, timestamp with time zone, public.dispatch_status, text, bigint, uuid, integer, integer) to anon, authenticated;
grant execute on function public.rpc_dispatch_get(text, uuid) to anon, authenticated;
grant execute on function public.rpc_dispatch_get_by_delivery_no(text, bigint) to anon, authenticated;
grant execute on function public.rpc_cashier_validate(text, uuid) to anon, authenticated;
grant execute on function public.rpc_dispatch_void(text, uuid, text) to anon, authenticated;
grant execute on function public.rpc_dispatch_register_external_sale(text, integer, text, bigint) to anon, authenticated;
