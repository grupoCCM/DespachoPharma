-- Read-only validation for migration 093.

-- 1. A verified case must preserve the arithmetic of the frozen expected qty.
select id, external_code, expected_qty_snapshot, verified_qty, confirmed_variance_qty
from public.inventory_variance_cases
where verified_qty is not null
  and confirmed_variance_qty <> verified_qty - expected_qty_snapshot;

-- 2. The first counter cannot be the verifier.
select c.id, c.external_code, i.counted_by, c.verified_by
from public.inventory_variance_cases c
join public.inventory_count_session_items i on i.id = c.count_item_id
where c.verified_by is not null and c.verified_by = i.counted_by;

-- 3. Resolutions cannot exceed the confirmed difference.
select c.id, c.external_code, abs(c.confirmed_variance_qty) as confirmed_qty,
       coalesce(sum(r.qty_resolved), 0) as resolved_qty
from public.inventory_variance_cases c
left join public.inventory_variance_resolutions r on r.case_id = c.id
where c.confirmed_variance_qty is not null
group by c.id
having coalesce(sum(r.qty_resolved), 0) > abs(c.confirmed_variance_qty);

-- 4. An applied case must have its idempotent stock movement.
select c.id, c.external_code, c.stock_adjustment_movement_id
from public.inventory_variance_cases c
where c.stock_adjustment_status = 'applied'
  and not exists (
    select 1 from public.inventory_movements im
    where im.id = c.stock_adjustment_movement_id
       or (im.source_id = c.id and im.source_type = 'inventory_variance_case')
       or (im.source_item_id = c.count_item_id and im.source_type in ('count_session','inventory_admin_correction','inventory_reclass'))
  );

-- 5. Izaban must be represented as adjusted stock but open investigation.
select external_code, expected_qty_snapshot, first_count_qty, verified_qty,
       confirmed_variance_qty, stock_adjustment_status, investigation_status,
       exposure_value
from public.inventory_variance_cases
where external_code = 750
order by opened_at desc;
