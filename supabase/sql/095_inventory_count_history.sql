-- Read-only administrative history for physical inventory counts.
-- Count results use the confirmed recount when it exists; otherwise they use
-- the frozen session item. Current reconciliation status comes from cases.

create index if not exists ix_inventory_count_sessions_history
  on public.inventory_count_sessions(started_at desc, status);

create or replace function public.rpc_inventory_count_history(
  p_session_token text,
  p_query text default '',
  p_status text default '',
  p_date_from date default null,
  p_date_to date default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_status text := lower(trim(coalesce(p_status, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 50));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Solo admin puede consultar el historial de conteos'; end if;
  if v_status not in ('', 'open', 'closed', 'cancelled') then raise exception 'Estado de conteo invalido'; end if;

  return (
    with item_base as (
      select
        i.*,
        coalesce(c.confirmed_variance_qty, i.variance_qty) as result_variance_qty
      from public.inventory_count_session_items i
      left join public.inventory_variance_cases c on c.count_item_id = i.id
    ), item_summary as (
      select
        i.session_id,
        count(*) as total_items,
        count(*) filter (where i.counted_qty is not null) as counted_items,
        count(*) filter (where i.counted_qty is null) as pending_items,
        count(*) filter (where i.status = 'applied') as applied_items,
        count(*) filter (where i.result_variance_qty < 0) as shortage_items,
        count(*) filter (where i.result_variance_qty > 0) as surplus_items,
        abs(coalesce(sum(i.result_variance_qty) filter (where i.result_variance_qty < 0), 0)) as shortage_qty,
        coalesce(sum(i.result_variance_qty) filter (where i.result_variance_qty > 0), 0) as surplus_qty,
        coalesce(sum(i.result_variance_qty), 0) as net_variance_qty,
        coalesce(sum(abs(i.result_variance_qty * coalesce(i.expected_unit_cost, 0))) filter (where i.counted_qty is not null), 0) as variance_abs_value,
        count(*) filter (where coalesce(i.condition_status, 'ok') <> 'ok') as finding_items,
        coalesce(sum(i.condition_qty) filter (where coalesce(i.condition_status, 'ok') <> 'ok'), 0) as finding_qty,
        max(i.counted_at) as last_counted_at
      from item_base i
      group by i.session_id
    ), participant_summary as (
      select
        p.session_id,
        jsonb_agg(p.display_name order by p.display_name) as participant_names,
        count(*) as participant_count
      from (
        select distinct i.session_id, u.display_name
        from public.inventory_count_session_items i
        join public.app_users u on u.id = i.counted_by
        where i.counted_by is not null
      ) p
      group by p.session_id
    ), case_summary as (
      select
        c.count_session_id as session_id,
        count(*) as case_count,
        count(*) filter (where c.investigation_status <> 'resolved') as open_case_count,
        count(*) filter (where c.investigation_status = 'resolved') as resolved_case_count,
        count(*) filter (where c.investigation_status = 'partially_resolved') as partial_case_count
      from public.inventory_variance_cases c
      group by c.count_session_id
    ), base as (
      select
        s.id,
        s.title,
        s.scope,
        s.status,
        s.started_at,
        s.closed_at,
        s.note,
        su.display_name as started_by_name,
        cu.display_name as closed_by_name,
        coalesce(ps.participant_names, '[]'::jsonb) as participant_names,
        coalesce(ps.participant_count, 0) as participant_count,
        coalesce(isum.total_items, 0) as total_items,
        coalesce(isum.counted_items, 0) as counted_items,
        coalesce(isum.pending_items, 0) as pending_items,
        coalesce(isum.applied_items, 0) as applied_items,
        coalesce(isum.shortage_items, 0) as shortage_items,
        coalesce(isum.surplus_items, 0) as surplus_items,
        coalesce(isum.shortage_qty, 0) as shortage_qty,
        coalesce(isum.surplus_qty, 0) as surplus_qty,
        coalesce(isum.net_variance_qty, 0) as net_variance_qty,
        coalesce(isum.variance_abs_value, 0) as variance_abs_value,
        coalesce(isum.finding_items, 0) as finding_items,
        coalesce(isum.finding_qty, 0) as finding_qty,
        isum.last_counted_at,
        coalesce(cs.case_count, 0) as case_count,
        coalesce(cs.open_case_count, 0) as open_case_count,
        coalesce(cs.resolved_case_count, 0) as resolved_case_count,
        coalesce(cs.partial_case_count, 0) as partial_case_count,
        case
          when s.status = 'open' then 'in_progress'
          when s.status = 'cancelled' then 'cancelled'
          when coalesce(isum.pending_items, 0) > 0 then 'closed_incomplete'
          when coalesce(isum.shortage_items, 0) + coalesce(isum.surplus_items, 0) = 0
               and coalesce(isum.finding_items, 0) = 0 then 'clean'
          else 'with_differences'
        end as result_status,
        case
          when s.status = 'cancelled' then 'not_applicable'
          when s.status = 'open' then 'in_progress'
          when coalesce(cs.case_count, 0) = 0 then 'not_required'
          when coalesce(cs.open_case_count, 0) = 0 then 'reconciled'
          when coalesce(cs.resolved_case_count, 0) > 0 or coalesce(cs.partial_case_count, 0) > 0 then 'in_progress'
          else 'pending'
        end as reconciliation_status
      from public.inventory_count_sessions s
      left join public.app_users su on su.id = s.started_by
      left join public.app_users cu on cu.id = s.closed_by
      left join item_summary isum on isum.session_id = s.id
      left join participant_summary ps on ps.session_id = s.id
      left join case_summary cs on cs.session_id = s.id
    ), filtered as (
      select *
      from base b
      where (v_status = '' or b.status = v_status)
        and (p_date_from is null or (b.started_at at time zone 'America/El_Salvador')::date >= p_date_from)
        and (p_date_to is null or (b.started_at at time zone 'America/El_Salvador')::date <= p_date_to)
        and (
          v_query = ''
          or coalesce(b.title, '') ilike '%' || v_query || '%'
          or coalesce(b.started_by_name, '') ilike '%' || v_query || '%'
          or coalesce(b.closed_by_name, '') ilike '%' || v_query || '%'
          or exists (
            select 1
            from jsonb_array_elements_text(b.participant_names) participant
            where participant ilike '%' || v_query || '%'
          )
        )
    ), page_rows as (
      select *
      from filtered
      order by started_at desc, id desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'latest_completed', (
        select to_jsonb(x)
        from (select * from base where status = 'closed' order by coalesce(closed_at, started_at) desc, started_at desc limit 1) x
      ),
      'total', (select count(*) from filtered),
      'limit', v_limit,
      'offset', v_offset,
      'rows', coalesce((select jsonb_agg(to_jsonb(p) order by p.started_at desc, p.id desc) from page_rows p), '[]'::jsonb)
    )
  );
end;
$$;

revoke execute on function public.rpc_inventory_count_history(text, text, text, date, date, integer, integer) from public;
grant execute on function public.rpc_inventory_count_history(text, text, text, date, date, integer, integer) to anon, authenticated;

comment on function public.rpc_inventory_count_history(text, text, text, date, date, integer, integer) is
  'Read-only, admin-only, paginated physical count history with confirmed count outcome and current reconciliation status.';
