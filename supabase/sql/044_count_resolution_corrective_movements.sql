create or replace function public.rpc_inventory_count_resolution_board(
  p_session_token text,
  p_query text default '',
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
  v_session_id uuid;
  v_payload jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'No autorizado para consultar pendientes de conteo';
  end if;

  select id into v_session_id
  from public.inventory_count_sessions
  where status <> 'cancelled'
  order by coalesce(closed_at, started_at) desc, started_at desc
  limit 1;

  if v_session_id is null then
    return jsonb_build_object(
      'session', null,
      'summary', jsonb_build_object(
        'resolution_items', 0,
        'open_items', 0,
        'resolved_items', 0,
        'shortage_items', 0,
        'surplus_items', 0,
        'finding_items', 0,
        'shortage_qty', 0,
        'surplus_qty', 0,
        'open_shortage_qty', 0,
        'open_surplus_qty', 0,
        'net_variance_qty', 0,
        'variance_abs_value', 0,
        'shortage_value', 0,
        'surplus_value', 0
      ),
      'rows', '[]'::jsonb
    );
  end if;

  with base_raw as (
    select
      i.id,
      i.session_id,
      i.external_code,
      m.name as medicine_name,
      m.secondary_name,
      m.model,
      m.barcode,
      i.expected_qty,
      i.counted_qty,
      i.variance_qty,
      coalesce(i.expected_unit_cost, vl.unit_cost, 0) as unit_cost,
      coalesce(i.variance_qty, 0) * coalesce(i.expected_unit_cost, vl.unit_cost, 0) as variance_value,
      i.status,
      i.note,
      coalesce(i.condition_status, 'ok') as condition_status,
      coalesce(i.condition_qty, 0) as condition_qty,
      i.condition_note,
      i.counted_at,
      cu.display_name as counted_by_name,
      i.applied_at,
      au.display_name as applied_by_name,
      coalesce(corr.corrective_qty, 0) as corrective_qty,
      coalesce(corr.corrective_movement_count, 0) as corrective_movement_count,
      corr.last_corrective_at,
      corr.corrective_types
    from public.inventory_count_session_items i
    join public.medicines m on m.id = i.medicine_id
    left join public.app_users cu on cu.id = i.counted_by
    left join public.app_users au on au.id = i.applied_by
    left join public.vw_inventory_live vl on vl.external_code = i.external_code
    left join lateral (
      select
        coalesce(sum(im.qty_delta), 0) as corrective_qty,
        count(*) as corrective_movement_count,
        max(im.created_at) as last_corrective_at,
        string_agg(distinct im.movement_type, ', ' order by im.movement_type) as corrective_types
      from public.inventory_movements im
      where im.external_code = i.external_code
        and im.created_at >= coalesce(i.counted_at, (select s.started_at from public.inventory_count_sessions s where s.id = i.session_id))
        and im.source_type in ('manual_count','count_session','inventory_reclass')
        and im.movement_type in ('manual_count_adjust_in','manual_count_adjust_out','reclass_in','reclass_out')
        and (
          coalesce(i.variance_qty, 0) = 0
          or (i.variance_qty > 0 and im.qty_delta > 0)
          or (i.variance_qty < 0 and im.qty_delta < 0)
        )
    ) corr on true
    where i.session_id = v_session_id
      and i.counted_qty is not null
      and (coalesce(i.variance_qty, 0) <> 0 or coalesce(i.condition_status, 'ok') <> 'ok')
      and (
        v_query = ''
        or i.external_code::text = v_query
        or coalesce(m.barcode, '') ilike '%' || v_query || '%'
        or coalesce(m.name, '') ilike '%' || v_query || '%'
        or coalesce(m.secondary_name, '') ilike '%' || v_query || '%'
        or coalesce(m.model, '') ilike '%' || v_query || '%'
        or coalesce(i.note, '') ilike '%' || v_query || '%'
        or coalesce(i.condition_note, '') ilike '%' || v_query || '%'
      )
  ), base as (
    select
      br.*,
      case
        when br.status = 'applied' then true
        when coalesce(br.variance_qty, 0) <> 0 and abs(coalesce(br.corrective_qty, 0)) >= abs(coalesce(br.variance_qty, 0)) then true
        else false
      end as is_resolved,
      case
        when br.status = 'applied' then 'Solventado por ajuste del conteo'
        when coalesce(br.variance_qty, 0) <> 0 and abs(coalesce(br.corrective_qty, 0)) >= abs(coalesce(br.variance_qty, 0)) then 'Solventado por ajuste/reclasificacion posterior'
        when coalesce(br.condition_status, 'ok') <> 'ok' then 'Hallazgo pendiente'
        when br.variance_qty < 0 then 'Faltante pendiente'
        when br.variance_qty > 0 then 'Sobrante pendiente'
        else 'Revisado'
      end as resolution_status,
      case
        when br.status = 'applied' then 'Ya fue aplicado desde el conteo'
        when coalesce(br.variance_qty, 0) <> 0 and abs(coalesce(br.corrective_qty, 0)) >= abs(coalesce(br.variance_qty, 0)) then 'Ya tiene movimiento correctivo. Mantener como trazabilidad.'
        when coalesce(br.condition_status, 'ok') <> 'ok' then 'Resolver hallazgo de condicion'
        when br.variance_qty < 0 then 'Confirmar faltante real o reclasificar'
        when br.variance_qty > 0 then 'Buscar origen del sobrante o ajustar'
        else 'Sin accion'
      end as next_step
    from base_raw br
  ), ordered_rows as (
    select *
    from base
    order by
      case when is_resolved then 1 else 0 end,
      case when variance_qty < 0 then 0 else 1 end,
      abs(coalesce(variance_qty, 0)) desc,
      medicine_name
    limit v_limit
  )
  select jsonb_build_object(
    'session', public.inventory_count_session_payload(v_session_id),
    'summary', (
      select jsonb_build_object(
        'resolution_items', count(*),
        'open_items', count(*) filter (where is_resolved is false),
        'resolved_items', count(*) filter (where is_resolved is true),
        'shortage_items', count(*) filter (where variance_qty < 0),
        'surplus_items', count(*) filter (where variance_qty > 0),
        'finding_items', count(*) filter (where condition_status <> 'ok'),
        'shortage_qty', abs(coalesce(sum(variance_qty) filter (where variance_qty < 0), 0)),
        'surplus_qty', coalesce(sum(variance_qty) filter (where variance_qty > 0), 0),
        'open_shortage_qty', abs(coalesce(sum(variance_qty) filter (where variance_qty < 0 and is_resolved is false), 0)),
        'open_surplus_qty', coalesce(sum(variance_qty) filter (where variance_qty > 0 and is_resolved is false), 0),
        'net_variance_qty', coalesce(sum(variance_qty) filter (where is_resolved is false), 0),
        'variance_abs_value', coalesce(sum(abs(variance_value)) filter (where is_resolved is false), 0),
        'shortage_value', abs(coalesce(sum(variance_value) filter (where variance_qty < 0 and is_resolved is false), 0)),
        'surplus_value', coalesce(sum(variance_value) filter (where variance_qty > 0 and is_resolved is false), 0)
      )
      from base
    ),
    'rows', (select coalesce(jsonb_agg(to_jsonb(ordered_rows)), '[]'::jsonb) from ordered_rows)
  ) into v_payload;

  return v_payload;
end;
$$;

grant execute on function public.rpc_inventory_count_resolution_board(text, text, integer) to anon, authenticated;
