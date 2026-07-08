create or replace function public.rpc_import_sales_profit(
  p_session_token text,
  p_source_file text,
  p_sha256 text,
  p_size_bytes bigint,
  p_rows jsonb
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
  v_batch_key text;
  v_source_file_id uuid;
  v_item_source_file text;
  v_row jsonb;
  v_row_number integer := 1;
  v_code integer;
  v_medicine_id uuid;
  v_sale_no integer;
  v_voucher text;
  v_sale_date date;
  v_client_code integer;
  v_patient_name text;
  v_patient_id uuid;
  v_doc_id uuid;
  v_qty numeric;
  v_unit_net numeric;
  v_net_sale numeric;
  v_unit_cost numeric;
  v_cost_total numeric;
  v_profit numeric;
  v_profit_sale numeric;
  v_profit_cost numeric;
  v_loaded integer := 0;
  v_duplicates integer := 0;
  v_unresolved integer := 0;
  v_errors integer := 0;
  v_min_date date;
  v_max_date date;
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
    raise exception 'No autorizado para procesar ventas/utilidad';
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception 'Archivo de ventas/utilidad invalido';
  end if;

  v_batch_key := 'sales-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_item_source_file := coalesce(nullif(trim(p_source_file), ''), 'ventas-utilidad.xlsx') || ' [' || left(coalesce(nullif(trim(p_sha256), ''), v_batch_key), 12) || ']';

  insert into public.source_files(source_type, original_filename, sha256, size_bytes)
  values ('sales_profit', coalesce(nullif(trim(p_source_file), ''), 'ventas-utilidad.xlsx'), coalesce(nullif(trim(p_sha256), ''), v_batch_key), p_size_bytes)
  on conflict (source_type, sha256) do update
    set original_filename = excluded.original_filename,
        size_bytes = excluded.size_bytes,
        last_seen_at = now()
  returning id into v_source_file_id;

  insert into public.import_batches(batch_key, mode, status, source_summary, notes)
  values (
    v_batch_key,
    'apply',
    'started',
    jsonb_build_object('source_type', 'sales_profit', 'source_file', p_source_file, 'uploaded_by', v_user_id),
    'Procesamiento de ventas/utilidad desde pantalla de importaciones'
  );

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    begin
      v_code := nullif(v_row->>0, '')::integer;
      v_sale_no := nullif(v_row->>2, '')::integer;
      v_voucher := nullif(trim(v_row->>3), '');
      v_sale_date := nullif(v_row->>4, '')::date;
      v_client_code := nullif(v_row->>5, '')::integer;
      v_patient_name := nullif(trim(coalesce(v_row->>6, '')), '');
      v_qty := coalesce(nullif(v_row->>7, '')::numeric, 0);
      v_unit_net := nullif(v_row->>8, '')::numeric;
      v_net_sale := coalesce(nullif(v_row->>9, '')::numeric, 0);
      v_unit_cost := nullif(v_row->>10, '')::numeric;
      v_cost_total := coalesce(nullif(v_row->>11, '')::numeric, 0);
      v_profit := coalesce(nullif(v_row->>12, '')::numeric, 0);
      v_profit_sale := nullif(v_row->>13, '')::numeric;
      v_profit_cost := nullif(v_row->>14, '')::numeric;
    exception
      when others then
        v_errors := v_errors + 1;
        continue;
    end;

    if v_sale_no is null or v_voucher is null or v_sale_date is null or v_code is null then
      v_errors := v_errors + 1;
      continue;
    end if;

    v_patient_id := null;
    if v_client_code is not null then
      insert into public.patients(external_client_code, display_name, source_first_seen)
      values (v_client_code, v_patient_name, p_source_file)
      on conflict (external_client_code) do update
        set display_name = coalesce(nullif(excluded.display_name, ''), patients.display_name),
            updated_at = now()
      returning id into v_patient_id;
    end if;

    insert into public.sales_documents(external_sale_no, voucher_no, sale_date, patient_id, source_file)
    values (v_sale_no, v_voucher, v_sale_date, v_patient_id, p_source_file)
    on conflict (external_sale_no, voucher_no) do update
      set sale_date = excluded.sale_date,
          patient_id = coalesce(sales_documents.patient_id, excluded.patient_id),
          source_file = excluded.source_file
    returning id into v_doc_id;

    select id into v_medicine_id
    from public.medicines
    where external_code = v_code
      and active is true
    limit 1;

    if v_medicine_id is null then
      v_unresolved := v_unresolved + 1;
    end if;

    if exists (
      select 1
      from public.sales_items si
      where si.sales_document_id = v_doc_id
        and si.external_code = v_code
        and coalesce(si.description_snapshot, '') = coalesce(nullif(v_row->>1, ''), '')
        and si.qty = v_qty
        and si.net_sale = v_net_sale
        and si.cost_total = v_cost_total
        and si.profit = v_profit
    ) then
      v_duplicates := v_duplicates + 1;
      continue;
    end if;

    insert into public.sales_items(
      sales_document_id,
      medicine_id,
      source_row_number,
      external_code,
      description_snapshot,
      qty,
      unit_net_price,
      net_sale,
      unit_cost,
      cost_total,
      profit,
      profit_on_sale_pct,
      profit_on_cost_pct,
      source_file
    )
    values (
      v_doc_id,
      v_medicine_id,
      v_row_number,
      v_code,
      nullif(v_row->>1, ''),
      v_qty,
      v_unit_net,
      v_net_sale,
      v_unit_cost,
      v_cost_total,
      v_profit,
      v_profit_sale,
      v_profit_cost,
      v_item_source_file
    );

    v_loaded := v_loaded + 1;
    v_min_date := least(coalesce(v_min_date, v_sale_date), v_sale_date);
    v_max_date := greatest(coalesce(v_max_date, v_sale_date), v_sale_date);
  end loop;

  insert into public.import_batch_files(batch_key, source_file_id, source_type, sha256, row_count, min_source_date, max_source_date, duplicate_rows_detected)
  values (v_batch_key, v_source_file_id, 'sales_profit', coalesce(nullif(trim(p_sha256), ''), v_batch_key), v_loaded, v_min_date, v_max_date, v_duplicates);

  if v_unresolved > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (v_batch_key, 'warning', 'SALES_UNRESOLVED_CODES', 'sales_profit', v_unresolved || ' lineas de venta no resolvieron producto activo.', jsonb_build_object('unresolved_rows', v_unresolved));
  end if;

  if v_errors > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (v_batch_key, 'warning', 'SALES_SKIPPED_ROWS', 'sales_profit', v_errors || ' filas fueron omitidas por datos incompletos o invalidos.', jsonb_build_object('skipped_rows', v_errors));
  end if;

  update public.import_batches
  set status = 'completed',
      finished_at = now(),
      source_summary = jsonb_build_object(
        'source_type', 'sales_profit',
        'source_file', p_source_file,
        'loaded_rows', v_loaded,
        'duplicate_rows', v_duplicates,
        'unresolved_rows', v_unresolved,
        'skipped_rows', v_errors,
        'min_date', v_min_date,
        'max_date', v_max_date
      )
  where batch_key = v_batch_key;

  return jsonb_build_object('ok', true, 'batch_key', v_batch_key, 'source_type', 'sales_profit', 'loaded_rows', v_loaded, 'duplicate_rows', v_duplicates, 'unresolved_rows', v_unresolved, 'skipped_rows', v_errors, 'min_date', v_min_date, 'max_date', v_max_date);
exception
  when others then
    if v_batch_key is not null then
      update public.import_batches
      set status = 'failed',
          finished_at = now(),
          notes = sqlerrm
      where batch_key = v_batch_key;
    end if;
    raise;
end;
$$;

create or replace function public.rpc_import_consultations(
  p_session_token text,
  p_source_file text,
  p_sha256 text,
  p_size_bytes bigint,
  p_rows jsonb
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
  v_batch_key text;
  v_source_file_id uuid;
  v_item_source_file text;
  v_row jsonb;
  v_row_number integer := 1;
  v_client_code integer;
  v_patient_id uuid;
  v_visit_date date;
  v_sale_no integer;
  v_voucher text;
  v_loaded integer := 0;
  v_duplicates integer := 0;
  v_errors integer := 0;
  v_min_date date;
  v_max_date date;
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
    raise exception 'No autorizado para procesar clientes consulta';
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception 'Archivo de clientes consulta invalido';
  end if;

  v_batch_key := 'consultations-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_item_source_file := coalesce(nullif(trim(p_source_file), ''), 'clientes-consulta.csv') || ' [' || left(coalesce(nullif(trim(p_sha256), ''), v_batch_key), 12) || ']';

  insert into public.source_files(source_type, original_filename, sha256, size_bytes)
  values ('consultations', coalesce(nullif(trim(p_source_file), ''), 'clientes-consulta.csv'), coalesce(nullif(trim(p_sha256), ''), v_batch_key), p_size_bytes)
  on conflict (source_type, sha256) do update
    set original_filename = excluded.original_filename,
        size_bytes = excluded.size_bytes,
        last_seen_at = now()
  returning id into v_source_file_id;

  insert into public.import_batches(batch_key, mode, status, source_summary, notes)
  values (
    v_batch_key,
    'apply',
    'started',
    jsonb_build_object('source_type', 'consultations', 'source_file', p_source_file, 'uploaded_by', v_user_id),
    'Procesamiento de clientes consulta desde pantalla de importaciones'
  );

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    begin
      v_visit_date := nullif(v_row->>4, '')::date;
      v_sale_no := nullif(v_row->>2, '')::integer;
      v_voucher := nullif(trim(v_row->>3), '');
      v_client_code := nullif(v_row->>5, '')::integer;
    exception
      when others then
        v_errors := v_errors + 1;
        continue;
    end;

    if v_visit_date is null then
      v_errors := v_errors + 1;
      continue;
    end if;

    v_patient_id := null;
    if v_client_code is not null then
      insert into public.patients(external_client_code, display_name, source_first_seen)
      values (v_client_code, nullif(v_row->>6, ''), p_source_file)
      on conflict (external_client_code) do update
        set display_name = coalesce(nullif(excluded.display_name, ''), patients.display_name),
            updated_at = now()
      returning id into v_patient_id;
    end if;

    if exists (
      select 1
      from public.consultation_visits cv
      where cv.visit_date = v_visit_date
        and coalesce(cv.external_sale_no, -1) = coalesce(v_sale_no, -1)
        and coalesce(cv.voucher_no, '') = coalesce(v_voucher, '')
        and coalesce(cv.patient_id::text, '') = coalesce(v_patient_id::text, '')
        and coalesce(cv.service_name, '') = coalesce(nullif(v_row->>1, ''), '')
    ) then
      v_duplicates := v_duplicates + 1;
      continue;
    end if;

    insert into public.consultation_visits(
      source_row_number,
      external_article_code,
      service_name,
      external_sale_no,
      voucher_no,
      visit_date,
      patient_id,
      patient_name_snapshot,
      source_file
    )
    values (
      v_row_number,
      nullif(v_row->>0, '')::integer,
      nullif(v_row->>1, ''),
      v_sale_no,
      v_voucher,
      v_visit_date,
      v_patient_id,
      nullif(v_row->>6, ''),
      v_item_source_file
    );

    v_loaded := v_loaded + 1;
    v_min_date := least(coalesce(v_min_date, v_visit_date), v_visit_date);
    v_max_date := greatest(coalesce(v_max_date, v_visit_date), v_visit_date);
  end loop;

  insert into public.import_batch_files(batch_key, source_file_id, source_type, sha256, row_count, min_source_date, max_source_date, duplicate_rows_detected)
  values (v_batch_key, v_source_file_id, 'consultations', coalesce(nullif(trim(p_sha256), ''), v_batch_key), v_loaded, v_min_date, v_max_date, v_duplicates);

  if v_errors > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (v_batch_key, 'warning', 'CONSULTATIONS_SKIPPED_ROWS', 'consultations', v_errors || ' filas fueron omitidas por datos incompletos o invalidos.', jsonb_build_object('skipped_rows', v_errors));
  end if;

  update public.import_batches
  set status = 'completed',
      finished_at = now(),
      source_summary = jsonb_build_object(
        'source_type', 'consultations',
        'source_file', p_source_file,
        'loaded_rows', v_loaded,
        'duplicate_rows', v_duplicates,
        'skipped_rows', v_errors,
        'min_date', v_min_date,
        'max_date', v_max_date
      )
  where batch_key = v_batch_key;

  return jsonb_build_object('ok', true, 'batch_key', v_batch_key, 'source_type', 'consultations', 'loaded_rows', v_loaded, 'duplicate_rows', v_duplicates, 'skipped_rows', v_errors, 'min_date', v_min_date, 'max_date', v_max_date);
exception
  when others then
    if v_batch_key is not null then
      update public.import_batches
      set status = 'failed',
          finished_at = now(),
          notes = sqlerrm
      where batch_key = v_batch_key;
    end if;
    raise;
end;
$$;

create or replace function public.rpc_import_purchases(
  p_session_token text,
  p_source_file text,
  p_sha256 text,
  p_size_bytes bigint,
  p_rows jsonb
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
  v_batch_key text;
  v_source_file_id uuid;
  v_item_source_file text;
  v_row jsonb;
  v_row_number integer := 1;
  v_code integer;
  v_medicine_id uuid;
  v_purchase_no integer;
  v_voucher text;
  v_purchase_date date;
  v_supplier_code integer;
  v_supplier_name text;
  v_supplier_id uuid;
  v_doc_id uuid;
  v_qty numeric;
  v_line_total numeric;
  v_loaded integer := 0;
  v_duplicates integer := 0;
  v_unresolved integer := 0;
  v_errors integer := 0;
  v_min_date date;
  v_max_date date;
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
    raise exception 'No autorizado para procesar compras';
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception 'Archivo de compras invalido';
  end if;

  v_batch_key := 'purchases-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_item_source_file := coalesce(nullif(trim(p_source_file), ''), 'compras.xlsx') || ' [' || left(coalesce(nullif(trim(p_sha256), ''), v_batch_key), 12) || ']';

  insert into public.source_files(source_type, original_filename, sha256, size_bytes)
  values ('purchases', coalesce(nullif(trim(p_source_file), ''), 'compras.xlsx'), coalesce(nullif(trim(p_sha256), ''), v_batch_key), p_size_bytes)
  on conflict (source_type, sha256) do update
    set original_filename = excluded.original_filename,
        size_bytes = excluded.size_bytes,
        last_seen_at = now()
  returning id into v_source_file_id;

  insert into public.import_batches(batch_key, mode, status, source_summary, notes)
  values (
    v_batch_key,
    'apply',
    'started',
    jsonb_build_object('source_type', 'purchases', 'source_file', p_source_file, 'uploaded_by', v_user_id),
    'Procesamiento de compras desde pantalla de importaciones'
  );

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    begin
      v_code := nullif(v_row->>0, '')::integer;
      v_purchase_no := nullif(v_row->>2, '')::integer;
      v_voucher := nullif(trim(v_row->>3), '');
      v_purchase_date := nullif(v_row->>4, '')::date;
      v_supplier_code := nullif(v_row->>5, '')::integer;
      v_supplier_name := coalesce(nullif(trim(v_row->>6), ''), 'Proveedor sin nombre');
      v_qty := coalesce(nullif(v_row->>7, '')::numeric, 0);
      v_line_total := coalesce(nullif(v_row->>8, '')::numeric, 0);
    exception
      when others then
        v_errors := v_errors + 1;
        continue;
    end;

    if v_purchase_no is null or v_voucher is null or v_purchase_date is null or v_code is null or v_qty = 0 then
      v_errors := v_errors + 1;
      continue;
    end if;

    if v_supplier_code is not null then
      insert into public.suppliers(external_code, name, source_file)
      values (v_supplier_code, v_supplier_name, p_source_file)
      on conflict (external_code) do update
        set name = excluded.name,
            source_file = excluded.source_file,
            updated_at = now()
      returning id into v_supplier_id;
    else
      insert into public.suppliers(name, source_file)
      values (v_supplier_name, p_source_file)
      on conflict (normalized_name) do update
        set source_file = excluded.source_file,
            updated_at = now()
      returning id into v_supplier_id;
    end if;

    insert into public.purchase_documents(external_purchase_no, voucher_no, purchase_date, supplier_id, source_file)
    values (v_purchase_no, v_voucher, v_purchase_date, v_supplier_id, p_source_file)
    on conflict (external_purchase_no, voucher_no) do update
      set purchase_date = excluded.purchase_date,
          supplier_id = coalesce(purchase_documents.supplier_id, excluded.supplier_id),
          source_file = excluded.source_file
    returning id into v_doc_id;

    select id into v_medicine_id
    from public.medicines
    where external_code = v_code
      and active is true
    limit 1;

    if v_medicine_id is null then
      v_unresolved := v_unresolved + 1;
    end if;

    if exists (
      select 1
      from public.purchase_items pi
      where pi.purchase_document_id = v_doc_id
        and pi.external_code = v_code
        and coalesce(pi.description_snapshot, '') = coalesce(nullif(v_row->>1, ''), '')
        and pi.qty = v_qty
        and pi.line_total = v_line_total
    ) then
      v_duplicates := v_duplicates + 1;
      continue;
    end if;

    insert into public.purchase_items(
      purchase_document_id,
      medicine_id,
      source_row_number,
      external_code,
      description_snapshot,
      qty,
      line_total,
      source_file
    )
    values (
      v_doc_id,
      v_medicine_id,
      v_row_number,
      v_code,
      nullif(v_row->>1, ''),
      v_qty,
      v_line_total,
      v_item_source_file
    );

    v_loaded := v_loaded + 1;
    v_min_date := least(coalesce(v_min_date, v_purchase_date), v_purchase_date);
    v_max_date := greatest(coalesce(v_max_date, v_purchase_date), v_purchase_date);
  end loop;

  insert into public.import_batch_files(batch_key, source_file_id, source_type, sha256, row_count, min_source_date, max_source_date, duplicate_rows_detected)
  values (v_batch_key, v_source_file_id, 'purchases', coalesce(nullif(trim(p_sha256), ''), v_batch_key), v_loaded, v_min_date, v_max_date, v_duplicates);

  if v_unresolved > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (v_batch_key, 'warning', 'PURCHASE_UNRESOLVED_CODES', 'purchases', v_unresolved || ' lineas de compra no resolvieron producto activo.', jsonb_build_object('unresolved_rows', v_unresolved));
  end if;

  if v_errors > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (v_batch_key, 'warning', 'PURCHASE_SKIPPED_ROWS', 'purchases', v_errors || ' filas fueron omitidas por datos incompletos o invalidos.', jsonb_build_object('skipped_rows', v_errors));
  end if;

  update public.import_batches
  set status = 'completed',
      finished_at = now(),
      source_summary = jsonb_build_object(
        'source_type', 'purchases',
        'source_file', p_source_file,
        'loaded_rows', v_loaded,
        'duplicate_rows', v_duplicates,
        'unresolved_rows', v_unresolved,
        'skipped_rows', v_errors,
        'min_date', v_min_date,
        'max_date', v_max_date
      )
  where batch_key = v_batch_key;

  return jsonb_build_object('ok', true, 'batch_key', v_batch_key, 'source_type', 'purchases', 'loaded_rows', v_loaded, 'duplicate_rows', v_duplicates, 'unresolved_rows', v_unresolved, 'skipped_rows', v_errors, 'min_date', v_min_date, 'max_date', v_max_date);
exception
  when others then
    if v_batch_key is not null then
      update public.import_batches
      set status = 'failed',
          finished_at = now(),
          notes = sqlerrm
      where batch_key = v_batch_key;
    end if;
    raise;
end;
$$;

grant execute on function public.rpc_import_sales_profit(text, text, text, bigint, jsonb) to anon, authenticated;
grant execute on function public.rpc_import_consultations(text, text, text, bigint, jsonb) to anon, authenticated;
grant execute on function public.rpc_import_purchases(text, text, text, bigint, jsonb) to anon, authenticated;
