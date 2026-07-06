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
    select distinct on (mrp.external_code)
      mrp.external_code,
      mrp.reference_price
    from public.medicine_reference_prices mrp
    order by mrp.external_code, mrp.loaded_at desc
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
