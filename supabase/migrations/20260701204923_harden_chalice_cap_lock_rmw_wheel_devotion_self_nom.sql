-- Agent-audit hardening bundle (all transformed in place; each replace aborts if its target
-- isn't found so it can never silently no-op):
--   #1 grove_chalice: clamp the client-supplied commit `delta` to +/-500. A real Kings-Cup
--      game yields tens-to-low-hundreds; this blocks the unlimited-point-mint exploit
--      (an anon caller could previously set any spirit to any value via a large delta).
--   #3 add SELECT ... FOR UPDATE to the read-modify-write RPCs (grove_action, grove_chalice,
--      grove_withdraw, grove_set_chibi, grove_clear_rites) so concurrent calls serialise on the
--      single grove_state row instead of clobbering each other (grove_propose/grove_vote already
--      had it).
--   #4 grove_wheel: track the running Test-of-Devotion tally server-side (spins +1, total +=
--      base outcome pts) so it persists in hosted play instead of living only on the client.
--   self-nomination: allowed for deeds (the deed points apply to you, but the nominator bounty
--      is skipped because nominator==target) and oaths (self by design); blocked for
--      title / badge / offer.
DO $mig$
declare src text; n text; fns text[] := array['grove_action','grove_chalice','grove_withdraw','grove_set_chibi','grove_clear_rites']; f text;
begin
  src := pg_get_functiondef('public.grove_chalice(jsonb)'::regprocedure);
  n := replace(src, $q$delta := coalesce((cm->>'delta')::int, 0);$q$, $q$delta := greatest(-500, least(500, coalesce((cm->>'delta')::int, 0)));$q$);
  if n=src then raise exception 'chalice delta line not found'; end if; execute n;

  foreach f in array fns loop
    src := pg_get_functiondef(('public.'||f||case when f='grove_action' or f='grove_chalice' then '(jsonb)' when f='grove_withdraw' then '(text,text)' when f='grove_set_chibi' then '(text,jsonb)' else '(text)' end)::regprocedure);
    n := replace(src, 'select data into d from public.grove_state where id = 1;', 'select data into d from public.grove_state where id = 1 for update;');
    if n=src then raise exception 'lock target not found in %', f; end if; execute n;
  end loop;

  src := pg_get_functiondef('public.grove_wheel(text)'::regprocedure);
  n := replace(src,
$q$  d := jsonb_set(d, '{members}', members);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return o;$q$,
$q$  members := jsonb_set(members, array[midx::text,'devotion'], jsonb_build_object(
      'spins', coalesce((members->midx#>>'{devotion,spins}')::int,0)+1,
      'total', coalesce((members->midx#>>'{devotion,total}')::int,0) + case when o ? 'pts' then (o->>'pts')::int else 0 end), true);
  d := jsonb_set(d, '{members}', members);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return o;$q$);
  if n=src then raise exception 'grove_wheel tail not found'; end if; execute n;

  src := pg_get_functiondef('public.grove_propose(jsonb)'::regprocedure);
  n := replace(src,
$q$  if kind <> 'newdeed' and not exists (select 1 from jsonb_array_elements(members) mm where mm->>'name' = target) then
    raise exception 'unknown target';
  end if;$q$,
$q$  if kind <> 'newdeed' and not exists (select 1 from jsonb_array_elements(members) mm where mm->>'name' = target) then
    raise exception 'unknown target';
  end if;
  if nominator = target and kind in ('title','badge','offer') then
    raise exception 'You cannot nominate yourself for a title, badge or offering.';
  end if;$q$);
  if n=src then raise exception 'propose target-check block not found'; end if; execute n;
end $mig$;
