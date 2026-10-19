-- Sales follow-up: anonymous capture, private recent receipts and admin reporting.
-- This module is additive and does not change sales, dispatch or inventory data.

begin;

create table if not exists public.sales_follow_up_reasons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null check (char_length(trim(label)) between 2 and 120),
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(id) on delete set null
);

create table if not exists public.sales_follow_up_events (
  id uuid primary key default gen_random_uuid(),
  receipt_token uuid not null default gen_random_uuid() unique,
  idempotency_key uuid not null unique,
  expediente text not null check (expediente ~ '^[0-9]{1,20}$'),
  outcome text not null check (outcome in ('no_purchase','partial_purchase')),
  reason_id uuid not null references public.sales_follow_up_reasons(id) on delete restrict,
  reason_label_snapshot text not null,
  comment text,
  dispatch_id uuid references public.dispatch_header(id) on delete set null,
  status text not null default 'active' check (status in ('active','voided')),
  source text not null default 'public_index' check (source in ('public_index','admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references public.app_users(id) on delete set null,
  void_reason text
);

create table if not exists public.sales_follow_up_audit (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.sales_follow_up_events(id) on delete restrict,
  action text not null check (action in ('create_admin','update','void','restore')),
  before_data jsonb,
  after_data jsonb,
  changed_by uuid not null references public.app_users(id) on delete restrict,
  changed_at timestamptz not null default now()
);

create index if not exists idx_sales_follow_up_events_created_at
  on public.sales_follow_up_events(created_at desc);
create index if not exists idx_sales_follow_up_events_expediente_created
  on public.sales_follow_up_events(expediente, created_at desc);
create index if not exists idx_sales_follow_up_events_outcome_status
  on public.sales_follow_up_events(outcome, status, created_at desc);
create index if not exists idx_sales_follow_up_events_reason
  on public.sales_follow_up_events(reason_id, created_at desc);

alter table public.sales_follow_up_reasons enable row level security;
alter table public.sales_follow_up_events enable row level security;
alter table public.sales_follow_up_audit enable row level security;

revoke all on table public.sales_follow_up_reasons from public, anon, authenticated;
revoke all on table public.sales_follow_up_events from public, anon, authenticated;
revoke all on table public.sales_follow_up_audit from public, anon, authenticated;

insert into public.sales_follow_up_reasons(code, label, sort_order)
values
  ('unavailable', 'Sin disponibilidad del medicamento', 10),
  ('high_price', 'Precio elevado', 20),
  ('no_money_now', 'No tiene dinero en este momento', 30),
  ('already_has', 'Ya tiene medicamento', 40),
  ('prefers_elsewhere', 'Prefiere comprar en otro lugar', 50),
  ('no_reason', 'No informa el motivo', 60),
  ('other', 'Otro', 70)
on conflict (code) do nothing;

create or replace function public.rpc_sales_follow_up_public_reasons()
returns table(reason_id uuid, code text, label text, sort_order integer)
language sql
security definer
set search_path = public, pg_temp
as $function$
  select r.id, r.code, r.label, r.sort_order
  from public.sales_follow_up_reasons r
  where r.active is true
  order by r.sort_order, r.label;
$function$;

create or replace function public.rpc_sales_follow_up_create(
  p_expediente text,
  p_outcome text,
  p_reason_id uuid,
  p_comment text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_expediente text;
  v_comment text;
  v_reason public.sales_follow_up_reasons%rowtype;
  v_event public.sales_follow_up_events%rowtype;
  v_duplicate boolean := false;
begin
  v_expediente := regexp_replace(coalesce(p_expediente, ''), '\D', '', 'g');
  v_comment := nullif(trim(coalesce(p_comment, '')), '');

  if p_idempotency_key is null then
    raise exception 'Identificador de solicitud requerido';
  end if;

  select * into v_event
  from public.sales_follow_up_events
  where idempotency_key = p_idempotency_key;

  if found then
    return jsonb_build_object(
      'receipt_token', v_event.receipt_token,
      'expediente', v_event.expediente,
      'outcome', v_event.outcome,
      'reason', v_event.reason_label_snapshot,
      'created_at', v_event.created_at,
      'duplicate', true
    );
  end if;

  if v_expediente !~ '^[0-9]{1,20}$' then
    raise exception 'Expediente requerido; use solamente numeros';
  end if;
  if p_outcome not in ('no_purchase','partial_purchase') then
    raise exception 'Resultado no valido';
  end if;
  if char_length(coalesce(v_comment, '')) > 500 then
    raise exception 'El comentario no puede exceder 500 caracteres';
  end if;

  select * into v_reason
  from public.sales_follow_up_reasons
  where id = p_reason_id and active is true;
  if not found then raise exception 'Motivo no disponible'; end if;
  if v_reason.code = 'other' and v_comment is null then
    raise exception 'Escriba un comentario para el motivo Otro';
  end if;

  -- Serialize same-patient submissions and absorb accidental repeat clicks.
  perform pg_advisory_xact_lock(hashtextextended('sales_follow_up:' || v_expediente, 0));

  select * into v_event
  from public.sales_follow_up_events
  where expediente = v_expediente
    and outcome = p_outcome
    and reason_id = p_reason_id
    and status = 'active'
    and created_at >= now() - interval '2 minutes'
  order by created_at desc
  limit 1;

  if found then
    v_duplicate := true;
  else
    if (select count(*) from public.sales_follow_up_events where created_at >= now() - interval '1 minute') >= 60 then
      raise exception 'Demasiados registros en este momento; espere un minuto';
    end if;
    if (select count(*) from public.sales_follow_up_events where expediente = v_expediente and created_at >= now() - interval '1 day') >= 10 then
      raise exception 'Se alcanzo el limite diario para este expediente';
    end if;

    insert into public.sales_follow_up_events(
      idempotency_key, expediente, outcome, reason_id,
      reason_label_snapshot, comment, source
    ) values (
      p_idempotency_key, v_expediente, p_outcome, v_reason.id,
      v_reason.label, v_comment, 'public_index'
    ) returning * into v_event;
  end if;

  return jsonb_build_object(
    'receipt_token', v_event.receipt_token,
    'expediente', v_event.expediente,
    'outcome', v_event.outcome,
    'reason', v_event.reason_label_snapshot,
    'created_at', v_event.created_at,
    'duplicate', v_duplicate
  );
end;
$function$;

create or replace function public.rpc_sales_follow_up_recent(p_receipts uuid[])
returns table(
  receipt_token uuid,
  expediente text,
  outcome text,
  reason text,
  comment text,
  status text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if coalesce(cardinality(p_receipts), 0) = 0 then return; end if;
  if cardinality(p_receipts) > 50 then raise exception 'Demasiados comprobantes solicitados'; end if;

  return query
  select e.receipt_token, e.expediente, e.outcome, e.reason_label_snapshot,
         e.comment, e.status, e.created_at
  from public.sales_follow_up_events e
  where e.receipt_token = any(p_receipts)
    and e.created_at >= now() - interval '7 days'
  order by e.created_at desc;
end;
$function$;

create or replace function public.rpc_sales_follow_up_admin_overview(
  p_session_token text,
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_role public.user_role;
  v_from timestamptz;
  v_to timestamptz;
  v_summary jsonb;
  v_reasons jsonb;
  v_trend jsonb;
  v_records jsonb;
  v_catalog jsonb;
begin
  select role into v_role from public.app_require_session(p_session_token);
  if v_role is distinct from 'admin' then raise exception 'Permiso denegado'; end if;
  if p_start_date is not null and p_end_date is not null and p_end_date < p_start_date then
    raise exception 'Rango de fechas no valido';
  end if;

  v_from := case when p_start_date is null then null else p_start_date::timestamp at time zone 'America/El_Salvador' end;
  v_to := case when p_end_date is null then null else (p_end_date + 1)::timestamp at time zone 'America/El_Salvador' end;

  select jsonb_build_object(
    'records', count(*),
    'unique_patients', count(distinct expediente),
    'no_purchase', count(*) filter (where outcome = 'no_purchase'),
    'partial_purchase', count(*) filter (where outcome = 'partial_purchase')
  ) into v_summary
  from public.sales_follow_up_events
  where status = 'active'
    and (v_from is null or created_at >= v_from)
    and (v_to is null or created_at < v_to);

  with counts as (
    select reason_label_snapshot as reason, count(*)::integer as qty
    from public.sales_follow_up_events
    where status = 'active'
      and (v_from is null or created_at >= v_from)
      and (v_to is null or created_at < v_to)
    group by reason_label_snapshot
  ), totals as (select coalesce(sum(qty), 0)::numeric as total from counts)
  select coalesce(jsonb_agg(jsonb_build_object(
    'reason', c.reason,
    'qty', c.qty,
    'pct', case when t.total > 0 then round(c.qty * 100.0 / t.total, 2) else 0 end
  ) order by c.qty desc, c.reason), '[]'::jsonb)
  into v_reasons from counts c cross join totals t;

  with days as (
    select (created_at at time zone 'America/El_Salvador')::date as day,
           count(*)::integer as records,
           count(distinct expediente)::integer as patients
    from public.sales_follow_up_events
    where status = 'active'
      and (v_from is null or created_at >= v_from)
      and (v_to is null or created_at < v_to)
    group by 1
  )
  select coalesce(jsonb_agg(to_jsonb(days) order by day), '[]'::jsonb)
  into v_trend from days;

  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb)
  into v_records
  from (
    select jsonb_build_object(
      'event_id', e.id,
      'expediente', e.expediente,
      'outcome', e.outcome,
      'reason_id', e.reason_id,
      'reason', e.reason_label_snapshot,
      'comment', e.comment,
      'status', e.status,
      'source', e.source,
      'created_at', e.created_at,
      'dispatch_id', e.dispatch_id,
      'delivery_no', h.delivery_no,
      'void_reason', e.void_reason
    ) as row_data, e.created_at
    from public.sales_follow_up_events e
    left join public.dispatch_header h on h.id = e.dispatch_id
    where (v_from is null or e.created_at >= v_from)
      and (v_to is null or e.created_at < v_to)
    order by e.created_at desc
    limit 500
  ) listed;

  select coalesce(jsonb_agg(jsonb_build_object(
    'reason_id', id, 'code', code, 'label', label,
    'active', active, 'sort_order', sort_order
  ) order by sort_order, label), '[]'::jsonb)
  into v_catalog from public.sales_follow_up_reasons;

  return jsonb_build_object(
    'summary', coalesce(v_summary, '{}'::jsonb),
    'reasons', coalesce(v_reasons, '[]'::jsonb),
    'trend', coalesce(v_trend, '[]'::jsonb),
    'records', coalesce(v_records, '[]'::jsonb),
    'catalog', coalesce(v_catalog, '[]'::jsonb)
  );
end;
$function$;

create or replace function public.rpc_sales_follow_up_admin_save(
  p_session_token text,
  p_event_id uuid,
  p_expediente text,
  p_outcome text,
  p_reason_id uuid,
  p_comment text,
  p_dispatch_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_expediente text;
  v_comment text;
  v_reason public.sales_follow_up_reasons%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_event_id uuid;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role is distinct from 'admin' then raise exception 'Permiso denegado'; end if;

  v_expediente := regexp_replace(coalesce(p_expediente, ''), '\D', '', 'g');
  v_comment := nullif(trim(coalesce(p_comment, '')), '');
  if v_expediente !~ '^[0-9]{1,20}$' then raise exception 'Expediente no valido'; end if;
  if p_outcome not in ('no_purchase','partial_purchase') then raise exception 'Resultado no valido'; end if;
  if char_length(coalesce(v_comment, '')) > 500 then raise exception 'Comentario demasiado largo'; end if;

  select * into v_reason from public.sales_follow_up_reasons where id = p_reason_id;
  if not found then raise exception 'Motivo no existe'; end if;
  if v_reason.active is false and (
    p_event_id is null
    or not exists(select 1 from public.sales_follow_up_events where id = p_event_id and reason_id = p_reason_id)
  ) then
    raise exception 'Motivo inactivo';
  end if;
  if v_reason.code = 'other' and v_comment is null then raise exception 'Comentario requerido para Otro'; end if;
  if p_dispatch_id is not null and not exists(select 1 from public.dispatch_header where id = p_dispatch_id) then
    raise exception 'Despacho no existe';
  end if;

  if p_event_id is null then
    insert into public.sales_follow_up_events(
      idempotency_key, expediente, outcome, reason_id, reason_label_snapshot,
      comment, dispatch_id, source, updated_by
    ) values (
      gen_random_uuid(), v_expediente, p_outcome, v_reason.id, v_reason.label,
      v_comment, p_dispatch_id, 'admin', v_user_id
    ) returning id into v_event_id;
    select to_jsonb(e) into v_after from public.sales_follow_up_events e where e.id = v_event_id;
    insert into public.sales_follow_up_audit(event_id, action, after_data, changed_by)
    values(v_event_id, 'create_admin', v_after, v_user_id);
  else
    select to_jsonb(e) into v_before from public.sales_follow_up_events e where e.id = p_event_id for update;
    if v_before is null then raise exception 'Registro no existe'; end if;
    update public.sales_follow_up_events
    set expediente = v_expediente,
        outcome = p_outcome,
        reason_id = v_reason.id,
        reason_label_snapshot = v_reason.label,
        comment = v_comment,
        dispatch_id = p_dispatch_id,
        updated_at = now(),
        updated_by = v_user_id
    where id = p_event_id
    returning id into v_event_id;
    select to_jsonb(e) into v_after from public.sales_follow_up_events e where e.id = v_event_id;
    insert into public.sales_follow_up_audit(event_id, action, before_data, after_data, changed_by)
    values(v_event_id, 'update', v_before, v_after, v_user_id);
  end if;
  return v_event_id;
end;
$function$;

create or replace function public.rpc_sales_follow_up_admin_set_status(
  p_session_token text,
  p_event_id uuid,
  p_status text,
  p_reason text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_before jsonb;
  v_after jsonb;
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role is distinct from 'admin' then raise exception 'Permiso denegado'; end if;
  if p_status not in ('active','voided') then raise exception 'Estado no valido'; end if;
  if p_status = 'voided' and nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Indique el motivo de anulacion';
  end if;

  select to_jsonb(e) into v_before from public.sales_follow_up_events e where e.id = p_event_id for update;
  if v_before is null then raise exception 'Registro no existe'; end if;

  update public.sales_follow_up_events
  set status = p_status,
      voided_at = case when p_status = 'voided' then now() else null end,
      voided_by = case when p_status = 'voided' then v_user_id else null end,
      void_reason = case when p_status = 'voided' then trim(p_reason) else null end,
      updated_at = now(),
      updated_by = v_user_id
  where id = p_event_id;

  select to_jsonb(e) into v_after from public.sales_follow_up_events e where e.id = p_event_id;
  insert into public.sales_follow_up_audit(event_id, action, before_data, after_data, changed_by)
  values(p_event_id, case when p_status = 'voided' then 'void' else 'restore' end, v_before, v_after, v_user_id);
  return true;
end;
$function$;

create or replace function public.rpc_sales_follow_up_admin_save_reason(
  p_session_token text,
  p_reason_id uuid,
  p_label text,
  p_sort_order integer,
  p_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_role public.user_role;
  v_id uuid;
  v_label text := trim(coalesce(p_label, ''));
begin
  select user_id, role into v_user_id, v_role from public.app_require_session(p_session_token);
  if v_role is distinct from 'admin' then raise exception 'Permiso denegado'; end if;
  if char_length(v_label) not between 2 and 120 then raise exception 'Nombre de motivo no valido'; end if;

  if p_reason_id is null then
    insert into public.sales_follow_up_reasons(code, label, active, sort_order, updated_by)
    values('custom_' || replace(gen_random_uuid()::text, '-', ''), v_label, coalesce(p_active, true), coalesce(p_sort_order, 100), v_user_id)
    returning id into v_id;
  else
    update public.sales_follow_up_reasons
    set label = v_label,
        active = coalesce(p_active, active),
        sort_order = coalesce(p_sort_order, sort_order),
        updated_at = now(),
        updated_by = v_user_id
    where id = p_reason_id
    returning id into v_id;
    if v_id is null then raise exception 'Motivo no existe'; end if;
  end if;
  return v_id;
end;
$function$;

revoke all on function public.rpc_sales_follow_up_public_reasons() from public;
revoke all on function public.rpc_sales_follow_up_create(text,text,uuid,text,uuid) from public;
revoke all on function public.rpc_sales_follow_up_recent(uuid[]) from public;
revoke all on function public.rpc_sales_follow_up_admin_overview(text,date,date) from public;
revoke all on function public.rpc_sales_follow_up_admin_save(text,uuid,text,text,uuid,text,uuid) from public;
revoke all on function public.rpc_sales_follow_up_admin_set_status(text,uuid,text,text) from public;
revoke all on function public.rpc_sales_follow_up_admin_save_reason(text,uuid,text,integer,boolean) from public;

grant execute on function public.rpc_sales_follow_up_public_reasons() to anon, authenticated;
grant execute on function public.rpc_sales_follow_up_create(text,text,uuid,text,uuid) to anon, authenticated;
grant execute on function public.rpc_sales_follow_up_recent(uuid[]) to anon, authenticated;
grant execute on function public.rpc_sales_follow_up_admin_overview(text,date,date) to anon, authenticated;
grant execute on function public.rpc_sales_follow_up_admin_save(text,uuid,text,text,uuid,text,uuid) to anon, authenticated;
grant execute on function public.rpc_sales_follow_up_admin_set_status(text,uuid,text,text) to anon, authenticated;
grant execute on function public.rpc_sales_follow_up_admin_save_reason(text,uuid,text,integer,boolean) to anon, authenticated;

commit;
