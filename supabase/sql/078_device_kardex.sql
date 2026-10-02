-- Paginated, read-only device Kardex.
-- Uses the immutable movement ledger and does not alter historical data.

create or replace function public.rpc_device_kardex(
  p_session_token text,
  p_query text default '',
  p_product_code integer default null,
  p_movement_type text default 'all',
  p_date_from date default null,
  p_date_to date default null,
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
  v_query text := lower(trim(coalesce(p_query, '')));
  v_movement_type text := lower(trim(coalesce(p_movement_type, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := greatest(10, least(coalesce(p_page_size, 25), 100));
begin
  select role into v_role
  from public.app_require_session(p_session_token);

  if v_role not in ('admin', 'cashier', 'dispatch') then
    raise exception 'No autorizado para consultar Kardex de dispositivos';
  end if;

  if p_date_from is not null and p_date_to is not null and p_date_to < p_date_from then
    raise exception 'La fecha hasta no puede ser anterior a la fecha desde';
  end if;

  if v_movement_type not in ('all', 'receive', 'sale', 'replacement', 'sale_void', 'admin_adjustment') then
    raise exception 'Tipo de movimiento invalido: %', p_movement_type;
  end if;

  return (
    with ranked as (
      select
        m.id as movement_id,
        m.created_at,
        (m.created_at at time zone 'America/El_Salvador')::date as movement_date,
        m.movement_type,
        m.qty_delta,
        m.serial_code,
        m.source_type,
        m.source_id,
        m.note,
        p.id as device_product_id,
        p.external_code,
        p.name as product_name,
        p.category,
        du.source_doc_no,
        s.sale_no,
        s.expediente,
        au.display_name as user_name,
        sum(m.qty_delta) over (
          partition by m.device_product_id
          order by m.created_at, m.id
          rows between unbounded preceding and current row
        )::integer as product_balance_after
      from public.device_inventory_movements m
      join public.device_products p on p.id = m.device_product_id
      left join public.device_units du on du.id = m.device_unit_id
      left join public.device_sales s
        on s.id = m.source_id
       and m.source_type in ('device_sale', 'device_sale_void')
      left join public.app_users au on au.id = m.created_by
    ), period_scope as (
      select *
      from ranked r
      where (p_product_code is null or r.external_code = p_product_code)
        and (p_date_from is null or r.movement_date >= p_date_from)
        and (p_date_to is null or r.movement_date <= p_date_to)
    ), row_scope as (
      select *
      from period_scope r
      where (v_movement_type = 'all' or r.movement_type = v_movement_type)
        and (
          v_query = ''
          or lower(coalesce(r.serial_code, '')) like '%' || v_query || '%'
          or lower(r.product_name) like '%' || v_query || '%'
          or r.external_code::text = v_query
          or lower(coalesce(r.expediente, '')) like '%' || v_query || '%'
          or lower(coalesce(r.user_name, '')) like '%' || v_query || '%'
          or lower(coalesce(r.source_doc_no, '')) like '%' || v_query || '%'
          or r.sale_no::text = v_query
        )
    ), summary as (
      select
        coalesce(sum(qty_delta) filter (where movement_type = 'receive' and qty_delta > 0), 0)::integer as receipts,
        coalesce(abs(sum(qty_delta) filter (where movement_type = 'sale' and qty_delta < 0)), 0)::integer as sales,
        coalesce(abs(sum(qty_delta) filter (where movement_type = 'replacement' and qty_delta < 0)), 0)::integer as replacements,
        coalesce(sum(qty_delta) filter (where movement_type = 'sale_void' and qty_delta > 0), 0)::integer as reinstatements,
        coalesce(sum(qty_delta) filter (where movement_type = 'admin_adjustment'), 0)::integer as adjustments_net
      from period_scope
    ), totals as (
      select
        case
          when p_date_from is null then 0
          else coalesce(sum(qty_delta) filter (where movement_date < p_date_from), 0)
        end::integer as opening_balance,
        coalesce(sum(qty_delta) filter (where p_date_to is null or movement_date <= p_date_to), 0)::integer as closing_balance
      from ranked
      where p_product_code is null or external_code = p_product_code
    ), counted as (
      select count(*)::integer as total_rows from row_scope
    ), page_rows as (
      select
        movement_id,
        created_at,
        movement_type,
        qty_delta,
        case when qty_delta > 0 then qty_delta else 0 end::integer as entry_qty,
        case when qty_delta < 0 then abs(qty_delta) else 0 end::integer as exit_qty,
        product_balance_after,
        external_code,
        product_name,
        category,
        serial_code,
        case
          when sale_no is not null then '#' || sale_no::text
          when nullif(trim(coalesce(source_doc_no, '')), '') is not null then source_doc_no
          else coalesce(source_type, '-')
        end as reference,
        sale_no,
        expediente,
        user_name,
        note
      from row_scope
      order by created_at desc, movement_id desc
      limit v_page_size
      offset (v_page - 1) * v_page_size
    )
    select jsonb_build_object(
      'summary', jsonb_build_object(
        'opening_balance', t.opening_balance,
        'receipts', s.receipts,
        'sales', s.sales,
        'replacements', s.replacements,
        'reinstatements', s.reinstatements,
        'adjustments_net', s.adjustments_net,
        'closing_balance', t.closing_balance,
        'total_rows', c.total_rows
      ),
      'rows', coalesce((
        select jsonb_agg(to_jsonb(pr) order by pr.created_at desc, pr.movement_id desc)
        from page_rows pr
      ), '[]'::jsonb),
      'pagination', jsonb_build_object(
        'page', v_page,
        'page_size', v_page_size,
        'total_rows', c.total_rows,
        'total_pages', greatest(1, ceil(c.total_rows::numeric / v_page_size)::integer)
      )
    )
    from summary s
    cross join totals t
    cross join counted c
  );
end;
$$;

revoke all on function public.rpc_device_kardex(text, text, integer, text, date, date, integer, integer) from public;
grant execute on function public.rpc_device_kardex(text, text, integer, text, date, date, integer, integer) to anon, authenticated;

comment on function public.rpc_device_kardex(text, text, integer, text, date, date, integer, integer) is
  'Read-only paginated device Kardex with local dates, movement totals and per-product running balance.';
