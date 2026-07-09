create or replace function public.app_pin_active_match_count(
  p_pin text,
  p_exclude_user_id uuid default null
)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.app_users u
  where u.active is true
    and (p_exclude_user_id is null or u.id <> p_exclude_user_id)
    and public.app_verify_pin(p_pin, u.pin_hash);
$$;

create or replace function public.rpc_pin_login(p_pin text)
returns table(
  user_id uuid,
  display_name text,
  role public.user_role,
  session_token text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_pin text;
  v_user public.app_users%rowtype;
  v_matches integer;
  v_token text;
  v_token_hash text;
  v_expires timestamptz;
begin
  v_pin := regexp_replace(trim(coalesce(p_pin, '')), '\D', '', 'g');
  if v_pin !~ '^\d{4}$' then
    return;
  end if;

  select count(*)::integer
    into v_matches
  from public.app_users u
  where u.active is true
    and public.app_verify_pin(v_pin, u.pin_hash);

  if coalesce(v_matches, 0) = 0 then
    return;
  end if;

  if v_matches > 1 then
    raise exception 'PIN duplicado: contacte al administrador.';
  end if;

  select * into v_user
  from public.app_users u
  where u.active is true
    and public.app_verify_pin(v_pin, u.pin_hash)
  limit 1;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_expires := now() + interval '30 minutes';

  insert into public.app_sessions(user_id, token_hash, expires_at)
  values (v_user.id, v_token_hash, v_expires);

  insert into public.audit_log(event_type, user_id, metadata)
  values ('LOGIN', v_user.id, jsonb_build_object('via', 'pin'));

  return query
  select v_user.id, v_user.display_name, v_user.role, v_token, v_expires;
end;
$$;

create or replace function public.rpc_admin_user_create(
  p_session_token text,
  p_display_name text,
  p_role text,
  p_pin text
)
returns table(user_id uuid)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_admin_id uuid;
  v_admin_role public.user_role;
  v_pin text;
  v_hash text;
begin
  select s.user_id, s.role
    into v_admin_id, v_admin_role
  from public.app_require_session(p_session_token) as s;

  if v_admin_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_admin_role <> 'admin' then
    raise exception 'Permiso denegado';
  end if;

  if p_display_name is null or length(trim(p_display_name)) < 3 then
    raise exception 'Nombre invalido';
  end if;

  if p_role is null or lower(p_role) not in ('admin', 'dispatch', 'cashier') then
    raise exception 'Rol invalido';
  end if;

  v_pin := regexp_replace(trim(coalesce(p_pin, '')), '\D', '', 'g');
  if v_pin !~ '^\d{4}$' then
    raise exception 'PIN debe ser 4 digitos';
  end if;

  if public.app_pin_active_match_count(v_pin, null) > 0 then
    raise exception 'PIN duplicado: ya esta asignado a otro usuario activo.';
  end if;

  v_hash := extensions.crypt(v_pin, extensions.gen_salt('bf', 10));

  insert into public.app_users (id, display_name, role, active, pin_hash)
  values (
    extensions.gen_random_uuid(),
    trim(p_display_name),
    lower(p_role)::public.user_role,
    true,
    v_hash
  )
  returning id into user_id;

  return next;
end;
$$;

create or replace function public.rpc_admin_user_set_pin(
  p_session_token text,
  p_user_id uuid,
  p_pin text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s record;
  v_pin text;
begin
  select user_id, role into s
  from public.app_require_session(p_session_token);

  if s.user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if s.role <> 'admin' then
    raise exception 'Permiso denegado';
  end if;

  v_pin := regexp_replace(trim(coalesce(p_pin, '')), '\D', '', 'g');
  if v_pin !~ '^\d{4}$' then
    raise exception 'PIN debe ser 4 digitos';
  end if;

  if not exists (select 1 from public.app_users where id = p_user_id) then
    raise exception 'Usuario no existe';
  end if;

  if public.app_pin_active_match_count(v_pin, p_user_id) > 0 then
    raise exception 'PIN duplicado: ya esta asignado a otro usuario activo.';
  end if;

  update public.app_users
  set pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf', 10)),
      updated_at = now()
  where id = p_user_id;
end;
$$;

create or replace function public.rpc_admin_user_set_active(
  p_session_token text,
  p_user_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s record;
  v_target public.app_users%rowtype;
  v_pin text;
begin
  select user_id, role into s
  from public.app_require_session(p_session_token);

  if s.user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if s.role <> 'admin' then
    raise exception 'Permiso denegado';
  end if;

  select * into v_target
  from public.app_users
  where id = p_user_id;

  if not found then
    raise exception 'Usuario no existe';
  end if;

  if coalesce(p_active, false) is true then
    select lpad(gs::text, 4, '0')
      into v_pin
    from generate_series(0, 9999) gs
    where public.app_verify_pin(lpad(gs::text, 4, '0'), v_target.pin_hash)
    limit 1;

    if v_pin is null then
      raise exception 'No se pudo validar el PIN del usuario. Resetee el PIN antes de activar.';
    end if;

    if public.app_pin_active_match_count(v_pin, p_user_id) > 0 then
      raise exception 'PIN duplicado: no se puede activar este usuario.';
    end if;
  end if;

  update public.app_users
  set active = coalesce(p_active, false),
      updated_at = now()
  where id = p_user_id;
end;
$$;

grant execute on function public.app_pin_active_match_count(text, uuid) to anon, authenticated;
grant execute on function public.rpc_pin_login(text) to anon, authenticated;
grant execute on function public.rpc_admin_user_create(text, text, text, text) to anon, authenticated;
grant execute on function public.rpc_admin_user_set_pin(text, uuid, text) to anon, authenticated;
grant execute on function public.rpc_admin_user_set_active(text, uuid, boolean) to anon, authenticated;
