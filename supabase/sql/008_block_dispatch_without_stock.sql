create or replace function public.dispatch_stock_check(
  p_barcode text,
  p_requested_qty numeric,
  p_exclude_dispatch_id uuid default null
)
returns table(
  external_code integer,
  medicine_name text,
  stock_qty numeric,
  reserved_qty numeric,
  available_qty numeric,
  requested_qty numeric,
  ok boolean
)
language sql
security definer
set search_path = public
as $$
with med as (
  select m.external_code, m.name as medicine_name
  from public.medicines m
  where m.barcode = p_barcode
  order by m.active desc, m.external_code
  limit 1
),
reserved as (
  select coalesce(sum(di.qty), 0)::numeric as qty
  from public.dispatch_items di
  join public.dispatch_header dh on dh.id = di.dispatch_id
  where di.barcode = p_barcode
    and dh.status = 'confirmed'
    and (p_exclude_dispatch_id is null or dh.id <> p_exclude_dispatch_id)
)
select
  med.external_code,
  med.medicine_name,
  coalesce(vl.stock_qty, 0)::numeric as stock_qty,
  reserved.qty as reserved_qty,
  greatest(coalesce(vl.stock_qty, 0)::numeric - reserved.qty, 0) as available_qty,
  coalesce(p_requested_qty, 0)::numeric as requested_qty,
  med.external_code is not null
    and coalesce(p_requested_qty, 0) > 0
    and greatest(coalesce(vl.stock_qty, 0)::numeric - reserved.qty, 0) >= coalesce(p_requested_qty, 0)::numeric as ok
from med
cross join reserved
left join public.vw_inventory_live vl on vl.external_code = med.external_code;
$$;

create or replace function public.dispatch_raise_if_stock_insufficient(
  p_barcode text,
  p_requested_qty numeric,
  p_exclude_dispatch_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
begin
  select *
    into v_check
  from public.dispatch_stock_check(p_barcode, p_requested_qty, p_exclude_dispatch_id);

  if v_check.external_code is null then
    raise exception 'No se puede despachar: el barcode % no cruza con inventario', p_barcode;
  end if;

  if v_check.ok is not true then
    raise exception 'No se puede despachar %. Solicitado: %, disponible: %, existencia: %, reservado: %',
      coalesce(v_check.medicine_name, p_barcode),
      v_check.requested_qty,
      v_check.available_qty,
      v_check.stock_qty,
      v_check.reserved_qty;
  end if;
end;
$$;

create or replace function public.rpc_dispatch_add_item(p_session_token text, p_dispatch_id uuid, p_barcode text, p_qty integer default 1)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_name text;
  v_owner uuid;
  v_status public.dispatch_status;
  v_match_barcode text;
  v_active boolean;
  v_current_draft_qty integer;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role not in ('dispatch','admin') then
    raise exception 'Permiso denegado';
  end if;

  if p_qty is null or p_qty < 1 then
    raise exception 'Cantidad inválida';
  end if;

  select created_by, status into v_owner, v_status
  from public.dispatch_header
  where id = p_dispatch_id;

  if not found then
    raise exception 'Despacho no existe';
  end if;

  if v_status <> 'draft' then
    raise exception 'Solo se puede agregar en estado draft';
  end if;

  if v_role <> 'admin' and v_owner <> v_user_id then
    raise exception 'Solo el creador puede modificar este draft';
  end if;

  select barcode, product_name, active
    into v_match_barcode, v_name, v_active
  from public.app_pharma_match(p_barcode);

  if v_match_barcode is null then
    raise exception 'Barcode no existe en catálogo';
  end if;

  if v_active is distinct from true then
    raise exception 'Barcode existe pero está inactivo';
  end if;

  select coalesce(sum(qty), 0)::integer
    into v_current_draft_qty
  from public.dispatch_items
  where dispatch_id = p_dispatch_id
    and barcode = v_match_barcode;

  perform public.dispatch_raise_if_stock_insufficient(
    v_match_barcode,
    v_current_draft_qty + p_qty,
    p_dispatch_id
  );

  insert into public.dispatch_items(dispatch_id, barcode, product_name_snapshot, qty)
  values (p_dispatch_id, v_match_barcode, v_name, p_qty)
  on conflict (dispatch_id, barcode)
  do update set
    qty = public.dispatch_items.qty + excluded.qty,
    product_name_snapshot = public.dispatch_items.product_name_snapshot,
    updated_at = now();

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_ADD_ITEM',
    v_user_id,
    p_dispatch_id,
    jsonb_build_object(
      'barcode_input', p_barcode,
      'barcode_matched', v_match_barcode,
      'qty', p_qty,
      'product_name_snapshot', v_name
    )
  );
end;
$$;

create or replace function public.rpc_dispatch_confirm(p_session_token text, p_dispatch_id uuid)
returns table(delivery_no bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_owner uuid;
  v_status public.dispatch_status;
  v_cnt int;
  v_delivery bigint;
  v_item record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role not in ('dispatch','admin') then
    raise exception 'Permiso denegado';
  end if;

  select created_by, status into v_owner, v_status
  from public.dispatch_header
  where id = p_dispatch_id;

  if v_status <> 'draft' then
    raise exception 'Solo se puede confirmar desde draft';
  end if;

  if v_role <> 'admin' and v_owner <> v_user_id then
    raise exception 'Solo el creador puede confirmar este draft';
  end if;

  select count(*) into v_cnt
  from public.dispatch_items
  where dispatch_id = p_dispatch_id;

  if v_cnt <= 0 then
    raise exception 'No puedes confirmar un despacho vacío';
  end if;

  for v_item in
    select barcode, sum(qty)::numeric as qty
    from public.dispatch_items
    where dispatch_id = p_dispatch_id
    group by barcode
  loop
    perform public.dispatch_raise_if_stock_insufficient(v_item.barcode, v_item.qty, p_dispatch_id);
  end loop;

  v_delivery := nextval('public.delivery_no_seq');

  update public.dispatch_header
     set status = 'confirmed',
         delivery_no = v_delivery,
         confirmed_at = now()
   where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_CONFIRM',
    v_user_id,
    p_dispatch_id,
    jsonb_build_object('delivery_no', v_delivery, 'items', v_cnt)
  );

  return query select v_delivery;
end;
$$;

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

  select status into v_status
  from public.dispatch_header
  where id = p_dispatch_id;

  if v_status <> 'confirmed' then
    raise exception 'Solo se puede validar si está confirmed';
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

grant execute on function public.dispatch_stock_check(text, numeric, uuid) to anon, authenticated;
