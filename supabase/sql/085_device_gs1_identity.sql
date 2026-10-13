-- Canonical device identity and GS1 parsing.
-- Existing units and movements are preserved; no historical serial is rewritten automatically.

alter table public.device_units
  add column if not exists raw_scan_code text,
  add column if not exists gtin text,
  add column if not exists manufactured_at date,
  add column if not exists cost_source text not null default 'legacy';

alter table public.device_units
  drop constraint if exists device_units_cost_source_check,
  add constraint device_units_cost_source_check
    check (cost_source in ('legacy','entered','catalog_default','corrected'));

create table if not exists public.device_unit_identifiers (
  id uuid primary key default gen_random_uuid(),
  device_unit_id uuid not null references public.device_units(id),
  identifier_type text not null,
  identifier_value text not null,
  normalized_identifier text generated always as (
    lower(regexp_replace(trim(identifier_value), '\s+', '', 'g'))
  ) stored,
  active boolean not null default true,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  constraint device_unit_identifiers_type_check
    check (identifier_type in ('canonical','gs1_raw','former_serial')),
  constraint device_unit_identifiers_value_check
    check (length(trim(identifier_value)) > 0)
);

create unique index if not exists ux_device_unit_identifiers_normalized
on public.device_unit_identifiers(normalized_identifier);

create index if not exists idx_device_unit_identifiers_unit
on public.device_unit_identifiers(device_unit_id, active);

alter table public.device_unit_identifiers enable row level security;

insert into public.device_unit_identifiers(
  device_unit_id, identifier_type, identifier_value, created_by
)
select u.id, 'canonical', u.serial_code, u.registered_by
from public.device_units u
where not exists (
  select 1
  from public.device_unit_identifiers i
  where i.device_unit_id = u.id
    and i.identifier_type = 'canonical'
)
on conflict (normalized_identifier) do nothing;

create or replace function public.device_parse_identifier(p_identifier text)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_clean text := upper(regexp_replace(replace(trim(coalesce(p_identifier,'')), chr(29), ''), '\s+', '', 'g'));
  v_parts text[];
  v_serial text;
  v_gtin text;
  v_lot text;
  v_mfg_text text;
  v_exp_text text;
  v_mfg date;
  v_exp date;
  v_is_gs1 boolean := false;
begin
  v_parts := regexp_match(
    v_clean,
    '^01([0-9]{14})(?:11([0-9]{6}))?(?:17([0-9]{6}))?10(.{1,20})21([A-Z0-9-]{6,40})$'
  );

  if v_parts is not null then
    v_is_gs1 := true;
    v_gtin := v_parts[1];
    v_mfg_text := v_parts[2];
    v_exp_text := v_parts[3];
    v_lot := v_parts[4];
    v_serial := v_parts[5];

    if v_mfg_text is not null then
      v_mfg := to_date('20' || v_mfg_text, 'YYYYMMDD');
      if to_char(v_mfg, 'YYMMDD') <> v_mfg_text then v_mfg := null; end if;
    end if;
    if v_exp_text is not null then
      v_exp := to_date('20' || v_exp_text, 'YYYYMMDD');
      if to_char(v_exp, 'YYMMDD') <> v_exp_text then v_exp := null; end if;
    end if;
  else
    v_serial := v_clean;
  end if;

  return jsonb_build_object(
    'input_code', v_clean,
    'canonical_serial', v_serial,
    'normalized_serial', lower(v_serial),
    'is_gs1', v_is_gs1,
    'gtin', v_gtin,
    'manufactured_at', v_mfg,
    'expires_at', v_exp,
    'lot_no', v_lot,
    'valid', v_serial ~ '^[A-Z0-9-]{6,40}$'
  );
end;
$$;

create or replace function public.rpc_device_identifier_preview(
  p_session_token text,
  p_identifier text,
  p_device_unit_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role public.user_role;
  v_parsed jsonb;
  v_raw_normalized text;
  v_canonical_normalized text;
  v_match jsonb;
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then
    raise exception 'Solo administrador puede interpretar identificadores de dispositivos';
  end if;

  v_parsed := public.device_parse_identifier(p_identifier);
  v_raw_normalized := lower(regexp_replace(coalesce(v_parsed->>'input_code',''), '\s+', '', 'g'));
  v_canonical_normalized := lower(coalesce(v_parsed->>'canonical_serial',''));

  select jsonb_build_object(
    'device_unit_id', u.id,
    'serial_code', u.serial_code,
    'status', u.status,
    'external_code', p.external_code,
    'product_name', p.name,
    'same_unit', u.id = p_device_unit_id
  ) into v_match
  from public.device_unit_identifiers i
  join public.device_units u on u.id = i.device_unit_id
  join public.device_products p on p.id = u.device_product_id
  where i.active = true
    and i.normalized_identifier in (v_raw_normalized, v_canonical_normalized)
  order by case when i.normalized_identifier = v_raw_normalized then 0 else 1 end
  limit 1;

  return jsonb_build_object('parsed', v_parsed, 'matching_unit', v_match);
end;
$$;

create or replace function public.rpc_device_unit_register(
  p_session_token text,
  p_external_code integer,
  p_serial_code text,
  p_lot_no text default null,
  p_expires_at date default null,
  p_cost numeric default null,
  p_source_doc_no text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_product public.device_products%rowtype;
  v_unit_id uuid;
  v_parsed jsonb := public.device_parse_identifier(p_serial_code);
  v_serial text := v_parsed->>'canonical_serial';
  v_raw text := v_parsed->>'input_code';
  v_lot text := coalesce(nullif(trim(coalesce(p_lot_no,'')), ''), nullif(v_parsed->>'lot_no',''));
  v_expires date := coalesce(p_expires_at, nullif(v_parsed->>'expires_at','')::date);
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then raise exception 'Solo administrador puede registrar unidades de dispositivos'; end if;
  if coalesce((v_parsed->>'valid')::boolean, false) is not true then raise exception 'Codigo unico invalido'; end if;

  if exists (
    select 1 from public.device_unit_identifiers
    where normalized_identifier in (lower(v_serial), lower(v_raw)) and active = true
  ) then
    raise exception 'El dispositivo ya esta registrado: %', v_serial;
  end if;

  select * into v_product from public.device_products where external_code = p_external_code and active = true;
  if v_product.id is null then raise exception 'Producto/dispositivo no activo o no existe'; end if;

  insert into public.device_units(
    device_product_id, serial_code, raw_scan_code, gtin, manufactured_at,
    lot_no, expires_at, cost, cost_source, source_doc_no, registered_by, note
  ) values (
    v_product.id, v_serial, case when v_raw <> v_serial then v_raw else null end,
    nullif(v_parsed->>'gtin',''), nullif(v_parsed->>'manufactured_at','')::date,
    v_lot, v_expires, coalesce(p_cost, v_product.default_cost),
    case when p_cost is null then 'catalog_default' else 'entered' end,
    nullif(trim(coalesce(p_source_doc_no,'')), ''), v_user_id, nullif(trim(coalesce(p_note,'')), '')
  ) returning id into v_unit_id;

  insert into public.device_unit_identifiers(device_unit_id, identifier_type, identifier_value, created_by)
  values (v_unit_id, 'canonical', v_serial, v_user_id);
  if v_raw <> v_serial then
    insert into public.device_unit_identifiers(device_unit_id, identifier_type, identifier_value, created_by)
    values (v_unit_id, 'gs1_raw', v_raw, v_user_id);
  end if;

  insert into public.device_inventory_movements(
    device_unit_id, device_product_id, serial_code, movement_type, qty_delta,
    source_type, source_id, source_event_key, note, created_by
  ) values (
    v_unit_id, v_product.id, v_serial, 'receive', 1,
    'device_unit_register', v_unit_id, 'device_unit_register:' || lower(v_serial),
    'Ingreso de unidad serializada', v_user_id
  );

  return jsonb_build_object('unit_id',v_unit_id,'status','available','parsed',v_parsed,'cost_source',case when p_cost is null then 'catalog_default' else 'entered' end);
exception when unique_violation then
  raise exception 'El dispositivo o una lectura equivalente ya existe: %', v_serial;
end;
$$;

create or replace function public.rpc_device_units_bulk_register(
  p_session_token text,
  p_external_code integer,
  p_serials jsonb,
  p_lot_no text default null,
  p_expires_at date default null,
  p_cost numeric default null,
  p_source_doc_no text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_product public.device_products%rowtype;
  v_raw_count integer := 0;
  v_unique_count integer := 0;
  v_invalid_count integer := 0;
  v_existing_count integer := 0;
  v_inserted_count integer := 0;
  v_row record;
  v_unit_id uuid;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then raise exception 'Solo administrador puede registrar unidades de dispositivos'; end if;
  select * into v_product from public.device_products where external_code = p_external_code and active = true;
  if v_product.id is null then raise exception 'Producto/dispositivo no activo o no existe'; end if;

  create temp table tmp_device_bulk_serials(
    raw_code text not null,
    canonical_serial text not null,
    normalized_serial text primary key,
    parsed jsonb not null,
    is_valid boolean not null
  ) on commit drop;

  insert into tmp_device_bulk_serials(raw_code,canonical_serial,normalized_serial,parsed,is_valid)
  select x.parsed->>'input_code', x.parsed->>'canonical_serial', lower(x.parsed->>'canonical_serial'),
    x.parsed, coalesce((x.parsed->>'valid')::boolean,false)
  from jsonb_array_elements_text(coalesce(p_serials,'[]'::jsonb)) r(value)
  cross join lateral (select public.device_parse_identifier(r.value) parsed) x
  where length(trim(r.value)) > 0
  on conflict (normalized_serial) do nothing;

  select count(*) into v_raw_count from jsonb_array_elements_text(coalesce(p_serials,'[]'::jsonb)) r(value) where length(trim(r.value)) > 0;
  select count(*) into v_unique_count from tmp_device_bulk_serials;
  select count(*) into v_invalid_count from tmp_device_bulk_serials where not is_valid;
  if v_unique_count = 0 then raise exception 'No hay codigos para registrar'; end if;
  if v_invalid_count > 0 then raise exception 'Hay % codigo(s) con formato invalido', v_invalid_count; end if;

  select count(*) into v_existing_count
  from tmp_device_bulk_serials t
  where exists (
    select 1 from public.device_unit_identifiers i
    where i.active = true
      and i.normalized_identifier in (lower(t.raw_code), t.normalized_serial)
  );

  for v_row in
    select * from tmp_device_bulk_serials t
    where not exists (
      select 1 from public.device_unit_identifiers i
      where i.active = true
        and i.normalized_identifier in (lower(t.raw_code), t.normalized_serial)
    )
    order by canonical_serial
  loop
    insert into public.device_units(
      device_product_id,serial_code,raw_scan_code,gtin,manufactured_at,lot_no,expires_at,
      cost,cost_source,source_doc_no,registered_by,note,source_file
    ) values (
      v_product.id,v_row.canonical_serial,case when v_row.raw_code <> v_row.canonical_serial then v_row.raw_code else null end,
      nullif(v_row.parsed->>'gtin',''),nullif(v_row.parsed->>'manufactured_at','')::date,
      coalesce(nullif(trim(coalesce(p_lot_no,'')),''),nullif(v_row.parsed->>'lot_no','')),
      coalesce(p_expires_at,nullif(v_row.parsed->>'expires_at','')::date),
      coalesce(p_cost,v_product.default_cost),case when p_cost is null then 'catalog_default' else 'entered' end,
      nullif(trim(coalesce(p_source_doc_no,'')),''),v_user_id,nullif(trim(coalesce(p_note,'')),''),'Carga masiva UI'
    ) returning id into v_unit_id;

    insert into public.device_unit_identifiers(device_unit_id,identifier_type,identifier_value,created_by)
    values(v_unit_id,'canonical',v_row.canonical_serial,v_user_id);
    if v_row.raw_code <> v_row.canonical_serial then
      insert into public.device_unit_identifiers(device_unit_id,identifier_type,identifier_value,created_by)
      values(v_unit_id,'gs1_raw',v_row.raw_code,v_user_id);
    end if;

    insert into public.device_inventory_movements(
      device_unit_id,device_product_id,serial_code,movement_type,qty_delta,source_type,source_id,source_event_key,note,created_by
    ) values (
      v_unit_id,v_product.id,v_row.canonical_serial,'receive',1,'device_bulk_register',v_unit_id,
      'device_bulk_register:'||lower(v_row.canonical_serial),'Ingreso por carga masiva de unidades serializadas',v_user_id
    );

    insert into public.device_admin_audit(device_unit_id,device_product_id,action,reason,old_data,new_data,created_by)
    values(v_unit_id,v_product.id,'bulk_register','Carga masiva de unidades',null,
      jsonb_build_object('serial_code',v_row.canonical_serial,'raw_scan_code',v_row.raw_code,'external_code',p_external_code,'status','available'),v_user_id);
    v_inserted_count := v_inserted_count + 1;
  end loop;

  return jsonb_build_object('received_lines',v_raw_count,'unique_lines',v_unique_count,
    'duplicated_in_batch',greatest(v_raw_count-v_unique_count,0),'existing',v_existing_count,
    'inserted',v_inserted_count);
end;
$$;

create or replace function public.rpc_device_unit_lookup(p_session_token text,p_serial_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role public.user_role;
  v_parsed jsonb := public.device_parse_identifier(p_serial_code);
  v_raw text := lower(coalesce(v_parsed->>'input_code',''));
  v_serial text := lower(coalesce(v_parsed->>'canonical_serial',''));
  v_unit_id uuid;
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role not in ('admin','dispatch','cashier') then raise exception 'No autorizado para consultar dispositivos'; end if;
  if v_serial = '' then return null; end if;

  select i.device_unit_id into v_unit_id
  from public.device_unit_identifiers i
  where i.active = true and i.normalized_identifier in (v_raw,v_serial)
  order by case when i.normalized_identifier=v_raw then 0 else 1 end
  limit 1;

  return (
    select to_jsonb(x)
    from (
      select u.id device_unit_id,u.device_product_id,p.external_code,p.name product_name,p.category,p.brand_name,p.model,
        u.serial_code,u.raw_scan_code,u.gtin,u.manufactured_at,u.lot_no,u.expires_at,u.status,u.cost,u.cost_source,
        p.sale_price,(u.status='available' and p.active=true) can_dispatch,
        v_parsed scanned_identifier
      from public.device_units u
      join public.device_products p on p.id=u.device_product_id
      where u.id=v_unit_id
    ) x
  );
end;
$$;

create or replace function public.rpc_device_dispatch_submit(
  p_session_token text,
  p_expediente text,
  p_serials jsonb,
  p_sale_type text default 'sale',
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid; v_role public.user_role; v_sale_id uuid; v_sale_no bigint;
  v_input text; v_parsed jsonb; v_unit_id uuid; v_unit public.device_units%rowtype;
  v_product public.device_products%rowtype; v_sale_type text:=lower(trim(coalesce(p_sale_type,'sale')));
  v_reason text:=nullif(trim(coalesce(p_reason,'')),''); v_price numeric(14,4); v_items integer:=0;
begin
  select user_id,role into v_user_id,v_role from public.app_require_session(p_session_token);
  if v_role <> 'dispatch' then raise exception 'Solo despacho puede vender dispositivos'; end if;
  if v_sale_type not in ('sale','replacement') then raise exception 'Tipo de salida invalido: %',p_sale_type; end if;
  if v_sale_type='replacement' and v_reason is null then raise exception 'Debe indicar el motivo de la reposicion'; end if;
  if length(trim(coalesce(p_expediente,'')))=0 then raise exception 'Expediente requerido'; end if;

  create temp table tmp_device_dispatch_units(unit_id uuid primary key) on commit drop;
  for v_input in select value from jsonb_array_elements_text(coalesce(p_serials,'[]'::jsonb)) r(value) where length(trim(value))>0 loop
    v_parsed:=public.device_parse_identifier(v_input);
    select i.device_unit_id into v_unit_id from public.device_unit_identifiers i
    where i.active=true and i.normalized_identifier in (lower(v_parsed->>'input_code'),lower(v_parsed->>'canonical_serial'))
    order by case when i.normalized_identifier=lower(v_parsed->>'input_code') then 0 else 1 end limit 1;
    if v_unit_id is null then raise exception 'Codigo unico no registrado: %',v_parsed->>'canonical_serial'; end if;
    insert into tmp_device_dispatch_units values(v_unit_id) on conflict do nothing;
  end loop;
  select count(*) into v_items from tmp_device_dispatch_units;
  if v_items=0 then raise exception 'Agrega al menos un dispositivo'; end if;

  insert into public.device_sales(expediente,status,created_by,sale_type,replacement_reason,note)
  values(trim(p_expediente),'confirmed',v_user_id,v_sale_type,
    case when v_sale_type='replacement' then v_reason end,
    case when v_sale_type='replacement' then 'Reposicion: '||v_reason end)
  returning id,sale_no into v_sale_id,v_sale_no;

  for v_unit_id in select unit_id from tmp_device_dispatch_units order by unit_id loop
    select * into v_unit from public.device_units where id=v_unit_id for update;
    if v_unit.status <> 'available' then raise exception 'El dispositivo % no esta disponible. Estado actual: %',v_unit.serial_code,v_unit.status; end if;
    select * into v_product from public.device_products where id=v_unit.device_product_id for update;
    if v_product.id is null or v_product.active is distinct from true then raise exception 'Producto no activo para el dispositivo %',v_unit.serial_code; end if;
    v_price:=case when v_sale_type='replacement' then 0 else coalesce(v_product.sale_price,0) end;
    update public.device_units set status='sold',sold_at=now(),sold_by=v_user_id,sale_id=v_sale_id where id=v_unit.id;
    insert into public.device_sale_items(sale_id,device_unit_id,device_product_id,serial_code,product_name_snapshot,price,cost,sale_type)
    values(v_sale_id,v_unit.id,v_product.id,v_unit.serial_code,v_product.name,v_price,v_unit.cost,v_sale_type);
    insert into public.device_inventory_movements(device_unit_id,device_product_id,serial_code,movement_type,qty_delta,source_type,source_id,source_event_key,note,created_by)
    values(v_unit.id,v_product.id,v_unit.serial_code,v_sale_type,-1,'device_sale',v_sale_id,'device_sale:'||v_sale_id::text||':'||v_unit.id::text,
      case when v_sale_type='replacement' then 'Reposicion de dispositivo: '||v_reason else 'Venta definitiva de dispositivo' end,v_user_id);
  end loop;
  return jsonb_build_object('sale_id',v_sale_id,'sale_no',v_sale_no,'items',v_items,'sale_type',v_sale_type);
end;
$$;

alter table public.device_inventory_adjustments
  drop constraint if exists device_inventory_adjustments_action_check,
  add constraint device_inventory_adjustments_action_check
    check (action in ('correction','retire','reinstate','reclassify','identifier_correction'));

create or replace function public.tg_device_adjustment_cost_source()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.action = 'correction'
     and (new.old_data->>'cost') is distinct from (new.new_data->>'cost') then
    update public.device_units
    set cost_source = 'corrected'
    where id = new.device_unit_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_device_adjustment_cost_source on public.device_inventory_adjustments;
create trigger trg_device_adjustment_cost_source
after insert on public.device_inventory_adjustments
for each row execute function public.tg_device_adjustment_cost_source();

create or replace function public.rpc_device_identifier_correct(
  p_session_token text,
  p_request_id uuid,
  p_device_unit_id uuid,
  p_identifier text,
  p_reason_code text,
  p_reason_detail text,
  p_reference_no text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid; v_role public.user_role; v_old public.device_units%rowtype;
  v_parsed jsonb:=public.device_parse_identifier(p_identifier); v_serial text:=v_parsed->>'canonical_serial';
  v_raw text:=v_parsed->>'input_code'; v_reason_code text:=lower(trim(coalesce(p_reason_code,'')));
  v_reason_detail text:=nullif(trim(coalesce(p_reason_detail,'')),''); v_existing public.device_inventory_adjustments%rowtype;
  v_conflict uuid; v_adjustment_id uuid; v_adjustment_no bigint; v_new_data jsonb;
begin
  select user_id,role into v_user_id,v_role from public.app_require_session(p_session_token);
  if v_role <> 'admin' then raise exception 'Solo administrador puede corregir identificadores'; end if;
  if p_request_id is null then raise exception 'Identificador de solicitud requerido'; end if;
  if coalesce((v_parsed->>'valid')::boolean,false) is not true then raise exception 'Codigo unico invalido'; end if;
  if v_reason_code not in ('entry_error','damage','loss','found','repaired','return','other') then raise exception 'Motivo no permitido'; end if;
  if v_reason_detail is null or length(v_reason_detail)<3 then raise exception 'Describe el motivo de la correccion'; end if;

  select * into v_existing from public.device_inventory_adjustments where request_id=p_request_id;
  if v_existing.id is not null then return jsonb_build_object('status','already_applied','adjustment_no',v_existing.adjustment_no,'parsed',v_parsed); end if;
  select * into v_old from public.device_units where id=p_device_unit_id for update;
  if v_old.id is null then raise exception 'Unidad no encontrada'; end if;
  if v_old.status='sold' or v_old.sale_id is not null then raise exception 'Una unidad entregada requiere anulacion antes de corregir su identificador'; end if;

  select i.device_unit_id into v_conflict from public.device_unit_identifiers i
  where i.active=true and i.device_unit_id<>v_old.id and i.normalized_identifier in (lower(v_serial),lower(v_raw)) limit 1;
  if v_conflict is not null then raise exception 'El serial o su lectura GS1 ya pertenecen a otra unidad'; end if;
  if lower(v_old.serial_code)=lower(v_serial) and lower(coalesce(v_old.raw_scan_code,v_old.serial_code))=lower(v_raw) then
    raise exception 'El identificador nuevo es igual al actual';
  end if;

  update public.device_unit_identifiers set identifier_value=v_serial
  where device_unit_id=v_old.id and identifier_type='canonical';
  if not found then
    insert into public.device_unit_identifiers(device_unit_id,identifier_type,identifier_value,created_by)
    values(v_old.id,'canonical',v_serial,v_user_id);
  end if;
  if lower(v_raw)<>lower(v_serial) then
    insert into public.device_unit_identifiers(device_unit_id,identifier_type,identifier_value,created_by)
    values(v_old.id,'gs1_raw',v_raw,v_user_id) on conflict(normalized_identifier) do nothing;
  end if;
  if lower(v_old.serial_code) not in (lower(v_serial),lower(v_raw)) then
    insert into public.device_unit_identifiers(device_unit_id,identifier_type,identifier_value,created_by)
    values(v_old.id,'former_serial',v_old.serial_code,v_user_id) on conflict(normalized_identifier) do nothing;
  end if;

  update public.device_units
  set serial_code=v_serial,raw_scan_code=case when v_raw<>v_serial then v_raw else null end,
      gtin=nullif(v_parsed->>'gtin',''),manufactured_at=nullif(v_parsed->>'manufactured_at','')::date
  where id=v_old.id;
  select to_jsonb(u) into v_new_data from public.device_units u where id=v_old.id;
  insert into public.device_inventory_adjustments(
    request_id,device_unit_id,action,from_product_id,to_product_id,from_status,to_status,qty_delta,
    reason_code,reason_detail,reference_no,old_data,new_data,created_by
  ) values (
    p_request_id,v_old.id,'identifier_correction',v_old.device_product_id,v_old.device_product_id,
    v_old.status,v_old.status,0,v_reason_code,v_reason_detail,nullif(trim(coalesce(p_reference_no,'')),''),to_jsonb(v_old),v_new_data,v_user_id
  ) returning id,adjustment_no into v_adjustment_id,v_adjustment_no;
  return jsonb_build_object('status','applied','adjustment_id',v_adjustment_id,'adjustment_no',v_adjustment_no,'parsed',v_parsed);
exception when unique_violation then
  raise exception 'El serial o una lectura equivalente ya estan registrados';
end;
$$;

revoke all on function public.device_parse_identifier(text) from public;
revoke all on function public.rpc_device_identifier_preview(text,text,uuid) from public;
revoke all on function public.rpc_device_identifier_correct(text,uuid,uuid,text,text,text,text) from public;
grant execute on function public.rpc_device_identifier_preview(text,text,uuid) to anon,authenticated;
grant execute on function public.rpc_device_identifier_correct(text,uuid,uuid,text,text,text,text) to anon,authenticated;

notify pgrst, 'reload schema';
