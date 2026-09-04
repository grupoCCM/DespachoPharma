-- Device replacement flow.
-- A replacement is an inventory exit that does not generate sale income.

alter table public.device_sales
  add column if not exists sale_type text not null default 'sale',
  add column if not exists replacement_reason text;

alter table public.device_sale_items
  add column if not exists sale_type text not null default 'sale';

alter table public.device_sales
  drop constraint if exists device_sales_sale_type_check,
  add constraint device_sales_sale_type_check check (sale_type in ('sale','replacement'));

alter table public.device_sale_items
  drop constraint if exists device_sale_items_sale_type_check,
  add constraint device_sale_items_sale_type_check check (sale_type in ('sale','replacement'));

alter table public.device_inventory_movements
  drop constraint if exists device_inventory_movements_type_check,
  add constraint device_inventory_movements_type_check
    check (movement_type in ('receive','sale','replacement','sale_void','admin_adjustment'));

create index if not exists idx_device_sales_sale_type on public.device_sales(sale_type);

create or replace function public.rpc_device_dispatch_submit(
  p_session_token text,
  p_expediente text,
  p_serials jsonb,
  p_sale_type text default 'sale',
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
  v_sale_id uuid;
  v_sale_no bigint;
  v_serials text[];
  v_serial text;
  v_unit public.device_units%rowtype;
  v_product public.device_products%rowtype;
  v_sale_type text := lower(trim(coalesce(p_sale_type, 'sale')));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_price numeric(14,4);
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'dispatch' then
    raise exception 'Solo despacho puede vender dispositivos';
  end if;

  if v_sale_type not in ('sale','replacement') then
    raise exception 'Tipo de salida invalido: %', p_sale_type;
  end if;

  if v_sale_type = 'replacement' and v_reason is null then
    raise exception 'Debe indicar el motivo de la reposicion';
  end if;

  if length(trim(coalesce(p_expediente,''))) = 0 then
    raise exception 'Expediente requerido';
  end if;

  select array_agg(distinct lower(regexp_replace(trim(value), '\s+', '', 'g')))
  into v_serials
  from jsonb_array_elements_text(coalesce(p_serials, '[]'::jsonb)) as serial_items(value)
  where length(trim(value)) > 0;

  if coalesce(array_length(v_serials, 1), 0) = 0 then
    raise exception 'Agrega al menos un dispositivo';
  end if;

  insert into public.device_sales(expediente, status, created_by, sale_type, replacement_reason, note)
  values (
    trim(p_expediente),
    'confirmed',
    v_user_id,
    v_sale_type,
    case when v_sale_type = 'replacement' then v_reason else null end,
    case when v_sale_type = 'replacement' then 'Reposicion: ' || v_reason else null end
  )
  returning id, sale_no into v_sale_id, v_sale_no;

  foreach v_serial in array v_serials loop
    select * into v_unit
    from public.device_units
    where normalized_serial = v_serial
    for update;

    if v_unit.id is null then
      raise exception 'Codigo unico no registrado: %', v_serial;
    end if;

    if v_unit.status <> 'available' then
      raise exception 'El dispositivo % no esta disponible. Estado actual: %', v_unit.serial_code, v_unit.status;
    end if;

    select * into v_product
    from public.device_products
    where id = v_unit.device_product_id
    for update;

    if v_product.id is null or v_product.active is distinct from true then
      raise exception 'Producto no activo para el dispositivo %', v_unit.serial_code;
    end if;

    v_price := case when v_sale_type = 'replacement' then 0 else coalesce(v_product.sale_price, 0) end;

    update public.device_units
    set status = 'sold',
        sold_at = now(),
        sold_by = v_user_id,
        sale_id = v_sale_id
    where id = v_unit.id;

    insert into public.device_sale_items(
      sale_id, device_unit_id, device_product_id, serial_code, product_name_snapshot, price, cost, sale_type
    ) values (
      v_sale_id, v_unit.id, v_product.id, v_unit.serial_code, v_product.name, v_price, v_unit.cost, v_sale_type
    );

    insert into public.device_inventory_movements(
      device_unit_id, device_product_id, serial_code, movement_type, qty_delta,
      source_type, source_id, source_event_key, note, created_by
    ) values (
      v_unit.id, v_product.id, v_unit.serial_code, v_sale_type, -1,
      'device_sale', v_sale_id, 'device_sale:' || v_sale_id::text || ':' || v_unit.id::text,
      case
        when v_sale_type = 'replacement' then 'Reposicion de dispositivo: ' || v_reason
        else 'Venta definitiva de dispositivo'
      end,
      v_user_id
    );
  end loop;

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_no', v_sale_no,
    'items', array_length(v_serials, 1),
    'sale_type', v_sale_type
  );
end;
$$;

create or replace function public.rpc_device_sales_history(
  p_session_token text,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_query text default '',
  p_status text default '',
  p_limit integer default 80,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
  v_q text := lower(trim(coalesce(p_query,'')));
  v_status text := lower(trim(coalesce(p_status,'')));
  v_limit integer := greatest(1, least(coalesce(p_limit,80), 200));
  v_offset integer := greatest(coalesce(p_offset,0), 0);
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede consultar historico de ventas de dispositivos';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.confirmed_at desc, x.sale_no desc)
    from (
      select
        s.id as sale_id,
        s.sale_no,
        s.expediente,
        s.status,
        s.sale_type,
        s.replacement_reason,
        s.confirmed_at,
        s.created_at,
        u.display_name as created_by_name,
        count(i.id)::integer as item_count,
        coalesce(sum(i.price),0)::numeric(14,4) as total_sale,
        coalesce(sum(i.cost),0)::numeric(14,4) as total_cost,
        (coalesce(sum(i.price),0) - coalesce(sum(i.cost),0))::numeric(14,4) as gross_profit,
        string_agg(distinct p.name, ' | ' order by p.name) as product_names,
        string_agg(i.serial_code, ', ' order by i.serial_code) as serial_codes
      from public.device_sales s
      left join public.device_sale_items i on i.sale_id = s.id
      left join public.device_products p on p.id = i.device_product_id
      left join public.app_users u on u.id = s.created_by
      where (p_date_from is null or s.confirmed_at >= p_date_from)
        and (p_date_to is null or s.confirmed_at <= p_date_to)
        and (v_status = '' or lower(s.status) = v_status)
        and (
          v_q = ''
          or s.sale_no::text = v_q
          or lower(coalesce(s.expediente,'')) like '%' || v_q || '%'
          or lower(coalesce(s.sale_type,'')) like '%' || v_q || '%'
          or (v_q in ('reposicion','reposición') and s.sale_type = 'replacement')
          or lower(coalesce(s.replacement_reason,'')) like '%' || v_q || '%'
          or lower(coalesce(u.display_name,'')) like '%' || v_q || '%'
          or exists (
            select 1
            from public.device_sale_items qi
            join public.device_products qp on qp.id = qi.device_product_id
            where qi.sale_id = s.id
              and (
                lower(qi.serial_code) like '%' || v_q || '%'
                or lower(qp.name) like '%' || v_q || '%'
                or qp.external_code::text = v_q
              )
          )
        )
      group by s.id, s.sale_no, s.expediente, s.status, s.sale_type, s.replacement_reason, s.confirmed_at, s.created_at, u.display_name
      order by s.confirmed_at desc, s.sale_no desc
      limit v_limit offset v_offset
    ) x
  ), '[]'::jsonb);
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
        s.sale_type,
        s.replacement_reason,
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
              coalesce(i.sale_type, s.sale_type) as sale_type,
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

grant execute on function public.rpc_device_dispatch_submit(text, text, jsonb, text, text) to anon, authenticated;
grant execute on function public.rpc_device_sales_history(text, timestamptz, timestamptz, text, text, integer, integer) to anon, authenticated;
grant execute on function public.rpc_device_sale_detail(text, bigint) to anon, authenticated;

notify pgrst, 'reload schema';
