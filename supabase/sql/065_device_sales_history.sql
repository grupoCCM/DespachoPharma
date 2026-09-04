-- Device sales history reporting.
-- Isolated from pharmacy dispatch history.

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
      group by s.id, s.sale_no, s.expediente, s.status, s.confirmed_at, s.created_at, u.display_name
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
        s.confirmed_at,
        s.created_at,
        s.note,
        u.display_name as created_by_name,
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
      where s.sale_no = p_sale_no
      limit 1
    ) x
  );
end;
$$;

grant execute on function public.rpc_device_sales_history(text, timestamptz, timestamptz, text, text, integer, integer) to anon, authenticated;
grant execute on function public.rpc_device_sale_detail(text, bigint) to anon, authenticated;
