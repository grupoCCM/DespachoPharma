-- Objetivo:
-- Blindar la regla equivalente a "codigo unico no duplicado" para dispositivos.
-- En dispositivos el codigo escaneado pertenece a la unidad fisica
-- (device_units.serial_code), no al producto maestro.

begin;

do $$
begin
  if exists (
    select 1
    from public.device_units
    where nullif(btrim(serial_code), '') is null
  ) then
    raise exception 'DEVICE_SERIAL_BLANK: existen dispositivos con codigo unico vacio.';
  end if;

  if exists (
    select normalized_serial
    from public.device_units
    group by normalized_serial
    having count(*) > 1
  ) then
    raise exception 'DEVICE_SERIAL_DUPLICATE: existen codigos unicos de dispositivo duplicados.';
  end if;
end $$;

create unique index if not exists ux_device_units_normalized_serial
  on public.device_units(normalized_serial);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'device_units_normalized_serial_not_blank'
      and conrelid = 'public.device_units'::regclass
  ) then
    alter table public.device_units
      add constraint device_units_normalized_serial_not_blank
      check (length(normalized_serial) > 0);
  end if;
end $$;

comment on column public.device_units.serial_code is
  'Codigo unico fisico del dispositivo. Es el valor operativo que se escanea.';

comment on column public.device_units.normalized_serial is
  'Codigo unico normalizado y no duplicable para impedir que una misma unidad fisica se registre dos veces.';

comment on index public.ux_device_units_normalized_serial is
  'Garantiza que cada dispositivo fisico tenga un codigo unico en todo el inventario.';

commit;
