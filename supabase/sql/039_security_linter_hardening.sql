-- Security hardening for Supabase database linter warnings.
--
-- Scope:
-- 1) Pin search_path on functions reported as mutable by the linter.
-- 2) Revoke direct API execution from internal helper/trigger functions.
--
-- This migration does not delete data, alter table contents, or change user-facing RPCs.
-- Public/app RPCs remain callable from the static frontend and continue enforcing
-- authorization through PIN/session checks inside each function.

-- ------------------------------------------------------------
-- 1. Fix function_search_path_mutable warnings
-- ------------------------------------------------------------
--
-- Some hosted Postgres environments do not accept "ALTER FUNCTION IF EXISTS".
-- Use to_regprocedure so this script is safe even when an older function name
-- no longer exists in the database.

do $$
declare
  fn regprocedure;
  search_path_functions text[] := array[
    'public.tg_set_updated_at()',
    'public.rpc_dispatch_get(text, uuid)',
    'public.pharma_catalog_set_updated_at()',
    'public.pharma_touch_updated_at()',
    'public.parse_inventory_lot_expiry(text)'
  ];
  fn_signature text;
begin
  foreach fn_signature in array search_path_functions loop
    fn := to_regprocedure(fn_signature);

    if fn is not null then
      execute format('alter function %s set search_path = public, pg_temp', fn);
    end if;
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- 2. Remove direct external execution from internal helpers
-- ------------------------------------------------------------

do $$
declare
  fn regprocedure;
  internal_functions text[] := array[
    'public.app_pharma_match(text)',
    'public.app_pin_active_match_count(text, uuid)',
    'public.app_require_session(text)',
    'public.dispatch_raise_if_stock_insufficient(text, numeric, uuid)',
    'public.dispatch_stock_check(text, numeric, uuid)',
    'public.inventory_apply_lot_fifo(uuid)',
    'public.inventory_count_session_payload(uuid)',
    'public.inventory_insert_dispatch_movement(uuid, uuid, text, numeric, text, text, text, uuid, text, jsonb)',
    'public.inventory_lot_fifo_trigger()',
    'public.inventory_purchase_item_movement()',
    'public.parse_inventory_lot_expiry(text)',
    'public.refresh_inventory_lots_from_snapshots()',
    'public.trg_set_product_name_from_pharma()'
  ];
  fn_signature text;
begin
  foreach fn_signature in array internal_functions loop
    fn := to_regprocedure(fn_signature);

    if fn is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', fn);
    end if;
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- 3. Explicitly keep app entrypoints callable by the frontend
-- ------------------------------------------------------------
--
-- Intentional RPC entrypoints stay exposed because this project is a static web app
-- that calls Supabase RPCs with the anon key. Authorization is enforced inside the
-- RPCs using session tokens, PIN roles, and admin checks.
--
-- Do not blanket revoke all SECURITY DEFINER functions without first confirming
-- every frontend call path, or operational modules can stop working.
