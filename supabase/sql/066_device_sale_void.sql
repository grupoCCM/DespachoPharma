-- Add controlled void flow for device sales.
-- Does not delete historical sale lines; it reverses unit status and writes a sale_void movement.

alter table public.device_sales
  add column if not exists voided_by uuid references public.app_users(id),
  add column if not exists voided_at timestamptz,
  add column if not exists void_reason text;

alter table public.device_sale_items
  add column if not exists voided_at timestamptz;

drop index if exists public.ux_device_sale_items_unit;
create unique index if not exists ux_device_sale_items_active_unit
on public.device_sale_items(device_unit_id)
where voided_at is null;

create or replace function public.rpc_device_sale_void(
  p_session_token text,
  p_sale_no bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_sale public.device_sales%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_item record;
  v_units integer := 0;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_role <> 'admin' then
    raise exception 'Solo administrador puede anular ventas de dispositivos';
  end if;

  if coalesce(p_sale_no, 0) <= 0 then
    raise exception 'Venta requerida';
  end if;

  if v_reason is null then
    raise exception 'Debe indicar un motivo para la anulacion';
  end if;

  select *
  into v_sale
  from public.device_sales
  where sale_no = p_sale_no
  for update;

  if v_sale.id is null then
    raise exception 'Venta de dispositivo no encontrada: %', p_sale_no;
  end if;

  if v_sale.status = 'voided' then
    raise exception 'Esta venta ya fue anulada previamente';
  end if;

  for v_item in
    select
      i.id as item_id,
      i.device_unit_id,
      i.device_product_id,
      i.serial_code
    from public.device_sale_items i
    where i.sale_id = v_sale.id
    order by i.serial_code
  loop
    update public.device_units
       set status = 'available',
           sold_at = null,
           sold_by = null,
           sale_id = null
     where id = v_item.device_unit_id
       and status = 'sold'
       and sale_id = v_sale.id;

    if not found then
      raise exception 'No se pudo devolver el dispositivo %. Revise su estado actual.', v_item.serial_code;
    end if;

    insert into public.device_inventory_movements(
      device_unit_id,
      device_product_id,
      serial_code,
      movement_type,
      qty_delta,
      source_type,
      source_id,
      source_event_key,
      note,
      created_by
    ) values (
      v_item.device_unit_id,
      v_item.device_product_id,
      v_item.serial_code,
      'sale_void',
      1,
      'device_sale_void',
      v_sale.id,
      'device_sale_void:' || v_sale.id::text || ':' || v_item.device_unit_id::text,
      'Anulacion de venta de dispositivo: ' || v_reason,
      v_user_id
    )
    on conflict (source_event_key) where source_event_key is not null do nothing;

    v_units := v_units + 1;
  end loop;

  update public.device_sale_items
     set voided_at = now()
   where sale_id = v_sale.id
     and voided_at is null;

  if v_units = 0 then
    raise exception 'La venta no tiene dispositivos registrados';
  end if;

  update public.device_sales
     set status = 'voided',
         voided_by = v_user_id,
         voided_at = now(),
         void_reason = v_reason
   where id = v_sale.id;

  return jsonb_build_object(
    'sale_no', p_sale_no,
    'status', 'voided',
    'units_returned', v_units
  );
end;
$$;

create or replace function public.rpc_device_sale_detail(
  p_session_token text,
  p_sale_no bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede consultar detalle de ventas de dispositivos';
  end if;

  return (
    select to_jsonb(x)
    from (
      select
        s.id as sale_id,
        s.sale_no,
        s.expediente,
        s.status,
        s.confirmed_at,
        s.created_at,
        s.note,
        u.display_name as created_by_name,
        vu.display_name as voided_by_name,
        s.voided_at,
        s.void_reason,
        coalesce((
          select jsonb_agg(to_jsonb(it) order by it.product_name, it.serial_code)
          from (
            select
              i.id as item_id,
              p.external_code,
              p.name as product_name,
              p.category,
              i.serial_code,
              i.price,
              i.cost,
              (coalesce(i.price,0) - coalesce(i.cost,0))::numeric(14,4) as gross_profit
            from public.device_sale_items i
            join public.device_products p on p.id = i.device_product_id
            where i.sale_id = s.id
            order by p.name, i.serial_code
          ) it
        ), '[]'::jsonb) as items
      from public.device_sales s
      left join public.app_users u on u.id = s.created_by
      left join public.app_users vu on vu.id = s.voided_by
      where s.sale_no = p_sale_no
      limit 1
    ) x
  );
end;
$$;

grant execute on function public.rpc_device_sale_void(text, bigint, text) to anon, authenticated;
grant execute on function public.rpc_device_sale_detail(text, bigint) to anon, authenticated;
