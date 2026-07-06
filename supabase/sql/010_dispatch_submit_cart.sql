create or replace function public.rpc_dispatch_submit_cart(
  p_session_token text,
  p_expediente text,
  p_items jsonb
)
returns table(dispatch_id uuid, delivery_no bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_dispatch_id uuid;
  v_delivery bigint;
  v_count int;
  v_item record;
  v_match record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role not in ('dispatch','admin') then
    raise exception 'Permiso denegado';
  end if;

  if nullif(trim(coalesce(p_expediente, '')), '') is null then
    raise exception 'Expediente requerido';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Carrito vacio';
  end if;

  select count(*)
    into v_count
  from (
    select
      nullif(regexp_replace(coalesce(item->>'barcode',''), '\D', '', 'g'), '') as barcode,
      sum(greatest(coalesce((item->>'qty')::int, 0), 0)) as qty
    from jsonb_array_elements(p_items) item
    group by 1
  ) grouped
  where barcode is not null and qty > 0;

  if coalesce(v_count, 0) = 0 then
    raise exception 'Carrito vacio';
  end if;

  for v_item in
    select
      nullif(regexp_replace(coalesce(item->>'barcode',''), '\D', '', 'g'), '') as barcode,
      sum(greatest(coalesce((item->>'qty')::int, 0), 0))::int as qty
    from jsonb_array_elements(p_items) item
    group by 1
  loop
    if v_item.barcode is null or v_item.qty <= 0 then
      raise exception 'Item invalido en carrito';
    end if;

    select * into v_match
    from public.app_pharma_match(v_item.barcode);

    if v_match.barcode is null then
      raise exception 'Barcode no existe en catalogo';
    end if;

    if v_match.active is distinct from true then
      raise exception 'Barcode existe pero esta inactivo';
    end if;

    perform public.dispatch_raise_if_stock_insufficient(v_match.barcode, v_item.qty, null);
  end loop;

  insert into public.dispatch_header(expediente, status, created_by, confirmed_at)
  values (trim(p_expediente), 'confirmed', v_user_id, now())
  returning id into v_dispatch_id;

  v_delivery := nextval('public.delivery_no_seq');

  update public.dispatch_header
     set delivery_no = v_delivery,
         updated_at = now()
   where id = v_dispatch_id;

  for v_item in
    select
      nullif(regexp_replace(coalesce(item->>'barcode',''), '\D', '', 'g'), '') as barcode,
      sum(greatest(coalesce((item->>'qty')::int, 0), 0))::int as qty
    from jsonb_array_elements(p_items) item
    group by 1
  loop
    select * into v_match
    from public.app_pharma_match(v_item.barcode);

    insert into public.dispatch_items(dispatch_id, barcode, product_name_snapshot, qty)
    values (v_dispatch_id, v_match.barcode, v_match.product_name, v_item.qty);
  end loop;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_SUBMIT_CART',
    v_user_id,
    v_dispatch_id,
    jsonb_build_object('delivery_no', v_delivery, 'items', v_count)
  );

  return query select v_dispatch_id, v_delivery;
end;
$$;

grant execute on function public.rpc_dispatch_submit_cart(text, text, jsonb) to anon, authenticated;
