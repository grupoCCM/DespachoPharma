-- Preserve lot traceability when importing new inventory snapshots.
-- Supplier returns and FEFO movements can reference inventory_lots, so lot
-- refreshes must update/insert/zero rows instead of deleting referenced IDs.

create or replace function public.refresh_inventory_lots_from_snapshots()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  alter table public.inventory_lots
  add column if not exists lot_sequence integer;

  create temporary table if not exists tmp_inventory_lot_parse(
    inventory_snapshot_item_id uuid,
    medicine_id uuid,
    lot_no text,
    expires_at date,
    qty numeric(14,4),
    lot_sequence integer,
    source_detail text
  ) on commit drop;

  truncate table tmp_inventory_lot_parse;

  insert into tmp_inventory_lot_parse(
    inventory_snapshot_item_id,
    medicine_id,
    lot_no,
    expires_at,
    qty,
    lot_sequence,
    source_detail
  )
  select
    i.id,
    i.medicine_id,
    nullif(trim(rx.m[1]), '') as lot_no,
    public.parse_inventory_lot_expiry(rx.m[2]) as expires_at,
    nullif(replace(rx.m[3], ',', ''), '')::numeric as qty,
    rx.ord::integer as lot_sequence,
    'Lote: ' || rx.m[1] || ', Vence: ' || rx.m[2] || ', Cantidad: ' || rx.m[3] as source_detail
  from public.inventory_snapshot_items i
  cross join lateral regexp_matches(
    coalesce(i.detail_raw, ''),
    'Lote:\s*([^,]+),\s*Vence:\s*([^,]+),\s*Cantidad:\s*([-0-9.,]+)',
    'g'
  ) with ordinality as rx(m, ord)
  where coalesce(i.detail_raw, '') ilike '%Lote:%';

  update public.inventory_lots il
  set medicine_id = p.medicine_id,
      lot_no = p.lot_no,
      expires_at = p.expires_at,
      qty = p.qty,
      source_detail = p.source_detail
  from tmp_inventory_lot_parse p
  where il.inventory_snapshot_item_id = p.inventory_snapshot_item_id
    and coalesce(il.lot_sequence, -1) = p.lot_sequence;

  insert into public.inventory_lots(
    inventory_snapshot_item_id,
    medicine_id,
    lot_no,
    expires_at,
    qty,
    lot_sequence,
    source_detail
  )
  select
    p.inventory_snapshot_item_id,
    p.medicine_id,
    p.lot_no,
    p.expires_at,
    p.qty,
    p.lot_sequence,
    p.source_detail
  from tmp_inventory_lot_parse p
  where not exists (
    select 1
    from public.inventory_lots il
    where il.inventory_snapshot_item_id = p.inventory_snapshot_item_id
      and coalesce(il.lot_sequence, -1) = p.lot_sequence
  );

  update public.inventory_lots il
  set qty = 0,
      source_detail = coalesce(il.source_detail, '') || ' | reemplazado por reproceso de inventario'
  where il.inventory_snapshot_item_id in (select id from public.inventory_snapshot_items)
    and coalesce(il.qty, 0) <> 0
    and not exists (
      select 1
      from tmp_inventory_lot_parse p
      where p.inventory_snapshot_item_id = il.inventory_snapshot_item_id
        and p.lot_sequence = coalesce(il.lot_sequence, -1)
    );

  select count(*) into v_count from tmp_inventory_lot_parse;
  return v_count;
end;
$$;

grant execute on function public.refresh_inventory_lots_from_snapshots() to anon, authenticated;

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
  v_lot_rows integer := 0;
  v_products_with_lots integer := 0;
  v_live_expired_lots integer := 0;
  v_live_unknown_lots integer := 0;
  v_historical_lot_rows integer := 0;
  v_effective_source_file text;
begin
  v_hash := encode(extensions.digest(p_session_token, 'sha256'), 'hex');
  v_effective_source_file := coalesce(nullif(trim(p_source_file), ''), 'inventario.xlsx');

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
  values ('inventory', v_effective_source_file, coalesce(nullif(trim(p_sha256), ''), v_batch_key), p_size_bytes)
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
    jsonb_build_object('source_type', 'inventory', 'source_file', v_effective_source_file, 'uploaded_by', v_user_id),
    'Procesamiento de inventario desde pantalla de importaciones'
  );

  insert into public.inventory_snapshots(snapshot_date, source_file, total_units, total_value)
  values (v_snapshot_date, v_effective_source_file, 0, 0)
  on conflict (snapshot_date, source_file) do update
    set total_units = 0,
        total_value = 0
  returning id into v_snapshot_id;

  update public.inventory_lots il
  set qty = 0,
      source_detail = coalesce(il.source_detail, '') || ' | reemplazado por reproceso de snapshot'
  where il.inventory_snapshot_item_id in (
    select id from public.inventory_snapshot_items where snapshot_id = v_snapshot_id
  )
    and coalesce(il.qty, 0) <> 0;

  delete from public.inventory_snapshot_items i
  where i.snapshot_id = v_snapshot_id
    and not exists (
      select 1 from public.inventory_lots il
      where il.inventory_snapshot_item_id = i.id
    );

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
    )
    on conflict (snapshot_id, external_code) do update
      set medicine_id = excluded.medicine_id,
          description_snapshot = excluded.description_snapshot,
          model = excluded.model,
          presentation = excluded.presentation,
          stock_qty = excluded.stock_qty,
          unit_cost = excluded.unit_cost,
          stock_value = excluded.stock_value,
          detail_raw = excluded.detail_raw;

    v_loaded := v_loaded + 1;
    v_total_units := v_total_units + coalesce(nullif(v_row->>5, '')::numeric, 0);
    v_total_value := v_total_value + coalesce(nullif(v_row->>7, '')::numeric, 0);
  end loop;

  update public.inventory_snapshots
  set total_units = v_total_units,
      total_value = v_total_value
  where id = v_snapshot_id;

  select public.refresh_inventory_lots_from_snapshots() into v_lots_refreshed;

  select
    count(*),
    count(distinct external_code)
    into v_lot_rows, v_products_with_lots
  from public.vw_inventory_lot_live
  where inventory_snapshot_item_id in (
    select id from public.inventory_snapshot_items where snapshot_id = v_snapshot_id
  );

  select
    count(*) filter (where expiration_status = 'expired'),
    count(*) filter (where expiration_status = 'unknown')
    into v_live_expired_lots, v_live_unknown_lots
  from public.vw_lot_stock_state
  where inventory_snapshot_item_id in (
    select id from public.inventory_snapshot_items where snapshot_id = v_snapshot_id
  );

  select count(*)
    into v_historical_lot_rows
  from (
    select
      i.id,
      coalesce(i.stock_qty, 0) as stock_qty,
      coalesce(sum(il.qty), 0) as lot_qty
    from public.inventory_snapshot_items i
    join public.inventory_lots il on il.inventory_snapshot_item_id = i.id
    where i.snapshot_id = v_snapshot_id
    group by i.id, i.stock_qty
    having coalesce(sum(il.qty), 0) > coalesce(i.stock_qty, 0)
  ) x;

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

  if v_historical_lot_rows > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (
      v_batch_key,
      'info',
      'INVENTORY_LOT_HISTORY_DETECTED',
      'inventory',
      v_historical_lot_rows || ' productos traen historial de lotes mayor que la existencia actual; se asigno el saldo vigente por FIFO.',
      jsonb_build_object('products_with_historical_lots', v_historical_lot_rows)
    );
  end if;

  if v_live_expired_lots > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (
      v_batch_key,
      'warning',
      'INVENTORY_LIVE_EXPIRED_LOTS',
      'inventory',
      v_live_expired_lots || ' lotes con saldo vigente quedaron vencidos; revisar fecha de vencimiento antes de despachar.',
      jsonb_build_object('live_expired_lots', v_live_expired_lots)
    );
  end if;

  if v_live_unknown_lots > 0 then
    insert into public.import_validation_issues(batch_key, severity, issue_code, source_type, message, details)
    values (
      v_batch_key,
      'warning',
      'INVENTORY_LIVE_UNKNOWN_EXPIRY_LOTS',
      'inventory',
      v_live_unknown_lots || ' lotes con saldo vigente no tienen vencimiento interpretable.',
      jsonb_build_object('live_unknown_lots', v_live_unknown_lots)
    );
  end if;

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
        'source_file', v_effective_source_file,
        'loaded_rows', v_loaded,
        'inactive_rows_skipped', v_inactive,
        'unresolved_rows', v_unresolved,
        'total_units', v_total_units,
        'total_value', v_total_value,
        'lots_refreshed', v_lots_refreshed,
        'lot_rows', v_lot_rows,
        'products_with_lots', v_products_with_lots,
        'historical_lot_rows', v_historical_lot_rows,
        'live_expired_lots', v_live_expired_lots,
        'live_unknown_lots', v_live_unknown_lots
      )
  where batch_key = v_batch_key;

  return jsonb_build_object(
    'ok', true,
    'batch_key', v_batch_key,
    'snapshot_date', v_snapshot_date,
    'source_file', v_effective_source_file,
    'loaded_rows', v_loaded,
    'inactive_rows_skipped', v_inactive,
    'unresolved_rows', v_unresolved,
    'total_units', v_total_units,
    'total_value', v_total_value,
    'lots_refreshed', v_lots_refreshed,
    'lot_rows', v_lot_rows,
    'products_with_lots', v_products_with_lots,
    'historical_lot_rows', v_historical_lot_rows,
    'live_expired_lots', v_live_expired_lots,
    'live_unknown_lots', v_live_unknown_lots
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

notify pgrst, 'reload schema';
