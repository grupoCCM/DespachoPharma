do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_COUNT_SESSION_CLOSE';
exception when duplicate_object then null;
end $$;

do $$
begin
  alter type public.audit_event_type add value if not exists 'INVENTORY_COUNT_SESSION_CANCEL';
exception when duplicate_object then null;
end $$;

create or replace function public.rpc_inventory_count_session_finish(
  p_session_token text,
  p_session_id uuid,
  p_action text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_status text;
  v_action text := lower(trim(coalesce(p_action, '')));
  v_event public.audit_event_type;
begin
  select user_id, role into v_user_id, v_role
  from public.app_require_session(p_session_token);

  if v_user_id is null then
    raise exception 'Sesion invalida o expirada';
  end if;

  if v_role <> 'admin' then
    raise exception 'Solo admin puede cerrar o cancelar conteos';
  end if;

  if v_action not in ('close','cancel') then
    raise exception 'Accion invalida';
  end if;

  select status into v_status
  from public.inventory_count_sessions
  where id = p_session_id
  for update;

  if v_status is null then
    raise exception 'Sesion de conteo no encontrada';
  end if;

  if v_status <> 'open' then
    raise exception 'La sesion ya no esta abierta';
  end if;

  update public.inventory_count_sessions
     set status = case when v_action = 'close' then 'closed' else 'cancelled' end,
         closed_by = v_user_id,
         closed_at = now(),
         note = nullif(trim(coalesce(p_note, note, '')), '')
   where id = p_session_id;

  v_event := case
    when v_action = 'close' then 'INVENTORY_COUNT_SESSION_CLOSE'::public.audit_event_type
    else 'INVENTORY_COUNT_SESSION_CANCEL'::public.audit_event_type
  end;

  insert into public.audit_log(event_type, user_id, metadata)
  values (
    v_event,
    v_user_id,
    jsonb_build_object('session_id', p_session_id, 'action', v_action, 'note', p_note)
  );

  return public.inventory_count_session_payload(p_session_id);
end;
$$;

grant execute on function public.rpc_inventory_count_session_finish(text, uuid, text, text) to anon, authenticated;
