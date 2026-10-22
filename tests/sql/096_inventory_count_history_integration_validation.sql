-- Read-only validation for migration 096.

-- Cancelled sessions must not retain actionable variance cases.
select
  s.id as session_id,
  s.title,
  c.id as case_id,
  c.stock_adjustment_status,
  c.investigation_status
from public.inventory_count_sessions s
join public.inventory_variance_cases c on c.count_session_id = s.id
where s.status = 'cancelled'
  and (
    c.stock_adjustment_status = 'pending'
    or c.investigation_status <> 'resolved'
  );

-- A confirmed recount must be the result exposed for reprints and summaries.
select
  c.id as case_id,
  i.id as count_item_id,
  c.verified_qty,
  c.confirmed_variance_qty,
  c.verified_qty - i.expected_qty as expected_confirmed_variance
from public.inventory_variance_cases c
join public.inventory_count_session_items i on i.id = c.count_item_id
where c.verified_qty is not null
  and c.confirmed_variance_qty is distinct from c.verified_qty - i.expected_qty;

-- No inventory movement or administrative resolution may reference a
-- cancelled session. Existing rows here require manual investigation.
select
  s.id as session_id,
  c.id as case_id,
  c.stock_adjustment_movement_id,
  count(r.id) as resolution_count
from public.inventory_count_sessions s
join public.inventory_variance_cases c on c.count_session_id = s.id
left join public.inventory_variance_resolutions r on r.case_id = c.id
where s.status = 'cancelled'
group by s.id, c.id, c.stock_adjustment_movement_id
having c.stock_adjustment_movement_id is not null or count(r.id) > 0;

-- Security and fixed search_path contract for the replaced RPCs.
select
  p.proname,
  p.prosecdef as security_definer,
  p.proconfig,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'rpc_inventory_count_session_items',
    'rpc_inventory_count_session_finish',
    'rpc_inventory_variance_apply_stock',
    'rpc_inventory_variance_resolve'
  )
order by p.proname;

