create or replace function public.rpc_import_inventory_snapshot(
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
  v_snapshot_id uuid;
  v_snapshot_date date := current_date;
  v_row jsonb;
  v_code integer;
  v_medicine_id uuid;
  v_active boolean;
  v_name text;
  v_loaded integer := 0;
  v_inactive integer := 0;
  v_unresolved integer := 0;
  v_total_units numeric := 0;
  v_total_value numeric := 0;
  v_lots_refreshed integer := 0;
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
    raise exception 'No autorizado para procesar inventario';
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception 'Archivo de inventario invalido';
  end if;

  v_batch_key := 'inventory-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');

  insert into public.source_files(source_type, original_filename, sha256, size_bytes)
  values ('inventory', coalesce(nullif(trim(p_source_file), ''), 'inventario.xlsx'), coalesce(nullif(trim(p_sha256), ''), v_batch_key), p_size_bytes)
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
    jsonb_build_object('source_type', 'inventory', 'source_file', p_source_file, 'uploaded_by', v_user_id),
    'Procesamiento de inventario desde pantalla de importaciones'
  );

  insert into public.inventory_snapshots(snapshot_date, source_file, total_units, total_value)
  values (v_snapshot_date, p_source_file, 0, 0)
  on conflict (snapshot_date, source_file) do update
    set total_units = 0,
        total_value = 0
  returning id into v_snapshot_id;

  delete from public.inventory_snapshot_items where snapshot_id = v_snapshot_id;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_code := nullif(v_row->>0, '')::integer;
    if v_code is null then
      continue;
    end if;

    select id, active, name into v_medicine_id, v_active, v_name
    from public.medicines
    where external_code = v_code
    limit 1;

    if v_medicine_id is null then
      v_unresolved := v_unresolved + 1;
      continue;
    end if;

    if v_active is not true then
      v_inactive := v_inactive + 1;
      continue;
    end if;

    insert into public.inventory_snapshot_items(
      snapshot_id,
      medicine_id,
      external_code,
      description_snapshot,
      model,
      presentation,
      stock_qty,
      unit_cost,
      stock_value,
      detail_raw
    )
    values (
      v_snapshot_id,
      v_medicine_id,
      v_code,
      nullif(v_row->>2, ''),
      nullif(v_row->>1, ''),
      nullif(v_row->>4, ''),
      coalesce(nullif(v_row->>5, '')::numeric, 0),
      coalesce(nullif(v_row->>6, '')::numeric, 0),
      coalesce(nullif(v_row->>7, '')::numeric, 0),
      nullif(v_row->>3, '')
    );

    v_loaded := v_loaded + 1;
    v_total_units := v_total_units + coalesce(nullif(v_row->>5, '')::numeric, 0);
    v_total_value := v_total_value + coalesce(nullif(v_row->>7, '')::numeric, 0);
  end loop;

  update public.inventory_snapshots
  set total_units = v_total_units,
      total_value = v_total_value
  where id = v_snapshot_id;

  select public.refresh_inventory_lots_from_snapshots() into v_lots_refreshed;

  insert into public.import_batch_files(
    batch_key,
    source_file_id,
    source_type,
    sha256,
    row_count,
    min_source_date,
    max_source_date,
    duplicate_rows_detected
  )
  values (
    v_batch_key,
    v_source_file_id,
    'inventory',
    coalesce(nullif(trim(p_sha256), ''), v_batch_key),
    v_loaded,
    v_snapshot_date,
    v_snapshot_date,
    0
  );

  if v_inactive > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (
      v_batch_key,
      'info',
      'INVENTORY_INACTIVE_SKIPPED',
      'inventory',
      v_inactive || ' productos inactivos fueron omitidos.',
      jsonb_build_object('inactive_rows', v_inactive)
    );
  end if;

  if v_unresolved > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (
      v_batch_key,
      'warning',
      'INVENTORY_UNRESOLVED_CODES',
      'inventory',
      v_unresolved || ' codigos no existen en catalogo y fueron omitidos.',
      jsonb_build_object('unresolved_rows', v_unresolved)
    );
  end if;

  update public.import_batches
  set status = 'completed',
      finished_at = now(),
      source_summary = jsonb_build_object(
        'source_type', 'inventory',
        'source_file', p_source_file,
        'loaded_rows', v_loaded,
        'inactive_rows_skipped', v_inactive,
        'unresolved_rows', v_unresolved,
        'total_units', v_total_units,
        'total_value', v_total_value,
        'lots_refreshed', v_lots_refreshed
      )
  where batch_key = v_batch_key;

  return jsonb_build_object(
    'ok', true,
    'batch_key', v_batch_key,
    'snapshot_date', v_snapshot_date,
    'source_file', p_source_file,
    'loaded_rows', v_loaded,
    'inactive_rows_skipped', v_inactive,
    'unresolved_rows', v_unresolved,
    'total_units', v_total_units,
    'total_value', v_total_value,
    'lots_refreshed', v_lots_refreshed
  );
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

grant execute on function public.rpc_import_inventory_snapshot(text, text, text, bigint, jsonb) to anon, authenticated;
