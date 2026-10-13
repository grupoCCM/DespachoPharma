-- Reserve sellable inventory when a dispatch is confirmed.
-- Existing dispatches remain on the legacy path (stock_reservation_version = 0).

begin;

alter table public.dispatch_header
  add column if not exists stock_reservation_version smallint not null default 0;

create table if not exists public.inventory_reservations (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.dispatch_header(id) on delete restrict,
  dispatch_item_id uuid not null references public.dispatch_items(id) on delete restrict,
  medicine_id uuid not null references public.medicines(id) on delete restrict,
  external_code integer not null,
  barcode text not null,
  lot_id uuid not null references public.inventory_lots(id) on delete restrict,
  qty numeric(14,4) not null check (qty > 0),
  status text not null default 'active'
    check (status in ('active','fulfilled','released')),
  reserved_at timestamptz not null default now(),
  fulfilled_at timestamptz,
  released_at timestamptz,
  release_reason text,
  created_by uuid references public.app_users(id),
  updated_at timestamptz not null default now()
);

create unique index if not exists ux_inventory_reservations_active_item_lot
  on public.inventory_reservations(dispatch_item_id, lot_id)
  where status = 'active';

create index if not exists idx_inventory_reservations_active_product
  on public.inventory_reservations(external_code, lot_id)
  where status = 'active';

create index if not exists idx_inventory_reservations_dispatch
  on public.inventory_reservations(dispatch_id, status);

alter table public.inventory_reservations enable row level security;
revoke all on table public.inventory_reservations from public, anon, authenticated;

create or replace view public.vw_product_stock_state as
with lot_totals as (
  select
    external_code,
    sum(expired_lot_qty)::numeric(14,4) as expired_qty,
    sum(quarantine_lot_qty)::numeric(14,4) as quarantine_qty,
    sum(not_sellable_lot_qty)::numeric(14,4) as not_sellable_qty,
    min(expires_at) filter (where physical_lot_qty > 0) as nearest_expiration,
    min(expires_at) filter (where sellable_lot_qty > 0) as nearest_sellable_expiration
  from public.vw_lot_stock_state
  group by external_code
),
reservation_totals as (
  select external_code, sum(qty)::numeric(14,4) as reserved_qty
  from public.inventory_reservations
  where status = 'active'
  group by external_code
)
select
  live.external_code,
  live.medicine_id,
  live.barcode,
  live.description_snapshot,
  live.model,
  live.presentation,
  greatest(coalesce(live.snapshot_stock_qty, 0), 0)::numeric(14,4) as snapshot_physical_qty,
  coalesce(live.movement_qty, 0)::numeric(14,4) as movement_qty,
  greatest(coalesce(live.stock_qty, 0), 0)::numeric(14,4) as physical_qty,
  coalesce(lt.expired_qty, 0)::numeric(14,4) as expired_qty,
  coalesce(rt.reserved_qty, 0)::numeric(14,4) as reserved_qty,
  coalesce(lt.quarantine_qty, 0)::numeric(14,4) as quarantine_qty,
  coalesce(lt.not_sellable_qty, 0)::numeric(14,4) as not_sellable_qty,
  greatest(
    coalesce(live.stock_qty, 0)
      - coalesce(lt.expired_qty, 0)
      - coalesce(rt.reserved_qty, 0)
      - coalesce(lt.quarantine_qty, 0)
      - coalesce(lt.not_sellable_qty, 0),
    0
  )::numeric(14,4) as sellable_qty,
  live.unit_cost,
  live.stock_value as physical_stock_value,
  live.snapshot_created_at,
  lt.nearest_expiration,
  lt.nearest_sellable_expiration
from public.vw_inventory_live live
left join lot_totals lt on lt.external_code = live.external_code
left join reservation_totals rt on rt.external_code = live.external_code;

create or replace function public.dispatch_stock_check(
  p_barcode text,
  p_requested_qty numeric,
  p_exclude_dispatch_id uuid default null
)
returns table(
  external_code integer,
  medicine_name text,
  stock_qty numeric,
  reserved_qty numeric,
  available_qty numeric,
  requested_qty numeric,
  ok boolean
)
language sql
security definer
set search_path = public, pg_temp
as $function$
with matched as (
  select apm.barcode, apm.product_name
  from public.app_pharma_match(p_barcode) apm
  where apm.active is true
  limit 1
),
med as (
  select m.external_code, coalesce(m.name, matched.product_name) as medicine_name
  from matched
  join public.medicines m on m.barcode = matched.barcode
  order by m.active desc, m.external_code
  limit 1
),
base_stock as (
  select coalesce(vs.sellable_qty, 0)::numeric as qty
  from med
  left join public.vw_inventory_sellable vs on vs.external_code = med.external_code
),
active_reservations as (
  select coalesce(sum(r.qty), 0)::numeric as qty
  from med
  left join public.inventory_reservations r
    on r.external_code = med.external_code
   and r.status = 'active'
   and (p_exclude_dispatch_id is null or r.dispatch_id <> p_exclude_dispatch_id)
)
select
  med.external_code,
  med.medicine_name,
  base_stock.qty as stock_qty,
  active_reservations.qty as reserved_qty,
  greatest(base_stock.qty - active_reservations.qty, 0) as available_qty,
  coalesce(p_requested_qty, 0)::numeric as requested_qty,
  med.external_code is not null
    and coalesce(p_requested_qty, 0) > 0
    and greatest(base_stock.qty - active_reservations.qty, 0) >= coalesce(p_requested_qty, 0)::numeric as ok
from med
cross join base_stock
cross join active_reservations;
$function$;

create or replace function public.rpc_dispatch_submit_cart(
  p_session_token text,
  p_expediente text,
  p_items jsonb
)
returns table(dispatch_id uuid, delivery_no bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_dispatch_id uuid;
  v_delivery bigint;
  v_count integer;
  v_item record;
  v_match record;
  v_item_id uuid;
  v_medicine_id uuid;
  v_external_code integer;
  v_remaining numeric;
  v_take numeric;
  v_lot record;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role not in ('dispatch','admin') then raise exception 'Permiso denegado'; end if;
  if nullif(trim(coalesce(p_expediente, '')), '') is null then raise exception 'Expediente requerido'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Carrito vacio';
  end if;

  create temporary table if not exists pg_temp.dispatch_cart_items(
    barcode text primary key,
    qty integer not null
  ) on commit drop;
  truncate table pg_temp.dispatch_cart_items;

  insert into pg_temp.dispatch_cart_items(barcode, qty)
  select barcode, qty
  from (
    select
      nullif(regexp_replace(coalesce(item->>'barcode',''), '\D', '', 'g'), '') as barcode,
      sum(greatest(coalesce((item->>'qty')::integer, 0), 0))::integer as qty
    from jsonb_array_elements(p_items) item
    group by 1
  ) grouped
  where barcode is not null and qty > 0;

  select count(*) into v_count from pg_temp.dispatch_cart_items;
  if coalesce(v_count, 0) = 0 then raise exception 'Carrito vacio'; end if;

  for v_item in select barcode from pg_temp.dispatch_cart_items order by barcode loop
    perform pg_advisory_xact_lock(hashtextextended('dispatch_stock:' || v_item.barcode, 0));
  end loop;

  for v_item in select barcode, qty from pg_temp.dispatch_cart_items order by barcode loop
    select * into v_match from public.app_pharma_match(v_item.barcode);
    if v_match.barcode is null then raise exception 'Barcode no existe en catalogo'; end if;
    if v_match.active is distinct from true then raise exception 'Barcode existe pero esta inactivo'; end if;
    perform public.dispatch_raise_if_stock_insufficient(v_match.barcode, v_item.qty, null);
  end loop;

  insert into public.dispatch_header(
    expediente, status, created_by, stock_reservation_version
  ) values (
    trim(p_expediente), 'draft', v_user_id, 1
  ) returning id into v_dispatch_id;

  v_delivery := nextval('public.delivery_no_seq');

  for v_item in select barcode, qty from pg_temp.dispatch_cart_items order by barcode loop
    select * into v_match from public.app_pharma_match(v_item.barcode);
    select id, external_code into v_medicine_id, v_external_code
    from public.medicines
    where barcode = v_match.barcode and active is true
    order by external_code
    limit 1;

    if v_medicine_id is null then
      raise exception 'No se puede reservar: el producto no cruza con inventario';
    end if;

    insert into public.dispatch_items(dispatch_id, barcode, product_name_snapshot, qty)
    values (v_dispatch_id, v_match.barcode, v_match.product_name, v_item.qty)
    returning id into v_item_id;

    v_remaining := v_item.qty;

    for v_lot in
      select
        ls.lot_id,
        ls.lot_no,
        ls.expires_at,
        greatest(ls.sellable_lot_qty - coalesce(ar.qty, 0), 0)::numeric(14,4) as available_lot_qty
      from public.vw_lot_stock_state ls
      left join lateral (
        select sum(r.qty)::numeric(14,4) as qty
        from public.inventory_reservations r
        where r.lot_id = ls.lot_id and r.status = 'active'
      ) ar on true
      where ls.external_code = v_external_code
        and ls.is_sellable is true
        and greatest(ls.sellable_lot_qty - coalesce(ar.qty, 0), 0) > 0
      order by ls.expires_at asc nulls last, ls.lot_no asc nulls last, ls.lot_sequence asc nulls last
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_lot.available_lot_qty);

      insert into public.inventory_reservations(
        dispatch_id, dispatch_item_id, medicine_id, external_code, barcode,
        lot_id, qty, status, created_by
      ) values (
        v_dispatch_id, v_item_id, v_medicine_id, v_external_code, v_match.barcode,
        v_lot.lot_id, v_take, 'active', v_user_id
      );

      v_remaining := v_remaining - v_take;
    end loop;

    if v_remaining > 0 then
      raise exception 'No se puede confirmar: no hay lotes vendibles suficientes para %. Disponible sin reservar: %.',
        v_match.product_name,
        (v_item.qty - v_remaining)::integer;
    end if;
  end loop;

  update public.dispatch_header
  set status = 'confirmed', delivery_no = v_delivery, confirmed_at = now(), updated_at = now()
  where id = v_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_CONFIRM', v_user_id, v_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery,
      'items', v_count,
      'mode', 'submit_cart',
      'stock_lock', 'advisory_xact',
      'stock_reservation_version', 1
    )
  );

  return query select v_dispatch_id, v_delivery;
end;
$function$;

create or replace function public.inventory_apply_lot_fifo(p_inventory_movement_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_movement record;
  v_remaining numeric;
  v_take numeric;
  v_lot record;
  v_return record;
  v_product_physical_before numeric;
begin
  select * into v_movement
  from public.inventory_movements
  where id = p_inventory_movement_id;

  if v_movement.id is null or coalesce(v_movement.qty_delta, 0) = 0 then return; end if;
  if coalesce(v_movement.source_type, '') not in ('dispatch_validate','dispatch_void','dispatch_adjust') then return; end if;
  if exists (select 1 from public.inventory_lot_movements where inventory_movement_id = v_movement.id) then return; end if;

  if v_movement.qty_delta < 0 then
    v_remaining := abs(v_movement.qty_delta);

    -- New dispatches consume the exact FEFO lots reserved at confirmation.
    if v_movement.source_type = 'dispatch_validate' and exists (
      select 1 from public.inventory_reservations r
      where r.dispatch_item_id = v_movement.source_item_id and r.status = 'active'
    ) then
      for v_lot in
        select r.id reservation_id, r.lot_id, r.qty, l.lot_no, l.expires_at
        from public.inventory_reservations r
        join public.inventory_lots l on l.id = r.lot_id
        where r.dispatch_item_id = v_movement.source_item_id and r.status = 'active'
        order by l.expires_at asc nulls last, l.lot_no asc nulls last, r.id
        for update of r
      loop
        exit when v_remaining <= 0;
        v_take := least(v_remaining, v_lot.qty);

        insert into public.inventory_lot_movements(
          lot_id, inventory_movement_id, movement_type, source_type, source_id,
          source_item_id, source_event_key, medicine_id, external_code, barcode,
          qty_delta, created_by, metadata
        ) values (
          v_lot.lot_id, v_movement.id, v_movement.movement_type, v_movement.source_type,
          v_movement.source_id, v_movement.source_item_id,
          'lot_reserved:' || v_movement.id::text || ':' || v_lot.lot_id::text,
          v_movement.medicine_id, v_movement.external_code, v_movement.barcode,
          -1 * v_take, v_movement.created_by,
          coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object(
            'fefo', true, 'reserved', true, 'reservation_id', v_lot.reservation_id,
            'lot_no', v_lot.lot_no, 'expires_at', v_lot.expires_at
          )
        ) on conflict (source_event_key) where source_event_key is not null do nothing;

        v_remaining := v_remaining - v_take;
      end loop;

      if v_remaining > 0 then
        raise exception 'La reserva del producto % esta incompleta. Faltante: %.', v_movement.external_code, v_remaining;
      end if;
      return;
    end if;

    -- Legacy dispatches keep the proven FEFO behavior.
    select greatest(coalesce(live.stock_qty, 0) - coalesce(v_movement.qty_delta, 0), 0)
      into v_product_physical_before
    from public.vw_inventory_live live
    where live.external_code = v_movement.external_code;
    v_product_physical_before := coalesce(v_product_physical_before, 0);

    for v_lot in
      with lot_base as (
        select
          vl.lot_id, vl.medicine_id, vl.external_code, vl.barcode, vl.lot_no,
          vl.lot_sequence, vl.expires_at,
          greatest(coalesce(vl.lot_qty, 0), 0)::numeric(14,4) as raw_lot_qty,
          coalesce(sum(greatest(coalesce(vl.lot_qty, 0), 0)) over (
            partition by vl.external_code
            order by vl.lot_sequence desc nulls last, vl.expires_at desc nulls last,
                     vl.lot_no desc nulls last, vl.lot_id desc
            rows between unbounded preceding and 1 preceding
          ), 0)::numeric(14,4) as newer_lot_qty
        from public.vw_inventory_lot_live vl
        left join public.medicines m on m.id = vl.medicine_id
        where vl.external_code = v_movement.external_code
          and coalesce(m.active, true) = true
          and greatest(coalesce(vl.lot_qty, 0), 0) > 0
      ), lot_state_before as (
        select *, greatest(0, least(raw_lot_qty, v_product_physical_before - newer_lot_qty))::numeric(14,4)
          as sellable_lot_qty_before
        from lot_base
      )
      select * from lot_state_before
      where sellable_lot_qty_before > 0 and (expires_at is null or expires_at > current_date)
      order by expires_at asc nulls last, lot_no asc nulls last, lot_sequence asc nulls last
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_lot.sellable_lot_qty_before);
      insert into public.inventory_lot_movements(
        lot_id, inventory_movement_id, movement_type, source_type, source_id,
        source_item_id, source_event_key, medicine_id, external_code, barcode,
        qty_delta, created_by, metadata
      ) values (
        v_lot.lot_id, v_movement.id, v_movement.movement_type, v_movement.source_type,
        v_movement.source_id, v_movement.source_item_id,
        'lot_fefo:' || v_movement.id::text || ':' || v_lot.lot_id::text,
        v_movement.medicine_id, v_movement.external_code, v_movement.barcode,
        -1 * v_take, v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object(
          'fefo', true, 'lot_no', v_lot.lot_no, 'expires_at', v_lot.expires_at,
          'sellable_lot_qty_before', v_lot.sellable_lot_qty_before,
          'product_physical_qty_before', v_product_physical_before
        )
      ) on conflict (source_event_key) where source_event_key is not null do nothing;
      v_remaining := v_remaining - v_take;
    end loop;

    if v_remaining > 0 then
      raise exception 'No hay lotes vendibles suficientes para despachar producto %. Faltante por lote: %.',
        v_movement.external_code, v_remaining;
    end if;
  else
    v_remaining := v_movement.qty_delta;
    for v_return in
      select lm.lot_id, min(lm.created_at) as first_out_at, -1 * sum(lm.qty_delta) as qty_out
      from public.inventory_lot_movements lm
      where lm.source_item_id = v_movement.source_item_id
      group by lm.lot_id
      having -1 * sum(lm.qty_delta) > 0
      order by first_out_at desc nulls last
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_return.qty_out);
      insert into public.inventory_lot_movements(
        lot_id, inventory_movement_id, movement_type, source_type, source_id,
        source_item_id, source_event_key, medicine_id, external_code, barcode,
        qty_delta, created_by, metadata
      ) values (
        v_return.lot_id, v_movement.id, v_movement.movement_type, v_movement.source_type,
        v_movement.source_id, v_movement.source_item_id,
        'lot_return:' || v_movement.id::text || ':' || v_return.lot_id::text,
        v_movement.medicine_id, v_movement.external_code, v_movement.barcode,
        v_take, v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object('fifo_return', true)
      ) on conflict (source_event_key) where source_event_key is not null do nothing;
      v_remaining := v_remaining - v_take;
    end loop;
  end if;
end;
$function$;

create or replace function public.rpc_cashier_validate(p_session_token text, p_dispatch_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_source_kind text;
  v_inventory_effect text;
  v_reservation_version smallint;
  v_item record;
  v_reserved numeric;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role not in ('cashier','admin') then raise exception 'Permiso denegado'; end if;

  select status, source_kind, inventory_effect, stock_reservation_version
    into v_status, v_source_kind, v_inventory_effect, v_reservation_version
  from public.dispatch_header
  where id = p_dispatch_id
  for update;

  if v_status <> 'confirmed' then raise exception 'Solo se puede validar si esta confirmed'; end if;
  if v_source_kind <> 'internal_dispatch' or v_inventory_effect <> 'cashier_validation' then
    raise exception 'Esta entrega corresponde a una venta externa conciliada; no requiere validacion de Caja';
  end if;

  for v_item in
    select id, barcode, qty, product_name_snapshot
    from public.dispatch_items where dispatch_id = p_dispatch_id order by barcode, id
  loop
    perform pg_advisory_xact_lock(hashtextextended('dispatch_stock:' || v_item.barcode, 0));

    if coalesce(v_reservation_version, 0) >= 1 then
      perform 1
      from public.inventory_reservations
      where dispatch_item_id = v_item.id and status = 'active'
      for update;

      select coalesce(sum(qty), 0) into v_reserved
      from public.inventory_reservations
      where dispatch_item_id = v_item.id and status = 'active';

      if v_reserved <> v_item.qty then
        raise exception 'La reserva de % ya no esta completa. Recargue la entrega o solicite anulacion.',
          v_item.product_name_snapshot;
      end if;
    else
      perform public.dispatch_raise_if_stock_insufficient(v_item.barcode, v_item.qty, p_dispatch_id);
    end if;
  end loop;

  for v_item in
    select id, barcode, qty, product_name_snapshot
    from public.dispatch_items where dispatch_id = p_dispatch_id order by barcode, id
  loop
    perform public.inventory_insert_dispatch_movement(
      p_dispatch_id, v_item.id, v_item.barcode, -1 * v_item.qty,
      'dispatch_out', 'dispatch_validate', 'dispatch_validate:' || v_item.id::text,
      v_user_id, 'Descuento por despacho validado',
      jsonb_build_object('product_name', v_item.product_name_snapshot, 'reserved', coalesce(v_reservation_version,0) >= 1)
    );
  end loop;

  if coalesce(v_reservation_version, 0) >= 1 then
    update public.inventory_reservations
    set status = 'fulfilled', fulfilled_at = now(), updated_at = now()
    where dispatch_id = p_dispatch_id and status = 'active';
  end if;

  update public.dispatch_header
  set status = 'validated', validated_by = v_user_id, validated_at = now(), updated_at = now()
  where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values ('CASHIER_VALIDATE', v_user_id, p_dispatch_id,
          jsonb_build_object('stock_reservation_version', coalesce(v_reservation_version,0)));
end;
$function$;

create or replace function public.rpc_cashier_observe(
  p_session_token text,
  p_dispatch_id uuid,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role not in ('cashier','admin') then raise exception 'Permiso denegado'; end if;

  select status into v_status from public.dispatch_header where id = p_dispatch_id for update;
  if v_status <> 'confirmed' then raise exception 'Solo se puede observar si esta confirmed'; end if;

  update public.inventory_reservations
  set status = 'released', released_at = now(), release_reason = 'cashier_observed', updated_at = now()
  where dispatch_id = p_dispatch_id and status = 'active';

  update public.dispatch_header
  set status = 'observed', observed_by = v_user_id, observed_at = now(), observation_note = p_note, updated_at = now()
  where id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values ('CASHIER_OBSERVE', v_user_id, p_dispatch_id,
          jsonb_build_object('note', p_note, 'reservation_released', true));
end;
$function$;

create or replace function public.rpc_dispatch_void(
  p_session_token text,
  p_dispatch_id uuid,
  p_reason text default null
)
returns table(success boolean, dispatch_id uuid, previous_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status public.dispatch_status;
  v_source_kind text;
  v_inventory_effect text;
  v_delivery bigint;
  v_expediente text;
  v_item record;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_user_id is null then raise exception 'Sesion invalida o expirada'; end if;
  if v_role <> 'admin' then raise exception 'Permiso denegado: solo el administrador puede anular despachos'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'Debe indicar un motivo para la anulacion'; end if;

  select dh.status, dh.delivery_no, dh.expediente, dh.source_kind, dh.inventory_effect
    into v_status, v_delivery, v_expediente, v_source_kind, v_inventory_effect
  from public.dispatch_header dh where dh.id = p_dispatch_id for update;

  if v_status is null then raise exception 'Despacho no encontrado'; end if;
  if v_status = 'voided' then raise exception 'Este despacho ya fue anulado previamente'; end if;

  if v_status = 'validated' and v_source_kind = 'internal_dispatch' and v_inventory_effect = 'cashier_validation' then
    for v_item in
      select di.id, di.barcode, di.qty, di.product_name_snapshot
      from public.dispatch_items di where di.dispatch_id = p_dispatch_id
    loop
      perform public.inventory_insert_dispatch_movement(
        p_dispatch_id, v_item.id, v_item.barcode, v_item.qty,
        'dispatch_return', 'dispatch_void', 'dispatch_void:' || v_item.id::text,
        v_user_id, 'Devolucion por anulacion de despacho validado',
        jsonb_build_object('product_name', v_item.product_name_snapshot, 'reason', p_reason)
      );
    end loop;
  else
    update public.inventory_reservations
    set status = 'released', released_at = now(), release_reason = 'dispatch_void', updated_at = now()
    where dispatch_id = p_dispatch_id and status = 'active';
  end if;

  update public.dispatch_header dh
  set status = 'voided', voided_by = v_user_id, voided_at = now(), void_reason = p_reason, updated_at = now()
  where dh.id = p_dispatch_id;

  insert into public.audit_log(event_type, user_id, dispatch_id, metadata)
  values (
    'DISPATCH_VOID', v_user_id, p_dispatch_id,
    jsonb_build_object(
      'delivery_no', v_delivery, 'expediente', v_expediente,
      'previous_status', v_status::text, 'source_kind', v_source_kind,
      'inventory_effect', v_inventory_effect, 'reason', p_reason,
      'reservation_released', v_status <> 'validated'
    )
  );

  return query select true, p_dispatch_id, v_status::text;
end;
$function$;

-- Historical rows are deliberately left at version 0 with no synthetic reservation.
-- This prevents retroactive changes to validated, voided, observed or pending records.

commit;
