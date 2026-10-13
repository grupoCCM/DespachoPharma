-- Restate the confirmed acquisition cost for SIBIONICS product 805.
-- This changes cost valuation only; quantities, statuses, serials and movements stay untouched.

begin;

alter table public.device_admin_audit
  drop constraint if exists device_admin_audit_action_check,
  add constraint device_admin_audit_action_check
    check (action in ('unit_update','unit_retire','bulk_register','cost_bulk_correction'));

do $$
declare
  v_product_id uuid;
  v_unit_count integer;
  v_sale_item_count integer;
begin
  select id into v_product_id
  from public.device_products
  where external_code = 805
  for update;

  if v_product_id is null then
    raise exception 'No existe el producto de dispositivos 805';
  end if;

  perform 1
  from public.device_units
  where device_product_id = v_product_id
  for update;

  insert into public.device_admin_audit(
    device_unit_id,
    device_product_id,
    action,
    reason,
    old_data,
    new_data,
    created_by
  )
  select
    u.id,
    u.device_product_id,
    'cost_bulk_correction',
    'Costo real sin IVA confirmado: USD 53.095000',
    jsonb_build_object(
      'unit_cost', u.cost,
      'cost_source', u.cost_source,
      'sale_item_cost', si.cost
    ),
    jsonb_build_object(
      'unit_cost', 53.0950,
      'cost_source', 'corrected',
      'sale_item_cost', case when si.id is null then null else 53.0950 end,
      'external_code', 805
    ),
    null
  from public.device_units u
  left join public.device_sale_items si on si.device_unit_id = u.id
  where u.device_product_id = v_product_id
    and (
      u.cost is distinct from 53.0950
      or (si.id is not null and si.cost is distinct from 53.0950)
    );

  get diagnostics v_unit_count = row_count;

  update public.device_products
  set default_cost = 53.0950,
      updated_at = now()
  where id = v_product_id;

  update public.device_units
  set cost = 53.0950,
      cost_source = 'corrected',
      updated_at = now()
  where device_product_id = v_product_id
    and (cost is distinct from 53.0950 or cost_source <> 'corrected');

  update public.device_sale_items
  set cost = 53.0950
  where device_product_id = v_product_id
    and cost is distinct from 53.0950;

  get diagnostics v_sale_item_count = row_count;

  raise notice 'SIBIONICS cost restatement: % audited units, % sale items updated',
    v_unit_count, v_sale_item_count;
end;
$$;

do $$
begin
  if exists (
    select 1
    from public.device_units u
    join public.device_products p on p.id = u.device_product_id
    where p.external_code = 805
      and u.cost is distinct from 53.0950
  ) then
    raise exception 'La correccion de costo no cubrio todas las unidades SIBIONICS';
  end if;

  if exists (
    select 1
    from public.device_sale_items si
    join public.device_products p on p.id = si.device_product_id
    where p.external_code = 805
      and si.cost is distinct from 53.0950
  ) then
    raise exception 'La correccion de costo no cubrio todas las ventas SIBIONICS';
  end if;
end;
$$;

commit;

