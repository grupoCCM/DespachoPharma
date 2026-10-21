-- Classify three audited legacy rows without changing inventory or count data.
-- 720 is a physical expired-unit finding, not a surplus.
-- 730/737 are the already documented crossed-product correction.

begin;

-- Align the case owner with the actual first counter when legacy rows have
-- that attribution. This changes attribution only, never count quantities.
update public.inventory_variance_cases c
set opened_by = i.counted_by
from public.inventory_count_session_items i
where i.id = c.count_item_id
  and i.counted_by is not null
  and c.opened_by is distinct from i.counted_by;

do $$
declare
  v_case record;
  v_reason text;
begin
  for v_case in
    select c.*
    from public.inventory_variance_cases c
    join public.inventory_count_sessions s on s.id = c.count_session_id
    where s.started_at::date = date '2026-10-20'
      and c.external_code in (720, 730, 737)
    for update of c
  loop
    v_reason := case
      when v_case.external_code = 720 then 'Hallazgo de vencimiento fisicamente presente; no es sobrante patrimonial.'
      else 'Cruce documental entre productos 730/737 ya corregido con trazabilidad.'
    end;

    update public.inventory_variance_cases
    set stock_adjustment_status = case
          when external_code = 737 and stock_adjustment_status = 'applied' then 'applied'
          else 'not_required'
        end,
        investigation_status = 'resolved',
        resolved_by = coalesce(resolved_by, opened_by),
        resolved_at = coalesce(resolved_at, now()),
        resolution_note = v_reason,
        metadata = metadata || jsonb_build_object(
          'legacy_classification', case when external_code = 720 then 'condition_finding' else 'documented_crossed_product' end,
          'classified_by_migration', '094_classify_legacy_variance_cases.sql'
        )
    where id = v_case.id;

    insert into public.inventory_variance_resolutions(
      case_id, resolution_type, qty_resolved, amount_recovered, note,
      idempotency_key, created_by, metadata
    ) values (
      v_case.id, 'document_error', abs(v_case.confirmed_variance_qty), 0,
      v_reason, 'legacy_variance_classification:' || v_case.id::text,
      v_case.opened_by,
      jsonb_build_object('migration', '094_classify_legacy_variance_cases.sql')
    ) on conflict (idempotency_key) do nothing;

    insert into public.inventory_variance_case_events(
      case_id, event_type, qty, reason_code, note,
      idempotency_key, created_by, metadata
    ) values (
      v_case.id, 'resolution', abs(v_case.confirmed_variance_qty), 'document_error',
      v_reason, 'legacy_variance_classification_event:' || v_case.id::text,
      v_case.opened_by,
      jsonb_build_object('migration', '094_classify_legacy_variance_cases.sql')
    ) on conflict (idempotency_key) do nothing;

    insert into public.audit_log(event_type, user_id, metadata)
    select 'INVENTORY_COUNT_ITEM_APPLY', v_case.opened_by,
      jsonb_build_object('audit_action', 'variance_case_legacy_classify', 'case_id', v_case.id, 'external_code', v_case.external_code, 'reason', v_reason)
    where not exists (
      select 1 from public.audit_log al
      where al.event_type = 'INVENTORY_COUNT_ITEM_APPLY'
        and al.metadata ->> 'audit_action' = 'variance_case_legacy_classify'
        and al.metadata ->> 'case_id' = v_case.id::text
    );
  end loop;
end;
$$;

commit;

-- Validation: these rows must be administratively resolved and no new
-- inventory_movements may have been created by this migration.
