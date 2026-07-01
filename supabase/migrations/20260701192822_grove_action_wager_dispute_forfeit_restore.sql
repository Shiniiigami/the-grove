-- Reverts 20260701191502: by request, an unresolved dispute FORFEITS the pot (both
-- stakes lost) rather than refunding. Restores the original burn semantics.
DO $mig$
declare src text; newsrc text;
begin
  src := pg_get_functiondef('public.grove_action(jsonb)'::regprocedure);
  newsrc := replace(src,
    $q$amt := coalesce((wagers->widx->>'amount')::int,0);
      members := grove_credit(members, wagers->widx->>'proposer', amt);
      members := grove_credit(members, wagers->widx->>'taker', amt);
      wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('settled'::text)), array[widx::text,'winner'], to_jsonb('tie'::text));$q$,
    $q$wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('forfeit'::text)), array[widx::text,'winner'], to_jsonb('forfeit'::text));$q$);
  if newsrc = src then raise exception 'refund block not found — aborting'; end if;
  execute newsrc;
end $mig$;
