-- Manual article creation/update from Catalog admin.

do $$
declare
  r record;
begin
  for r in
    select oid::regprocedure as signature
    from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('rpc_pharma_catalog_search', 'rpc_pharma_catalog_upsert', 'rpc_pharma_catalog_set_active')
  loop
    execute 'drop function if exists ' || r.signature;
  end loop;
end $$;

create or replace function public.rpc_pharma_catalog_search(
  p_session_token text,
  p_q text default null,
  p_barcode text default null,
  p_active boolean default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table(
  external_code integer,
  barcode text,
  product_name text,
  secondary_name text,
  model text,
  group_name text,
  subgroup_name text,
  price_1 numeric,
  reference_price numeric,
  active boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_role public.user_role;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');

  select u.role into v_user_role
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active is true
  limit 1;

  if v_user_role is distinct from 'admin'::public.user_role then
    raise exception 'No autorizado para consultar catalogo';
  end if;

  return query
  with latest_ref as (
    select distinct on (external_code)
      external_code,
      reference_price
    from public.medicine_reference_prices
    order by external_code, reference_date desc nulls last, source_loaded_at desc
  )
  select
    m.external_code,
    m.barcode,
    m.name as product_name,
    m.secondary_name,
    m.model,
    m.group_name,
    m.subgroup_name,
    m.price_1,
    coalesce(o.reference_price, lr.reference_price) as reference_price,
    m.active
  from public.medicines m
  left join latest_ref lr on lr.external_code = m.external_code
  left join public.medicine_reference_price_overrides o on o.external_code = m.external_code
  where (p_active is null or m.active = p_active)
    and (nullif(trim(coalesce(p_barcode, '')), '') is null or m.barcode = trim(p_barcode))
    and (
      nullif(trim(coalesce(p_q, '')), '') is null
      or m.name ilike '%' || trim(p_q) || '%'
      or coalesce(m.secondary_name, '') ilike '%' || trim(p_q) || '%'
      or coalesce(m.model, '') ilike '%' || trim(p_q) || '%'
      or coalesce(m.subgroup_name, '') ilike '%' || trim(p_q) || '%'
      or coalesce(m.barcode, '') ilike '%' || trim(p_q) || '%'
      or m.external_code::text ilike '%' || trim(p_q) || '%'
    )
  order by m.name
  limit greatest(1, least(coalesce(p_limit, 100), 500))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

grant execute on function public.rpc_pharma_catalog_search(text, text, text, boolean, integer, integer) to anon, authenticated;

create or replace function public.rpc_pharma_catalog_upsert(
  p_session_token text,
  p_barcode text default null,
  p_product_name text default null,
  p_active boolean default true,
  p_external_code integer default null,
  p_secondary_name text default null,
  p_model text default null,
  p_group_name text default null,
  p_subgroup_name text default null,
  p_price_1 numeric default null,
  p_reference_price numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_id uuid;
  v_user_role public.user_role;
  v_id uuid;
  v_external_code integer;
  v_barcode text;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');

  select u.id, u.role into v_user_id, v_user_role
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active is true
  limit 1;

  if v_user_role is distinct from 'admin'::public.user_role then
    raise exception 'No autorizado para guardar articulo';
  end if;

  if nullif(trim(coalesce(p_product_name, '')), '') is null then
    raise exception 'Nombre del articulo requerido';
  end if;

  if p_price_1 is not null and p_price_1 < 0 then
    raise exception 'Precio de venta invalido';
  end if;

  if p_reference_price is not null and p_reference_price < 0 then
    raise exception 'Precio de referencia invalido';
  end if;

  v_barcode := nullif(regexp_replace(coalesce(p_barcode, ''), '\D', '', 'g'), '');

  if v_barcode is not null then
    select id, external_code into v_id, v_external_code
    from public.medicines
    where barcode = v_barcode
    limit 1;
  end if;

  if v_id is null and p_external_code is not null then
    select id, external_code into v_id, v_external_code
    from public.medicines
    where external_code = p_external_code
    limit 1;
  end if;

  if v_id is null then
    if p_external_code is not null then
      v_external_code := p_external_code;
    else
      select coalesce(max(external_code), 0) + 1 into v_external_code
      from public.medicines;
    end if;

    insert into public.medicines(
      external_code, barcode, name, secondary_name, model, group_name, subgroup_name,
      price_1, active, inventory_item, source_file, source_loaded_at
    )
    values (
      v_external_code, v_barcode, trim(p_product_name), nullif(trim(coalesce(p_secondary_name, '')), ''),
      nullif(trim(coalesce(p_model, '')), ''), nullif(trim(coalesce(p_group_name, '')), ''),
      nullif(trim(coalesce(p_subgroup_name, '')), ''), p_price_1, coalesce(p_active, true),
      true, 'manual_catalog', now()
    )
    returning id into v_id;
  else
    if p_external_code is not null and p_external_code <> v_external_code then
      if exists (select 1 from public.medicines where external_code = p_external_code and id <> v_id) then
        raise exception 'Ya existe otro articulo con codigo %', p_external_code;
      end if;
      v_external_code := p_external_code;
    end if;

    update public.medicines
       set external_code = v_external_code,
           barcode = v_barcode,
           name = trim(p_product_name),
           secondary_name = nullif(trim(coalesce(p_secondary_name, '')), ''),
           model = nullif(trim(coalesce(p_model, '')), ''),
           group_name = nullif(trim(coalesce(p_group_name, '')), ''),
           subgroup_name = nullif(trim(coalesce(p_subgroup_name, '')), ''),
           price_1 = p_price_1,
           active = coalesce(p_active, true),
           inventory_item = true,
           source_file = coalesce(source_file, 'manual_catalog'),
           source_loaded_at = now()
     where id = v_id;
  end if;

  if p_reference_price is not null then
    insert into public.medicine_reference_price_overrides(
      medicine_id, external_code, reference_price, note, updated_by
    )
    values (v_id, v_external_code, p_reference_price, 'Editado desde catalogo manual', v_user_id)
    on conflict (external_code) do update
      set medicine_id = excluded.medicine_id,
          reference_price = excluded.reference_price,
          note = excluded.note,
          updated_by = excluded.updated_by,
          updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'external_code', v_external_code, 'barcode', v_barcode);
end;
$$;

grant execute on function public.rpc_pharma_catalog_upsert(text, text, text, boolean, integer, text, text, text, text, numeric, numeric) to anon, authenticated;

create or replace function public.rpc_pharma_catalog_set_active(
  p_session_token text,
  p_barcode text,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_user_role public.user_role;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');

  select u.role into v_user_role
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active is true
  limit 1;

  if v_user_role is distinct from 'admin'::public.user_role then
    raise exception 'No autorizado para cambiar estado';
  end if;

  update public.medicines
     set active = coalesce(p_active, true),
         updated_at = now()
   where barcode = nullif(regexp_replace(coalesce(p_barcode, ''), '\D', '', 'g'), '');

  if not found then
    raise exception 'Articulo no encontrado';
  end if;

  return jsonb_build_object('ok', true, 'barcode', p_barcode, 'active', p_active);
end;
$$;

grant execute on function public.rpc_pharma_catalog_set_active(text, text, boolean) to anon, authenticated;
