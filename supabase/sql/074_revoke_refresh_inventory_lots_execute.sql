-- Emergency hardening: this maintenance function writes lot state and must not
-- be callable with the public anon key or regular browser sessions.
revoke execute on function public.refresh_inventory_lots_from_snapshots() from anon, authenticated;
