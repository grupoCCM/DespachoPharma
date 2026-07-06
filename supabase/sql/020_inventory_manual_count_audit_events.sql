do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_MANUAL_COUNT_CREATE';
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_MANUAL_COUNT_APPLY';
exception
  when duplicate_object then null;
end $$;
