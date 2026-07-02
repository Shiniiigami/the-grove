-- Agent-audit round 2 fixes:
--  #3 grove_set_chibi: reject a corrupt/oversized chibi (null, non-object, or >4000 chars) so
--     malformed sprite data can't be stored and later crash the grove render for all viewers.
--     (Wearable point-gating stays client-side by design — cosmetic only, no economy impact.)
--  Cheat radar 150 -> 145: a wheel buff (winMult>1) on a challenge of reward >= 145 now trips
--     the -100 penalty (was >= 150, so a reward-149 trial slipped under and paid full x mult).
--     Buffs on rewards <= 144 still pay the intended blessing. Reward cap itself stays 150.
CREATE OR REPLACE FUNCTION public.grove_set_chibi(p_name text, p_chibi jsonb)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare d jsonb; members jsonb; mem jsonb; i int; midx int := -1;
begin
  if p_chibi is null or jsonb_typeof(p_chibi) <> 'object' or length(p_chibi::text) > 4000 then
    raise exception 'invalid chibi';
  end if;
  select data into d from public.grove_state where id = 1 for update;
  if d is null then raise exception 'grove not seeded'; end if;
  members := coalesce(d->'members','[]'::jsonb);
  for i in 0 .. jsonb_array_length(members) - 1 loop
    if members->i->>'name' = p_name then midx := i; exit; end if;
  end loop;
  if midx < 0 then raise exception 'no such member'; end if;
  mem := members->midx;
  mem := jsonb_set(mem, '{sprite}', jsonb_build_object('chibi', p_chibi));
  members := jsonb_set(members, array[midx::text], mem);
  d := jsonb_set(d, '{members}', members);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return true;
end; $function$;

DO $mig$
declare src text; n text;
begin
  src := pg_get_functiondef('public.grove_action(jsonb)'::regprocedure);
  n := replace(src, 'mult > 1 and rew >= 150', 'mult > 1 and rew >= 145');
  n := replace(n,   'coalesce(rew,0) >= 150',  'coalesce(rew,0) >= 145');
  if n=src then raise exception 'cheat threshold not found'; end if;
  execute n;
end $mig$;
