-- Fix supplier return list ordering by including created_at in the inner row.

create or replace function public.rpc_supplier_return_list(
  p_session_token text,
  p_status text default null,
  p_query text default '',
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status text := nullif(trim(coalesce(p_status, '')), '');
  v_query text := lower(trim(coalesce(p_query, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 300));
  v_docs jsonb;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.return_date desc, x.created_at desc), '[]'::jsonb)
    into v_docs
  from (
    select
      d.id,
      d.return_sheet_no,
      d.return_date,
      d.status,
      d.supplier_display_name,
      d.credit_note_no,
      d.credit_note_date,
      d.line_count,
      d.total_units,
      d.created_at,
      d.created_by_name,
      d.applied_by_name,
      d.applied_at,
      d.reconciled_by_name,
      d.reconciled_at
    from public.vw_supplier_return_documents d
    where (v_status is null or d.status = v_status)
      and (
        v_query = ''
        or lower(coalesce(d.return_sheet_no, '')) like '%' || v_query || '%'
        or lower(coalesce(d.supplier_display_name, '')) like '%' || v_query || '%'
        or lower(coalesce(d.credit_note_no, '')) like '%' || v_query || '%'
      )
    order by d.return_date desc, d.created_at desc
    limit v_limit
  ) x;

  return jsonb_build_object('documents', v_docs);
end;
$$;

grant execute on function public.rpc_supplier_return_list(text, text, text, integer) to anon, authenticated;
