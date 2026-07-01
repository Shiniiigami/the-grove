-- The client lets a spirit add a log to the fire every 3h (the Stoke button, its cooldown
-- readout, and the offline replica in applyAction all use 3*3600), but grove_action still
-- enforced 6h (21600s). A stoke made between 3h and 6h therefore passed on the client
-- (log looked consumed, fire looked stoked) but was silently rejected server-side and
-- reverted on the next refresh — the log "didn't count". Align the server to 3h (10800s).
DO $mig$
declare src text; newsrc text;
begin
  src := pg_get_functiondef('public.grove_action(jsonb)'::regprocedure);
  newsrc := replace(src,
    $q$coalesce((members->midx->>'lastStoke')::double precision,0) + 21600 <= nowe$q$,
    $q$coalesce((members->midx->>'lastStoke')::double precision,0) + 10800 <= nowe$q$);
  if newsrc = src then raise exception 'stoke cooldown pattern not found — aborting'; end if;
  execute newsrc;
end $mig$;
