-- Read-only validation for migration 095.

-- The summary uses a confirmed recount when present and keeps item totals exact.
with item_base as (
  select
    i.*,
    coalesce(c.confirmed_variance_qty, i.variance_qty) as result_variance_qty
  from public.inventory_count_session_items i
  left join public.inventory_variance_cases c on c.count_item_id = i.id
), direct as (
  select
    s.id,
    count(i.id) as total_items,
    count(i.id) filter (where i.counted_qty is not null) as counted_items,
    count(i.id) filter (where i.counted_qty is null) as pending_items,
    abs(coalesce(sum(i.result_variance_qty) filter (where i.result_variance_qty < 0), 0)) as shortage_qty,
    coalesce(sum(i.result_variance_qty) filter (where i.result_variance_qty > 0), 0) as surplus_qty
  from public.inventory_count_sessions s
  left join item_base i on i.session_id = s.id
  group by s.id
)
select *
from direct
where total_items <> counted_items + pending_items
   or shortage_qty < 0
   or surplus_qty < 0;

-- Closed sessions must retain their frozen quantities.
select s.id, s.title
from public.inventory_count_sessions s
join public.inventory_count_session_items i on i.session_id = s.id
where s.status = 'closed'
  and (i.expected_qty is null or i.expected_unit_cost is null);

-- Variance cases must belong to the same session as their source item.
select c.id, c.count_session_id, i.session_id as item_session_id
from public.inventory_variance_cases c
join public.inventory_count_session_items i on i.id = c.count_item_id
where c.count_session_id <> i.session_id;

-- Security contract for the new RPC.
select
  p.proname,
  p.prosecdef as security_definer,
  p.proconfig,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'rpc_inventory_count_history';
