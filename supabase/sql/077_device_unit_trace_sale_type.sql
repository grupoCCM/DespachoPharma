-- Expose the business meaning of a device exit in inventory listings.
-- Additive view change only: no historical rows are updated.

create or replace view public.vw_device_unit_trace
with (security_invoker = true) as
select
  u.id as device_unit_id,
  p.id as device_product_id,
  p.external_code,
  p.name as product_name,
  p.category,
  p.brand_name,
  p.model,
  u.serial_code,
  u.lot_no,
  u.expires_at,
  u.status,
  u.cost,
  u.source_doc_no,
  u.registered_at,
  ru.display_name as registered_by_name,
  u.sold_at,
  su.display_name as sold_by_name,
  s.sale_no,
  s.expediente,
  u.note,
  p.active as product_active,
  p.sale_price,
  p.default_cost,
  u.source_file,
  u.updated_at,
  s.sale_type,
  s.replacement_reason
from public.device_units u
join public.device_products p on p.id = u.device_product_id
left join public.app_users ru on ru.id = u.registered_by
left join public.app_users su on su.id = u.sold_by
left join public.device_sales s on s.id = u.sale_id;

comment on view public.vw_device_unit_trace is
  'Device unit trace including whether an exit was a sale or a replacement.';
