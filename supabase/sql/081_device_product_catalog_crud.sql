-- Admin CRUD for the device product catalog.
-- Additive rollout: existing products, units, sales and movements are not modified.

alter table public.device_products
  add column if not exists generic_barcode text,
  add column if not exists internal_notes text;

create unique index if not exists ux_device_products_generic_barcode
on public.device_products (lower(trim(generic_barcode)))
where nullif(trim(generic_barcode), '') is not null;

create or replace view public.vw_device_inventory_state
with (security_invoker = true) as
select
  p.id as device_product_id,
  p.external_code,
  p.name,
  p.category,
  p.brand_name,
  p.model,
  p.active,
  count(u.id) filter (where u.status = 'available' and p.active)::integer as available_qty,
  count(u.id) filter (where u.status = 'sold')::integer as sold_qty,
  count(u.id) filter (
    where u.status in ('inactive','damaged','lost','retired')
       or (u.status = 'available' and not p.active)
  )::integer as unavailable_qty,
  count(u.id)::integer as physical_units,
  coalesce(sum(u.cost) filter (where u.status = 'available' and p.active), 0)::numeric(14,4) as available_cost_value
from public.device_products p
left join public.device_units u on u.device_product_id = p.id
group by p.id, p.external_code, p.name, p.category, p.brand_name, p.model, p.active;

create table if not exists public.device_product_admin_audit (
  id uuid primary key default gen_random_uuid(),
  device_product_id uuid not null,
  action text not null,
  reason text not null,
  old_data jsonb,
  new_data jsonb,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  constraint device_product_admin_audit_action_check
    check (action in ('product_create','product_update','product_activate','product_deactivate','product_delete'))
);

create index if not exists idx_device_product_admin_audit_product_created
on public.device_product_admin_audit(device_product_id, created_at desc);

alter table public.device_product_admin_audit enable row level security;

create or replace function public.rpc_device_product_admin_list(
  p_session_token text,
  p_query text default '',
  p_status text default 'all',
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
  v_q text := lower(trim(coalesce(p_query,'')));
  v_status text := lower(trim(coalesce(p_status,'all')));
  v_limit integer := greatest(1, least(coalesce(p_limit,200), 500));
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede consultar el catalogo de dispositivos';
  end if;

  if v_status not in ('all','active','inactive') then
    raise exception 'Filtro de estado no valido';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.name, x.external_code)
    from (
      select
        p.*,
        (select count(*)::integer from public.device_units u where u.device_product_id = p.id) as unit_count,
        (select count(*)::integer from public.device_units u where u.device_product_id = p.id and u.status = 'available' and p.active) as available_qty,
        (select count(*)::integer from public.device_sale_items i where i.device_product_id = p.id) as sale_item_count,
        (select count(*)::integer from public.device_inventory_movements m where m.device_product_id = p.id) as movement_count,
        not exists (select 1 from public.device_units u where u.device_product_id = p.id)
          and not exists (select 1 from public.device_sale_items i where i.device_product_id = p.id)
          and not exists (select 1 from public.device_inventory_movements m where m.device_product_id = p.id) as can_delete
      from public.device_products p
      where (v_status = 'all'
          or (v_status = 'active' and p.active)
          or (v_status = 'inactive' and not p.active))
        and (
          v_q = ''
          or p.external_code::text = v_q
          or lower(p.name) like '%' || v_q || '%'
          or lower(coalesce(p.secondary_name,'')) like '%' || v_q || '%'
          or lower(coalesce(p.category,'')) like '%' || v_q || '%'
          or lower(coalesce(p.brand_name,'')) like '%' || v_q || '%'
          or lower(coalesce(p.model,'')) like '%' || v_q || '%'
          or lower(coalesce(p.generic_barcode,'')) like '%' || v_q || '%'
        )
      order by p.name, p.external_code
      limit v_limit
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.rpc_device_product_create(
  p_session_token text,
  p_external_code integer,
  p_name text,
  p_secondary_name text default null,
  p_category text default null,
  p_brand_code integer default null,
  p_brand_name text default null,
  p_model text default null,
  p_presentation_name text default null,
  p_generic_barcode text default null,
  p_sale_price numeric default null,
  p_default_cost numeric default null,
  p_requires_serial boolean default true,
  p_requires_expiration boolean default false,
  p_internal_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_product public.device_products%rowtype;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede crear productos de dispositivos';
  end if;

  if coalesce(p_external_code,0) <= 0 then raise exception 'Codigo interno requerido'; end if;
  if nullif(trim(coalesce(p_name,'')), '') is null then raise exception 'Nombre requerido'; end if;
  if nullif(trim(coalesce(p_category,'')), '') is null then raise exception 'Categoria requerida'; end if;
  if coalesce(p_sale_price,0) < 0 or coalesce(p_default_cost,0) < 0 then
    raise exception 'Costo y precio no pueden ser negativos';
  end if;
  if exists (select 1 from public.device_products where external_code = p_external_code) then
    raise exception 'Ya existe un producto con el codigo interno %', p_external_code;
  end if;
  if nullif(trim(coalesce(p_generic_barcode,'')), '') is not null and exists (
    select 1 from public.device_products
    where lower(trim(generic_barcode)) = lower(trim(p_generic_barcode))
  ) then
    raise exception 'El codigo de barras general ya pertenece a otro producto';
  end if;

  insert into public.device_products(
    external_code, name, secondary_name, category, brand_code, brand_name, model,
    presentation_name, generic_barcode, sale_price, default_cost, active,
    requires_serial, requires_expiration, internal_notes, source_file
  ) values (
    p_external_code, trim(p_name), nullif(trim(coalesce(p_secondary_name,'')), ''),
    nullif(trim(coalesce(p_category,'')), ''), p_brand_code,
    nullif(trim(coalesce(p_brand_name,'')), ''), nullif(trim(coalesce(p_model,'')), ''),
    nullif(trim(coalesce(p_presentation_name,'')), ''), nullif(trim(coalesce(p_generic_barcode,'')), ''),
    p_sale_price, p_default_cost, true, coalesce(p_requires_serial,true),
    coalesce(p_requires_expiration,false), nullif(trim(coalesce(p_internal_notes,'')), ''),
    'Catalogo UI'
  ) returning * into v_product;

  insert into public.device_product_admin_audit(
    device_product_id, action, reason, old_data, new_data, created_by
  ) values (
    v_product.id, 'product_create', 'Creacion desde catalogo administrativo', null, to_jsonb(v_product), v_user_id
  );

  return jsonb_build_object('status','created','product',to_jsonb(v_product));
end;
$$;

create or replace function public.rpc_device_product_update(
  p_session_token text,
  p_device_product_id uuid,
  p_external_code integer,
  p_name text,
  p_secondary_name text default null,
  p_category text default null,
  p_brand_code integer default null,
  p_brand_name text default null,
  p_model text default null,
  p_presentation_name text default null,
  p_generic_barcode text default null,
  p_sale_price numeric default null,
  p_default_cost numeric default null,
  p_requires_serial boolean default true,
  p_requires_expiration boolean default false,
  p_internal_notes text default null,
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
  v_old public.device_products%rowtype;
  v_new public.device_products%rowtype;
  v_has_history boolean;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then raise exception 'Solo administrador puede editar productos de dispositivos'; end if;
  if v_reason is null then raise exception 'Motivo requerido para editar el producto'; end if;
  if coalesce(p_external_code,0) <= 0 then raise exception 'Codigo interno requerido'; end if;
  if nullif(trim(coalesce(p_name,'')), '') is null then raise exception 'Nombre requerido'; end if;
  if nullif(trim(coalesce(p_category,'')), '') is null then raise exception 'Categoria requerida'; end if;
  if coalesce(p_sale_price,0) < 0 or coalesce(p_default_cost,0) < 0 then
    raise exception 'Costo y precio no pueden ser negativos';
  end if;

  select * into v_old from public.device_products where id = p_device_product_id for update;
  if v_old.id is null then raise exception 'Producto no encontrado'; end if;

  select exists(select 1 from public.device_units where device_product_id = p_device_product_id)
      or exists(select 1 from public.device_sale_items where device_product_id = p_device_product_id)
      or exists(select 1 from public.device_inventory_movements where device_product_id = p_device_product_id)
  into v_has_history;

  if v_has_history and p_external_code <> v_old.external_code then
    raise exception 'El codigo interno no puede cambiar porque el producto ya tiene historial';
  end if;
  if v_has_history and coalesce(p_requires_serial,true) <> v_old.requires_serial then
    raise exception 'El tipo de control por codigo unico no puede cambiar porque el producto ya tiene historial';
  end if;
  if exists (
    select 1 from public.device_products
    where external_code = p_external_code and id <> p_device_product_id
  ) then raise exception 'Ya existe otro producto con el codigo interno %', p_external_code; end if;
  if nullif(trim(coalesce(p_generic_barcode,'')), '') is not null and exists (
    select 1 from public.device_products
    where lower(trim(generic_barcode)) = lower(trim(p_generic_barcode)) and id <> p_device_product_id
  ) then raise exception 'El codigo de barras general ya pertenece a otro producto'; end if;

  update public.device_products set
    external_code = p_external_code,
    name = trim(p_name),
    secondary_name = nullif(trim(coalesce(p_secondary_name,'')), ''),
    category = nullif(trim(coalesce(p_category,'')), ''),
    brand_code = p_brand_code,
    brand_name = nullif(trim(coalesce(p_brand_name,'')), ''),
    model = nullif(trim(coalesce(p_model,'')), ''),
    presentation_name = nullif(trim(coalesce(p_presentation_name,'')), ''),
    generic_barcode = nullif(trim(coalesce(p_generic_barcode,'')), ''),
    sale_price = p_sale_price,
    default_cost = p_default_cost,
    requires_serial = coalesce(p_requires_serial,true),
    requires_expiration = coalesce(p_requires_expiration,false),
    internal_notes = nullif(trim(coalesce(p_internal_notes,'')), '')
  where id = p_device_product_id
  returning * into v_new;

  insert into public.device_product_admin_audit(
    device_product_id, action, reason, old_data, new_data, created_by
  ) values (v_new.id, 'product_update', v_reason, to_jsonb(v_old), to_jsonb(v_new), v_user_id);

  return jsonb_build_object('status','updated','product',to_jsonb(v_new));
end;
$$;

create or replace function public.rpc_device_product_set_active(
  p_session_token text,
  p_device_product_id uuid,
  p_active boolean,
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
  v_old public.device_products%rowtype;
  v_new public.device_products%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then raise exception 'Solo administrador puede cambiar el estado del producto'; end if;
  if v_reason is null then raise exception 'Motivo requerido para cambiar el estado'; end if;

  select * into v_old from public.device_products where id = p_device_product_id for update;
  if v_old.id is null then raise exception 'Producto no encontrado'; end if;

  update public.device_products set active = coalesce(p_active,false)
  where id = p_device_product_id returning * into v_new;

  insert into public.device_product_admin_audit(
    device_product_id, action, reason, old_data, new_data, created_by
  ) values (
    v_new.id,
    case when v_new.active then 'product_activate' else 'product_deactivate' end,
    v_reason, to_jsonb(v_old), to_jsonb(v_new), v_user_id
  );

  return jsonb_build_object('status',case when v_new.active then 'active' else 'inactive' end,'product',to_jsonb(v_new));
end;
$$;

create or replace function public.rpc_device_product_delete(
  p_session_token text,
  p_device_product_id uuid,
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
  v_old public.device_products%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then raise exception 'Solo administrador puede eliminar productos de dispositivos'; end if;
  if v_reason is null then raise exception 'Motivo requerido para eliminar el producto'; end if;

  select * into v_old from public.device_products where id = p_device_product_id for update;
  if v_old.id is null then raise exception 'Producto no encontrado'; end if;

  if exists(select 1 from public.device_units where device_product_id = p_device_product_id)
     or exists(select 1 from public.device_sale_items where device_product_id = p_device_product_id)
     or exists(select 1 from public.device_inventory_movements where device_product_id = p_device_product_id) then
    raise exception 'El producto tiene historial y no puede eliminarse. Desactivalo para conservar la trazabilidad.';
  end if;

  insert into public.device_product_admin_audit(
    device_product_id, action, reason, old_data, new_data, created_by
  ) values (v_old.id, 'product_delete', v_reason, to_jsonb(v_old), null, v_user_id);

  delete from public.device_products where id = p_device_product_id;
  return jsonb_build_object('status','deleted','device_product_id',p_device_product_id);
end;
$$;

revoke all on table public.device_product_admin_audit from public, anon, authenticated;
revoke all on public.vw_device_inventory_state from anon, authenticated;
revoke execute on function public.rpc_device_product_admin_list(text, text, text, integer) from public;
revoke execute on function public.rpc_device_product_create(text, integer, text, text, text, integer, text, text, text, text, numeric, numeric, boolean, boolean, text) from public;
revoke execute on function public.rpc_device_product_update(text, uuid, integer, text, text, text, integer, text, text, text, text, numeric, numeric, boolean, boolean, text, text) from public;
revoke execute on function public.rpc_device_product_set_active(text, uuid, boolean, text) from public;
revoke execute on function public.rpc_device_product_delete(text, uuid, text) from public;
grant execute on function public.rpc_device_product_admin_list(text, text, text, integer) to anon, authenticated;
grant execute on function public.rpc_device_product_create(text, integer, text, text, text, integer, text, text, text, text, numeric, numeric, boolean, boolean, text) to anon, authenticated;
grant execute on function public.rpc_device_product_update(text, uuid, integer, text, text, text, integer, text, text, text, text, numeric, numeric, boolean, boolean, text, text) to anon, authenticated;
grant execute on function public.rpc_device_product_set_active(text, uuid, boolean, text) to anon, authenticated;
grant execute on function public.rpc_device_product_delete(text, uuid, text) to anon, authenticated;
