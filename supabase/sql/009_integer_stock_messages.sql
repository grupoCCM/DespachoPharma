create or replace function public.dispatch_raise_if_stock_insufficient(
  p_barcode text,
  p_requested_qty numeric,
  p_exclude_dispatch_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
begin
  select *
    into v_check
  from public.dispatch_stock_check(p_barcode, p_requested_qty, p_exclude_dispatch_id);

  if v_check.external_code is null then
    raise exception 'No se puede despachar: el producto no cruza con inventario.';
  end if;

  if v_check.ok is not true then
    raise exception 'No se puede despachar %. disponible: %.',
      coalesce(v_check.medicine_name, p_barcode),
      coalesce(floor(v_check.available_qty), 0)::integer;
  end if;
end;
$$;
