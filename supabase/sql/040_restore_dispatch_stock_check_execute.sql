-- Restore frontend permission required by dispatch.html.
--
-- dispatch_stock_check is intentionally called by the static dispatch screen to
-- validate available stock before adding an item to the cart. It still only reads
-- stock status and does not mutate inventory.

grant execute on function public.dispatch_stock_check(text, numeric, uuid) to anon, authenticated;
