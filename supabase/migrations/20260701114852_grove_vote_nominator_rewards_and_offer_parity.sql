-- Bring grove_vote into parity with the client's applyRiteEffect (index.html):
--   * reward the nominator of a passing title (+25), badge (+20) and deed (+5..+30
--     scaled by the deed's size) - mirrors "reward nominators of passing rites"
--   * an offering now robes the offered for 3h (was 4h) and pays its nominator +50
--     (was +25); the offered still receive +150 "Offered to the Eye"
-- New deeds and oaths carry no nominator bounty (the oath's +100 Rite of Passage is
-- reconciled client-side by the Keeper, unchanged here).
CREATE OR REPLACE FUNCTION public.grove_vote(p_id text, p_voter text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d jsonb; rites jsonb; r jsonb; appr jsonb; members jsonb; mem jsonb;
  i int; idx int := -1; midx int := -1;
  thr int; kind text; target text; pts int; lbl text;
  cur int; sea int; chibi jsonb;
  nowe double precision; cnt int; jj int;
  nomname text; nidx int; nommem jsonb; ncur int; nsea int;
  rew int := 0; nlabel text := '';
begin
  select data into d from public.grove_state where id = 1;
  if d is null then raise exception 'grove not seeded'; end if;

  rites := coalesce(d->'rites','[]'::jsonb);

  for i in 0 .. jsonb_array_length(rites) - 1 loop
    if rites->i->>'id' = p_id then idx := i; exit; end if;
  end loop;
  if idx < 0 then raise exception 'no such rite'; end if;

  r := rites->idx;
  if coalesce((r->>'applied')::boolean, false) then return r; end if;

  -- the voter must be a real spirit: stops anyone conjuring fake approvers to cross the threshold
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'members','[]'::jsonb)) mm
                 where mm->>'name' = p_voter) then
    return r;
  end if;

  -- distinct-voter guard
  appr := coalesce(r->'approvers','[]'::jsonb);
  if appr @> to_jsonb(p_voter) then return r; end if;
  appr := appr || to_jsonb(p_voter);
  r := jsonb_set(r, '{approvers}', appr);

  thr := coalesce((r->>'threshold')::int, 5);

  if jsonb_array_length(appr) >= thr then
    kind := r->>'kind';

    if kind = 'newdeed' then
      pts := greatest(-50, least(100, coalesce((r->>'points')::int, 0)));
      lbl := r->>'label';
      d := jsonb_set(d, '{deeds}',
            coalesce(d->'deeds','[]'::jsonb)
            || jsonb_build_array(jsonb_build_array(to_jsonb(lbl), to_jsonb(pts))));

    else
      target  := r->>'target';
      members := coalesce(d->'members','[]'::jsonb);
      for i in 0 .. jsonb_array_length(members) - 1 loop
        if members->i->>'name' = target then midx := i; exit; end if;
      end loop;

      if midx >= 0 then
        mem := members->midx;

        if kind = 'title' then
          mem := jsonb_set(mem, '{epithet}', to_jsonb(r->>'label'));
          rew := 25; nlabel := 'Named a title';

        elsif kind = 'badge' then
          if not coalesce(mem->'badges','[]'::jsonb) @> to_jsonb(r->>'label') then
            mem := jsonb_set(mem, '{badges}',
                    coalesce(mem->'badges','[]'::jsonb) || to_jsonb(r->>'label'));
          end if;
          rew := 20; nlabel := 'Named a badge';

        elsif kind = 'deed' then
          -- clamp on apply too (defence in depth against any pre-existing unclamped rite)
          pts := greatest(-200, least(200, coalesce((r->>'points')::int, 0)));
          cur := greatest(0, coalesce((mem->>'points')::int, 0) + pts);
          sea := greatest(0, coalesce((mem->>'season')::int, 0) + pts);
          mem := jsonb_set(mem, '{points}', to_jsonb(cur));
          mem := jsonb_set(mem, '{season}', to_jsonb(sea));
          mem := jsonb_set(mem, '{history}',
                  coalesce(mem->'history','[]'::jsonb)
                  || jsonb_build_array(jsonb_build_object('l', r->>'label', 'd', pts)));
          -- the nominator is rewarded on the same scale that sets the threshold
          rew := case when abs(pts)<=20 then 5 when abs(pts)<=49 then 10 when abs(pts)<=69 then 15
                      when abs(pts)<=100 then 20 when abs(pts)<=150 then 25 else 30 end;
          nlabel := 'Named a deed';

        elsif kind = 'offer' then
          nowe := extract(epoch from now());
          cnt := 0;
          for jj in 0 .. jsonb_array_length(members) - 1 loop
            if coalesce((members->jj->>'offered')::double precision, 0) > nowe
               and (members->jj->>'name') <> target then cnt := cnt + 1; end if;
          end loop;
          if cnt < 3 then
            if coalesce((mem->>'offered')::double precision, 0) <= nowe then
              cur := greatest(0, coalesce((mem->>'points')::int, 0) + 150);
              sea := greatest(0, coalesce((mem->>'season')::int, 0) + 150);
              mem := jsonb_set(mem, '{points}', to_jsonb(cur));
              mem := jsonb_set(mem, '{season}', to_jsonb(sea));
              mem := jsonb_set(mem, '{history}',
                      coalesce(mem->'history','[]'::jsonb)
                      || jsonb_build_array(jsonb_build_object('l','Offered to the Eye','d',150)));
              nomname := r->>'nominator';
              if nomname is not null and nomname <> '' and nomname <> target then
                nidx := -1;
                for jj in 0 .. jsonb_array_length(members) - 1 loop
                  if members->jj->>'name' = nomname then nidx := jj; exit; end if;
                end loop;
                if nidx >= 0 then
                  nommem := members->nidx;
                  ncur := greatest(0, coalesce((nommem->>'points')::int, 0) + 50);
                  nsea := greatest(0, coalesce((nommem->>'season')::int, 0) + 50);
                  nommem := jsonb_set(nommem, '{points}', to_jsonb(ncur));
                  nommem := jsonb_set(nommem, '{season}', to_jsonb(nsea));
                  nommem := jsonb_set(nommem, '{history}',
                          coalesce(nommem->'history','[]'::jsonb)
                          || jsonb_build_array(jsonb_build_object('l','Named the offering','d',50)));
                  members := jsonb_set(members, array[nidx::text], nommem);
                end if;
              end if;
            end if;
            if not coalesce(mem->'unlocks','[]'::jsonb) @> to_jsonb('robes'::text) then
              mem := jsonb_set(mem, '{unlocks}',
                      coalesce(mem->'unlocks','[]'::jsonb) || to_jsonb('robes'::text));
            end if;
            if not coalesce(mem->'badges','[]'::jsonb) @> to_jsonb('Of the Eye'::text) then
              mem := jsonb_set(mem, '{badges}',
                      coalesce(mem->'badges','[]'::jsonb) || to_jsonb('Of the Eye'::text));
            end if;
            chibi := coalesce(mem->'sprite'->'chibi', '{}'::jsonb);
            chibi := jsonb_set(chibi, '{top_style}', to_jsonb('robes'::text), true);
            mem := jsonb_set(mem, '{sprite}', jsonb_build_object('chibi', chibi), true);
            mem := jsonb_set(mem, '{offered}', to_jsonb(nowe + 10800));
          end if;

        elsif kind = 'oath' then
          mem := jsonb_set(mem, '{oath}', 'true'::jsonb);
          if not coalesce(mem->'badges','[]'::jsonb) @> to_jsonb('Initiated'::text) then
            mem := jsonb_set(mem, '{badges}',
                    coalesce(mem->'badges','[]'::jsonb) || to_jsonb('Initiated'::text));
          end if;
        end if;

        -- reward the nominator of a passing title / badge / deed (offerings pay their
        -- nominator inline above; oaths and new deeds carry no nominator bounty)
        if rew > 0 then
          nomname := r->>'nominator';
          if nomname is not null and nomname <> '' and nomname <> target then
            nidx := -1;
            for jj in 0 .. jsonb_array_length(members) - 1 loop
              if members->jj->>'name' = nomname then nidx := jj; exit; end if;
            end loop;
            if nidx >= 0 then
              nommem := members->nidx;
              ncur := greatest(0, coalesce((nommem->>'points')::int, 0) + rew);
              nsea := greatest(0, coalesce((nommem->>'season')::int, 0) + rew);
              nommem := jsonb_set(nommem, '{points}', to_jsonb(ncur));
              nommem := jsonb_set(nommem, '{season}', to_jsonb(nsea));
              nommem := jsonb_set(nommem, '{history}',
                      coalesce(nommem->'history','[]'::jsonb)
                      || jsonb_build_array(jsonb_build_object('l', nlabel, 'd', rew)));
              members := jsonb_set(members, array[nidx::text], nommem);
            end if;
          end if;
        end if;

        members := jsonb_set(members, array[midx::text], mem);
        d := jsonb_set(d, '{members}', members);
      end if;
    end if;

    r := jsonb_set(r, '{applied}', 'true'::jsonb);
  end if;

  rites := jsonb_set(rites, array[idx::text], r);
  d := jsonb_set(d, '{rites}', rites);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return r;
end; $function$;
