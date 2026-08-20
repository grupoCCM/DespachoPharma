-- Reversal plan for the stale count session that remained open from 2026-07-04.
-- This does not delete history. It creates opposite inventory movements with
-- idempotent source_event_key values, then cancels the stale session to avoid reuse.
--
-- Target session found in production analysis:
--   c1d2eb6f-1d37-4383-8839-3986c4d51ef4
--
-- Target movements:
--   source_type = 'count_session'
--   source_id   = target session id
--   created_at  >= 2026-08-20 00:00:00+00

begin;

with target_movements as (
  select im.*
  from public.inventory_movements im
  where im.source_type = 'count_session'
    and im.source_id = 'c1d2eb6f-1d37-4383-8839-3986c4d51ef4'::uuid
    and im.created_at >= '2026-08-20 00:00:00+00'::timestamptz
    and im.movement_type in ('manual_count_adjust_in', 'manual_count_adjust_out')
),
inserted_reversals as (
  insert into public.inventory_movements(
    movement_type,
    source_type,
    source_id,
    source_item_id,
    source_event_key,
    medicine_id,
    external_code,
    barcode,
    qty_delta,
    unit_cost,
    note,
    created_by,
    metadata
  )
  select
    case
      when tm.qty_delta > 0 then 'stale_count_reversal_out'
      else 'stale_count_reversal_in'
    end,
    'inventory_admin_correction',
    tm.source_id,
    tm.id,
    'stale_count_reversal:' || tm.id::text,
    tm.medicine_id,
    tm.external_code,
    tm.barcode,
    -tm.qty_delta,
    tm.unit_cost,
    'Reversion trazable de ajuste aplicado desde sesion de conteo antigua',
    tm.created_by,
    jsonb_build_object(
      'reason', 'Sesion de conteo antigua aplicada el 2026-08-20 con esperado congelado de julio',
      'original_movement_id', tm.id,
      'original_movement_type', tm.movement_type,
      'original_qty_delta', tm.qty_delta,
      'original_created_at', tm.created_at,
      'stale_session_id', tm.source_id,
      'original_metadata', tm.metadata
    )
  from target_movements tm
  on conflict (source_event_key) where source_event_key is not null do nothing
  returning id, external_code, qty_delta
),
session_cancel as (
  update public.inventory_count_sessions
     set status = 'cancelled',
         closed_at = coalesce(closed_at, now()),
         note = coalesce(nullif(note, ''), 'Sesion antigua cancelada por control de inventario')
   where id = 'c1d2eb6f-1d37-4383-8839-3986c4d51ef4'::uuid
     and status = 'open'
  returning id
)
insert into public.audit_log(event_type, user_id, metadata)
select
  'STALE_COUNT_SESSION_REVERSAL',
  (select created_by from target_movements where created_by is not null limit 1),
  jsonb_build_object(
    'stale_session_id', 'c1d2eb6f-1d37-4383-8839-3986c4d51ef4',
    'reversal_count', (select count(*) from inserted_reversals),
    'reversal_net_qty', coalesce((select sum(qty_delta) from inserted_reversals), 0),
    'cancelled_session', exists(select 1 from session_cancel)
  );

commit;

-- Verification query after running:
-- select external_code, sum(qty_delta) as stock_qty
-- from public.inventory_movements
-- group by external_code
-- having sum(qty_delta) < 0
-- order by stock_qty;
