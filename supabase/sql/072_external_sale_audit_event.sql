-- Allow external sale reconciliation to be audited with its own event type.

alter type public.audit_event_type
  add value if not exists 'EXTERNAL_SALE_RECONCILED';
