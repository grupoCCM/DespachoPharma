create or replace function public.rpc_inventory_audit(
  p_session_token text,
  p_query text default '',
  p_limit integer default 80
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_limit integer := greatest(10, least(coalesce(p_limit, 80), 200));
  v_query text := trim(coalesce(p_query, ''));
  v_payload jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesión inválida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  v_payload := jsonb_build_object(
    'summary', (
      select jsonb_build_object(
        'movement_count', count(*),
        'in_qty', coalesce(sum(qty_delta) filter (where qty_delta > 0), 0),
        'out_qty', abs(coalesce(sum(qty_delta) filter (where qty_delta < 0), 0)),
        'net_qty', coalesce(sum(qty_delta), 0),
        'unresolved_count', count(*) filter (where external_code is null),
        'last_movement_at', max(created_at)
      )
      from public.inventory_movements
    ),
    'live_summary', (
      select jsonb_build_object(
        'items', count(*),
        'snapshot_units', coalesce(sum(snapshot_stock_qty), 0),
        'movement_units', coalesce(sum(movement_qty), 0),
        'live_units', coalesce(sum(stock_qty), 0),
        'negative_items', count(*) filter (where stock_qty < 0),
        'zero_items', count(*) filter (where stock_qty = 0)
      )
      from public.vw_inventory_live
    ),
    'movements', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
      from (
        select
          im.id,
          im.created_at,
          im.movement_type,
          im.source_type,
          im.source_id,
          im.source_item_id,
          im.external_code,
          im.barcode,
          coalesce(m.name, im.metadata->>'product_name', im.metadata->>'description', 'Sin catálogo') as medicine_name,
          m.model,
          im.qty_delta,
          im.unit_cost,
          im.note,
          im.metadata,
          u.display_name as created_by_name,
          dh.delivery_no,
          pd.external_purchase_no,
          pd.voucher_no,
          pd.purchase_date,
          (im.external_code is not null) as resolved
        from public.inventory_movements im
        left join public.medicines m on m.external_code = im.external_code
        left join public.app_users u on u.id = im.created_by
        left join public.dispatch_header dh on dh.id = im.source_id and im.source_type like 'dispatch%'
        left join public.purchase_documents pd on pd.id = im.source_id and im.source_type = 'purchase_file'
        where v_query = ''
           or im.external_code::text = v_query
           or coalesce(im.barcode, '') ilike '%' || v_query || '%'
           or coalesce(m.name, '') ilike '%' || v_query || '%'
           or coalesce(m.secondary_name, '') ilike '%' || v_query || '%'
           or coalesce(m.model, '') ilike '%' || v_query || '%'
           or coalesce(im.metadata->>'product_name', '') ilike '%' || v_query || '%'
           or coalesce(im.metadata->>'description', '') ilike '%' || v_query || '%'
        order by im.created_at desc
        limit v_limit
      ) x
    ),
    'unresolved', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
      from (
        select
          im.barcode,
          im.external_code,
          coalesce(im.metadata->>'product_name', im.metadata->>'description', 'Sin detalle') as description,
          count(*) as movement_count,
          sum(im.qty_delta) as net_qty,
          max(im.created_at) as last_movement_at
        from public.inventory_movements im
        where im.external_code is null
        group by im.barcode, im.external_code, coalesce(im.metadata->>'product_name', im.metadata->>'description', 'Sin detalle')
        order by max(im.created_at) desc
        limit 30
      ) x
    ),
    'changed_stock', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
      from (
        select
          vl.external_code,
          coalesce(m.name, vl.description_snapshot) as medicine_name,
          m.model,
          vl.snapshot_stock_qty,
          vl.movement_qty,
          vl.stock_qty,
          case
            when vl.stock_qty < 0 then 'Negativo'
            when vl.movement_qty <> 0 then 'Con movimiento'
            else 'Sin movimiento'
          end as status
        from public.vw_inventory_live vl
        left join public.medicines m on m.external_code = vl.external_code
        where vl.movement_qty <> 0 or vl.stock_qty < 0
        order by abs(vl.movement_qty) desc, medicine_name
        limit 80
      ) x
    )
  );

  return v_payload;
end;
$$;

grant execute on function public.rpc_inventory_audit(text, text, integer) to anon, authenticated;
