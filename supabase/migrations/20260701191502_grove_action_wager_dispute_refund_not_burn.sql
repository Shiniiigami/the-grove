-- A matched wager left in dispute past the 1h window used to become 'forfeit', which
-- destroyed BOTH stakes (a silent points sink — confirmed by conservation testing:
-- total dropped by 2×amount). The parallel group-wager path already 'void's and refunds.
-- Make wagers consistent: refund both and settle as a tie.
-- Transformed in place (string replace over the live definition) to avoid retyping the
-- whole ~400-line function; it raises if the target line isn't found, so it can never
-- silently no-op.
DO $mig$
declare src text; newsrc text;
begin
  src := pg_get_functiondef('public.grove_action(jsonb)'::regprocedure);
  newsrc := replace(src,
    $q$wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('forfeit'::text)), array[widx::text,'winner'], to_jsonb('forfeit'::text));$q$,
    $q$amt := coalesce((wagers->widx->>'amount')::int,0);
      members := grove_credit(members, wagers->widx->>'proposer', amt);
      members := grove_credit(members, wagers->widx->>'taker', amt);
      wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('settled'::text)), array[widx::text,'winner'], to_jsonb('tie'::text));$q$);
  if newsrc = src then raise exception 'forfeit pattern not found — aborting'; end if;
  execute newsrc;
end $mig$;
