drop index if exists public.purchase_items_source_row_key;

create unique index if not exists purchase_items_business_key
on public.purchase_items (
  purchase_document_id,
  external_code,
  coalesce(description_snapshot, ''),
  qty,
  line_total
);
