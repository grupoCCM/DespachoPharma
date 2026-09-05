-- Cashier validation flow for device exits.
-- Inventory is already discounted at dispatch; cashier only validates or observes the operational record.

alter table public.device_sales
  add column if not exists validated_by uuid references public.app_users(id),
  add column if not exists validated_at timestamptz,
  add column if not exists observed_by uuid references public.app_users(id),
  add column if not exists observed_at timestamptz,
  add column if not exists observation_note text;

alter table public.device_sales
  drop constraint if exists device_sales_status_check,
  add constraint device_sales_status_check check (status in ('confirmed','validated','observed','voided'));

create index if not exists idx_device_sales_status_confirmed_at
on public.device_sales(status, confirmed_at desc);

create or replace function public.rpc_device_cashier_search(
  p_session_token text,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_status text default null,
  p_sale_no bigint default null,
  p_limit integer default 200,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
  v_status text := lower(trim(coalesce(p_status, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 300));
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role not in ('cashier','admin') then
    raise exception 'Solo caja o administrador puede revisar salidas de dispositivos';
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
        s.validated_at,
        s.observed_at,
        s.observation_note,
        u.display_name as created_by_name,
        vu.display_name as validated_by_name,
        ou.display_name as observed_by_name,
        count(i.id)::integer as item_count,
        coalesce(sum(i.price), 0)::numeric(14,4) as total_sale,
        coalesce(sum(i.cost), 0)::numeric(14,4) as total_cost,
        (coalesce(sum(i.price), 0) - coalesce(sum(i.cost), 0))::numeric(14,4) as gross_profit,
        string_agg(distinct p.name, ' | ' order by p.name) as product_names,
        string_agg(i.serial_code, ', ' order by i.serial_code) as serial_codes
      from public.device_sales s
      left join public.device_sale_items i on i.sale_id = s.id
      left join public.device_products p on p.id = i.device_product_id
      left join public.app_users u on u.id = s.created_by
      left join public.app_users vu on vu.id = s.validated_by
      left join public.app_users ou on ou.id = s.observed_by
      where (p_date_from is null or s.confirmed_at >= p_date_from)
        and (p_date_to is null or s.confirmed_at <= p_date_to)
        and (v_status = '' or lower(s.status) = v_status)
        and (p_sale_no is null or s.sale_no = p_sale_no)
      group by
        s.id, s.sale_no, s.expediente, s.status, s.sale_type, s.replacement_reason,
        s.confirmed_at, s.created_at, s.validated_at, s.observed_at, s.observation_note,
        u.display_name, vu.display_name, ou.display_name
      order by s.confirmed_at desc, s.sale_no desc
      limit v_limit offset v_offset
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.rpc_device_cashier_get_by_sale_no(
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
  if v_role not in ('cashier','admin') then
    raise exception 'Solo caja o administrador puede consultar salidas de dispositivos';
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
        s.validated_at,
        s.observed_at,
        s.observation_note,
        u.display_name as created_by_name,
        vu.display_name as validated_by_name,
        ou.display_name as observed_by_name,
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
              (coalesce(i.price, 0) - coalesce(i.cost, 0))::numeric(14,4) as gross_profit
            from public.device_sale_items i
            join public.device_products p on p.id = i.device_product_id
            where i.sale_id = s.id
            order by p.name, i.serial_code
          ) it
        ), '[]'::jsonb) as items
      from public.device_sales s
      left join public.app_users u on u.id = s.created_by
      left join public.app_users vu on vu.id = s.validated_by
      left join public.app_users ou on ou.id = s.observed_by
      where s.sale_no = p_sale_no
      limit 1
    ) x
  );
end;
$$;

create or replace function public.rpc_device_cashier_validate(
  p_session_token text,
  p_sale_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_sale_no bigint;
  v_status text;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role not in ('cashier','admin') then
    raise exception 'Solo caja o administrador puede validar salidas de dispositivos';
  end if;

  select sale_no, status
  into v_sale_no, v_status
  from public.device_sales
  where id = p_sale_id
  for update;

  if v_sale_no is null then
    raise exception 'Salida de dispositivo no encontrada';
  end if;

  if v_status <> 'confirmed' then
    raise exception 'Solo se pueden validar salidas pendientes. Estado actual: %', v_status;
  end if;

  update public.device_sales
     set status = 'validated',
         validated_by = v_user_id,
         validated_at = now()
   where id = p_sale_id;

  return jsonb_build_object('sale_no', v_sale_no, 'status', 'validated');
end;
$$;

create or replace function public.rpc_device_cashier_observe(
  p_session_token text,
  p_sale_id uuid,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_sale_no bigint;
  v_status text;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role not in ('cashier','admin') then
    raise exception 'Solo caja o administrador puede observar salidas de dispositivos';
  end if;

  if v_note is null or length(v_note) < 3 then
    raise exception 'La observacion debe tener al menos 3 caracteres';
  end if;

  select sale_no, status
  into v_sale_no, v_status
  from public.device_sales
  where id = p_sale_id
  for update;

  if v_sale_no is null then
    raise exception 'Salida de dispositivo no encontrada';
  end if;

  if v_status <> 'confirmed' then
    raise exception 'Solo se pueden observar salidas pendientes. Estado actual: %', v_status;
  end if;

  update public.device_sales
     set status = 'observed',
         observed_by = v_user_id,
         observed_at = now(),
         observation_note = v_note
   where id = p_sale_id;

  return jsonb_build_object('sale_no', v_sale_no, 'status', 'observed');
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
        s.validated_at,
        s.observed_at,
        s.observation_note,
        u.display_name as created_by_name,
        vu.display_name as validated_by_name,
        ou.display_name as observed_by_name,
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
      left join public.app_users vu on vu.id = s.validated_by
      left join public.app_users ou on ou.id = s.observed_by
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
          or lower(coalesce(s.observation_note,'')) like '%' || v_q || '%'
          or lower(coalesce(u.display_name,'')) like '%' || v_q || '%'
          or lower(coalesce(vu.display_name,'')) like '%' || v_q || '%'
          or lower(coalesce(ou.display_name,'')) like '%' || v_q || '%'
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
      group by
        s.id, s.sale_no, s.expediente, s.status, s.sale_type, s.replacement_reason,
        s.confirmed_at, s.created_at, s.validated_at, s.observed_at, s.observation_note,
        u.display_name, vu.display_name, ou.display_name
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
        s.validated_at,
        s.observed_at,
        s.observation_note,
        u.display_name as created_by_name,
        vu.display_name as voided_by_name,
        s.voided_at,
        s.void_reason,
        val.display_name as validated_by_name,
        obs.display_name as observed_by_name,
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
      left join public.app_users val on val.id = s.validated_by
      left join public.app_users obs on obs.id = s.observed_by
      where s.sale_no = p_sale_no
      limit 1
    ) x
  );
end;
$$;

grant execute on function public.rpc_device_cashier_search(text, timestamptz, timestamptz, text, bigint, integer, integer) to anon, authenticated;
grant execute on function public.rpc_device_cashier_get_by_sale_no(text, bigint) to anon, authenticated;
grant execute on function public.rpc_device_cashier_validate(text, uuid) to anon, authenticated;
grant execute on function public.rpc_device_cashier_observe(text, uuid, text) to anon, authenticated;
grant execute on function public.rpc_device_sales_history(text, timestamptz, timestamptz, text, text, integer, integer) to anon, authenticated;
grant execute on function public.rpc_device_sale_detail(text, bigint) to anon, authenticated;

notify pgrst, 'reload schema';
