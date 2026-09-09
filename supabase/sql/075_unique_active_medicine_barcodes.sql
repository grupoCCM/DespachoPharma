-- Prevent active catalog rows from sharing the same barcode. This avoids
-- dispatch resolving a scan to the wrong medicine.
update public.medicines
set barcode = null,
    updated_at = now()
where external_code = 734
  and barcode = '7501298204444'
  and exists (
    select 1
    from public.medicines m75
    where m75.external_code = 742
      and m75.barcode = '7501298204444'
      and m75.active is true
  );

create unique index if not exists medicines_active_barcode_unique
on public.medicines (barcode)
where active is true
  and barcode is not null
  and btrim(barcode) <> '';
