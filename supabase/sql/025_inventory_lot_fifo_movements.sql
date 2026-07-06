create table if not exists public.inventory_lot_movements (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid references public.inventory_lots(id) on delete cascade,
  inventory_movement_id uuid references public.inventory_movements(id) on delete cascade,
  movement_type text not null,
  source_type text not null,
  source_id uuid,
  source_item_id uuid,
  source_event_key text,
  medicine_id uuid references public.medicines(id),
  external_code integer,
  barcode text,
  qty_delta numeric(14,4) not null,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint inventory_lot_movements_qty_nonzero check (qty_delta <> 0)
);

create unique index if not exists ux_inventory_lot_movements_source_event_key
on public.inventory_lot_movements(source_event_key)
where source_event_key is not null;

create index if not exists ix_inventory_lot_movements_lot_created
on public.inventory_lot_movements(lot_id, created_at);

create index if not exists ix_inventory_lot_movements_external_created
on public.inventory_lot_movements(external_code, created_at);

create or replace view public.vw_inventory_lot_live as
with latest_snapshot as (
  select id, created_at
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
),
latest_lots as (
  select
    il.id as lot_id,
    il.inventory_snapshot_item_id,
    il.medicine_id,
    i.external_code,
    m.barcode,
    coalesce(m.name, i.description_snapshot) as medicine_name,
    m.model,
    m.secondary_name,
    i.presentation,
    i.stock_qty,
    i.unit_cost,
    i.stock_value,
    il.lot_no,
    il.lot_sequence,
    il.expires_at,
    il.qty as original_lot_qty,
    s.created_at as snapshot_created_at
  from latest_snapshot s
  join public.inventory_snapshot_items i on i.snapshot_id = s.id
  join public.inventory_lots il on il.inventory_snapshot_item_id = i.id
  left join public.medicines m on m.id = i.medicine_id
),
lot_movements as (
  select
    lm.lot_id,
    sum(lm.qty_delta) as movement_qty
  from public.inventory_lot_movements lm
  cross join latest_snapshot s
  where lm.created_at > s.created_at
  group by lm.lot_id
)
select
  ll.*,
  coalesce(lm.movement_qty, 0) as movement_qty,
  ll.original_lot_qty + coalesce(lm.movement_qty, 0) as lot_qty
from latest_lots ll
left join lot_movements lm on lm.lot_id = ll.lot_id;

create or replace function public.inventory_apply_lot_fifo(p_inventory_movement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movement record;
  v_remaining numeric;
  v_take numeric;
  v_lot record;
  v_return record;
begin
  select *
    into v_movement
  from public.inventory_movements
  where id = p_inventory_movement_id;

  if v_movement.id is null or coalesce(v_movement.qty_delta, 0) = 0 then
    return;
  end if;

  if coalesce(v_movement.source_type, '') not in ('dispatch_validate', 'dispatch_void', 'dispatch_adjust') then
    return;
  end if;

  if exists (
    select 1
    from public.inventory_lot_movements
    where inventory_movement_id = v_movement.id
  ) then
    return;
  end if;

  if v_movement.qty_delta < 0 then
    v_remaining := abs(v_movement.qty_delta);

    for v_lot in
      select *
      from public.vw_inventory_lot_live
      where external_code = v_movement.external_code
        and lot_qty > 0
      order by expires_at nulls last, lot_sequence nulls last, lot_no
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_lot.lot_qty);

      insert into public.inventory_lot_movements(
        lot_id, inventory_movement_id, movement_type, source_type, source_id,
        source_item_id, source_event_key, medicine_id, external_code, barcode,
        qty_delta, created_by, metadata
      )
      values (
        v_lot.lot_id,
        v_movement.id,
        v_movement.movement_type,
        v_movement.source_type,
        v_movement.source_id,
        v_movement.source_item_id,
        'lot_fifo:' || v_movement.id::text || ':' || v_lot.lot_id::text,
        v_movement.medicine_id,
        v_movement.external_code,
        v_movement.barcode,
        -1 * v_take,
        v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object(
          'fifo', true,
          'lot_no', v_lot.lot_no,
          'expires_at', v_lot.expires_at,
          'lot_sequence', v_lot.lot_sequence
        )
      )
      on conflict (source_event_key) where source_event_key is not null do nothing;

      v_remaining := v_remaining - v_take;
    end loop;

    if v_remaining > 0 then
      insert into public.inventory_lot_movements(
        lot_id, inventory_movement_id, movement_type, source_type, source_id,
        source_item_id, source_event_key, medicine_id, external_code, barcode,
        qty_delta, created_by, metadata
      )
      values (
        null,
        v_movement.id,
        v_movement.movement_type,
        v_movement.source_type,
        v_movement.source_id,
        v_movement.source_item_id,
        'lot_fifo_unassigned:' || v_movement.id::text,
        v_movement.medicine_id,
        v_movement.external_code,
        v_movement.barcode,
        -1 * v_remaining,
        v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object('fifo', true, 'unassigned_qty', v_remaining)
      )
      on conflict (source_event_key) where source_event_key is not null do nothing;
    end if;
  else
    v_remaining := v_movement.qty_delta;

    for v_return in
      select
        lm.lot_id,
        min(lm.created_at) as first_out_at,
        -1 * sum(lm.qty_delta) as qty_out
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
      )
      values (
        v_return.lot_id,
        v_movement.id,
        v_movement.movement_type,
        v_movement.source_type,
        v_movement.source_id,
        v_movement.source_item_id,
        'lot_return:' || v_movement.id::text || ':' || coalesce(v_return.lot_id::text, 'unassigned'),
        v_movement.medicine_id,
        v_movement.external_code,
        v_movement.barcode,
        v_take,
        v_movement.created_by,
        coalesce(v_movement.metadata, '{}'::jsonb) || jsonb_build_object('fifo_return', true)
      )
      on conflict (source_event_key) where source_event_key is not null do nothing;

      v_remaining := v_remaining - v_take;
    end loop;
  end if;
end;
$$;

create or replace function public.inventory_lot_fifo_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.inventory_apply_lot_fifo(new.id);
  return new;
end;
$$;

drop trigger if exists trg_inventory_lot_fifo_after_movement on public.inventory_movements;
create trigger trg_inventory_lot_fifo_after_movement
after insert on public.inventory_movements
for each row execute function public.inventory_lot_fifo_trigger();

with latest_snapshot as (
  select created_at
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
)
select public.inventory_apply_lot_fifo(im.id)
from public.inventory_movements im
cross join latest_snapshot s
where im.created_at > s.created_at
  and im.source_type in ('dispatch_validate', 'dispatch_void', 'dispatch_adjust')
  and not exists (
    select 1
    from public.inventory_lot_movements lm
    where lm.inventory_movement_id = im.id
  );

drop view if exists public.vw_expiration_risk_latest;
create or replace view public.vw_expiration_risk_latest as
with latest_snapshot as (
  select id, snapshot_date, source_file, created_at
  from public.inventory_snapshots
  order by snapshot_date desc, created_at desc
  limit 1
)
select
  s.snapshot_date,
  s.source_file,
  vl.external_code,
  vl.medicine_name,
  vl.model,
  vl.secondary_name,
  vl.presentation,
  vl.stock_qty,
  vl.unit_cost,
  vl.stock_value,
  vl.lot_no,
  vl.lot_sequence,
  vl.expires_at,
  vl.original_lot_qty,
  vl.lot_qty,
  case
    when vl.expires_at is null then null
    else (vl.expires_at - current_date)
  end as days_to_expire,
  case
    when vl.expires_at is null then 'unknown'
    when vl.expires_at < current_date then 'expired'
    when vl.expires_at <= current_date + interval '30 days' then 'expires_30_days'
    when vl.expires_at <= current_date + interval '90 days' then 'expires_90_days'
    when vl.expires_at <= current_date + interval '180 days' then 'expires_180_days'
    else 'ok'
  end as expiration_status
from latest_snapshot s
join public.vw_inventory_lot_live vl on true
left join public.medicines m on m.id = vl.medicine_id
where coalesce(m.active, true) = true
  and vl.stock_qty > 0
  and vl.lot_qty > 0;

create or replace function public.rpc_inventory_expiration_dashboard(
  p_session_token text,
  p_query text default '',
  p_days integer default 180,
  p_limit integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_query text := trim(coalesce(p_query, ''));
  v_days integer := greatest(0, least(coalesce(p_days, 180), 730));
  v_limit integer := greatest(20, least(coalesce(p_limit, 120), 500));
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Permiso denegado: solo administrador';
  end if;

  return jsonb_build_object(
    'snapshot', (
      select jsonb_build_object(
        'snapshot_date', max(snapshot_date),
        'source_file', max(source_file)
      )
      from public.vw_expiration_risk_latest
    ),
    'summary', (
      select jsonb_build_object(
        'products_with_stock', count(distinct external_code),
        'products_with_lots', count(distinct external_code) filter (where lot_no is not null),
        'lots_total', count(*) filter (where lot_no is not null),
        'expired_lots', count(*) filter (where expiration_status = 'expired'),
        'expires_30_days', count(*) filter (where expiration_status = 'expires_30_days'),
        'expires_90_days', count(*) filter (where expiration_status = 'expires_90_days'),
        'expires_180_days', count(*) filter (where expiration_status = 'expires_180_days'),
        'unknown_lots', count(*) filter (where expiration_status = 'unknown'),
        'risk_stock_value', coalesce(sum((lot_qty * coalesce(unit_cost, 0))) filter (
          where expiration_status in ('expired', 'expires_30_days', 'expires_90_days', 'expires_180_days')
        ), 0)
      )
      from public.vw_expiration_risk_latest
    ),
    'rows', (
      select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
      from (
        select
          snapshot_date,
          source_file,
          external_code,
          medicine_name,
          model,
          secondary_name,
          presentation,
          stock_qty,
          unit_cost,
          stock_value,
          lot_no,
          lot_sequence,
          expires_at,
          original_lot_qty,
          lot_qty,
          days_to_expire,
          expiration_status
        from public.vw_expiration_risk_latest
        where (
            expiration_status = 'expired'
            or expires_at <= current_date + (v_days || ' days')::interval
            or lot_no is null
          )
          and (
            v_query = ''
            or external_code::text = v_query
            or coalesce(medicine_name, '') ilike '%' || v_query || '%'
            or coalesce(model, '') ilike '%' || v_query || '%'
            or coalesce(secondary_name, '') ilike '%' || v_query || '%'
            or coalesce(lot_no, '') ilike '%' || v_query || '%'
          )
        order by expires_at nulls last, medicine_name, lot_sequence, lot_no
        limit v_limit
      ) x
    )
  );
end;
$$;

grant select on public.inventory_lot_movements to authenticated;
grant execute on function public.inventory_apply_lot_fifo(uuid) to anon, authenticated;
grant execute on function public.inventory_lot_fifo_trigger() to anon, authenticated;
grant execute on function public.rpc_inventory_expiration_dashboard(text, text, integer, integer) to anon, authenticated;
