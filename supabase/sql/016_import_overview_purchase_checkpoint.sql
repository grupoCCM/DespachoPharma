create or replace function public.rpc_import_overview(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_batch_key text;
  v_user_role public.user_role;
  v_latest jsonb;
  v_files jsonb;
  v_issues jsonb;
  v_purchase_checkpoint jsonb;
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
    raise exception 'No autorizado para consultar importaciones';
  end if;

  select to_jsonb(x) into v_purchase_checkpoint
  from (
    select
      pd.purchase_date,
      pd.external_purchase_no,
      pd.voucher_no,
      pd.source_file,
      pd.created_at,
      s.name as supplier_name,
      count(pi.id) as purchase_lines,
      coalesce(sum(pi.qty), 0) as units
    from public.purchase_documents pd
    left join public.suppliers s on s.id = pd.supplier_id
    left join public.purchase_items pi on pi.purchase_document_id = pd.id
    group by pd.id, s.name
    order by pd.purchase_date desc nulls last, pd.created_at desc
    limit 1
  ) x;

  select batch_key into v_batch_key
  from public.import_batches
  order by started_at desc
  limit 1;

  if v_batch_key is null then
    return jsonb_build_object(
      'latest', null,
      'files', '[]'::jsonb,
      'issues', '[]'::jsonb,
      'purchase_checkpoint', v_purchase_checkpoint
    );
  end if;

  select to_jsonb(x) into v_latest
  from (
    select batch_key, mode, status, started_at, finished_at, warnings, errors, files_seen
    from public.vw_import_batch_latest
    where batch_key = v_batch_key
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.source_type), '[]'::jsonb) into v_files
  from (
    select source_type, row_count, min_source_date, max_source_date, duplicate_rows_detected, sha256
    from public.import_batch_files
    where batch_key = v_batch_key
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.severity, x.issue_code), '[]'::jsonb) into v_issues
  from (
    select severity, issue_code, source_type, message, details, created_at
    from public.import_validation_issues
    where batch_key = v_batch_key
  ) x;

  return jsonb_build_object(
    'latest', v_latest,
    'files', v_files,
    'issues', v_issues,
    'purchase_checkpoint', v_purchase_checkpoint
  );
end;
$$;

grant execute on function public.rpc_import_overview(text) to anon, authenticated;
