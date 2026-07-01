-- Widen the wheel's ×2/×3 "blessing" (winMult) beyond challenge approvals + Keeper awards
-- to also bless the next: community deed rite (grove_vote), Devotion wheel spin (grove_wheel),
-- Trial of the Chalice total (grove_chalice), and normal (non-group) wager win (grove_action,
-- both concede & dispute-vote). Positive gains only; the buff is consumed on use.
--   * deed: multiply the applied points; the nominator reward stays on the BASE scale.
--   * wheel/chalice: multiply the positive outcome / game total.
--   * wager (Option A): multiply the NET winnings — winner gets stake back + M×stake
--     (amt*(1+M); with no buff M=1 → the usual 2×stake). Group wagers are untouched.
-- Transformed in place; each replace raises if its target isn't found.
DO $mig$
declare src text; n text;
begin
  src := pg_get_functiondef('public.grove_vote(text,text)'::regprocedure);
  n := replace(src,
$q$          pts := greatest(-200, least(200, coalesce((r->>'points')::int, 0)));
          cur := greatest(0, coalesce((mem->>'points')::int, 0) + pts);
          sea := greatest(0, coalesce((mem->>'season')::int, 0) + pts);
          mem := jsonb_set(mem, '{points}', to_jsonb(cur));
          mem := jsonb_set(mem, '{season}', to_jsonb(sea));
          mem := jsonb_set(mem, '{history}',
                  coalesce(mem->'history','[]'::jsonb)
                  || jsonb_build_array(jsonb_build_object('l', r->>'label', 'd', pts)));
          -- the nominator is rewarded on the same scale that sets the threshold
          rew := case when abs(pts)<=20 then 5 when abs(pts)<=49 then 10 when abs(pts)<=69 then 15
                      when abs(pts)<=100 then 20 when abs(pts)<=150 then 25 else 30 end;$q$,
$q$          pts := greatest(-200, least(200, coalesce((r->>'points')::int, 0)));
          rew := case when abs(pts)<=20 then 5 when abs(pts)<=49 then 10 when abs(pts)<=69 then 15
                      when abs(pts)<=100 then 20 when abs(pts)<=150 then 25 else 30 end;
          if pts > 0 and coalesce((mem->>'winMult')::int,1) > 1 then
            pts := pts * coalesce((mem->>'winMult')::int,1);
            mem := mem - 'winMult';
          end if;
          cur := greatest(0, coalesce((mem->>'points')::int, 0) + pts);
          sea := greatest(0, coalesce((mem->>'season')::int, 0) + pts);
          mem := jsonb_set(mem, '{points}', to_jsonb(cur));
          mem := jsonb_set(mem, '{season}', to_jsonb(sea));
          mem := jsonb_set(mem, '{history}',
                  coalesce(mem->'history','[]'::jsonb)
                  || jsonb_build_array(jsonb_build_object('l', r->>'label', 'd', pts)));$q$);
  if n=src then raise exception 'grove_vote deed block not found'; end if;
  execute n;

  src := pg_get_functiondef('public.grove_wheel(text)'::regprocedure);
  n := replace(src,
$q$    spv := coalesce((o->>'pts')::int,0);
    members := jsonb_set(members, array[midx::text], grove_adj(members->midx, spv));$q$,
$q$    spv := coalesce((o->>'pts')::int,0);
    if spv > 0 and coalesce((members->midx->>'winMult')::int,1) > 1 then
      spv := spv * coalesce((members->midx->>'winMult')::int,1);
      members := jsonb_set(members, array[midx::text], (members->midx) - 'winMult');
    end if;
    members := jsonb_set(members, array[midx::text], grove_adj(members->midx, spv));$q$);
  if n=src then raise exception 'grove_wheel spv block not found'; end if;
  execute n;

  src := pg_get_functiondef('public.grove_chalice(jsonb)'::regprocedure);
  n := replace(src,
$q$          m := members->idx;
          m := jsonb_set(m, '{points}', to_jsonb(greatest(0, coalesce((m->>'points')::int,0) + delta)));$q$,
$q$          m := members->idx;
          if delta > 0 and coalesce((m->>'winMult')::int,1) > 1 then
            delta := delta * coalesce((m->>'winMult')::int,1);
            m := m - 'winMult';
          end if;
          m := jsonb_set(m, '{points}', to_jsonb(greatest(0, coalesce((m->>'points')::int,0) + delta)));$q$);
  if n=src then raise exception 'grove_chalice delta block not found'; end if;
  execute n;

  src := pg_get_functiondef('public.grove_action(jsonb)'::regprocedure);
  n := replace(src,
    $q$grove_adj(members->midx, 2*amt)$q$,
    $q$grove_adj((members->midx) - 'winMult', amt * (1 + coalesce((members->midx->>'winMult')::int,1)))$q$);
  if n=src then raise exception 'grove_action 2*amt not found'; end if;
  execute n;
end $mig$;
