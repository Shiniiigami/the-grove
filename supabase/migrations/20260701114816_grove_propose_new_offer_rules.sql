-- Bring the server's offering guard rails into parity with the client's reworked
-- offering rules (index.html): a global 6h public cooldown, a 30-minute nomination
-- window, a 24h per-target cooldown, and a block on offering a spirit who is already
-- offered. The per-supplicant 12h cooldown and the "Eye is full" (3 offered) cap are
-- kept. The Keeper's `offerGateClearedAt` reset bypasses the public cooldown.
CREATE OR REPLACE FUNCTION public.grove_propose(p_item jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d jsonb; rites jsonb; members jsonb; item jsonb;
  nominator text; kind text; target text;
  nowep double precision := extract(epoch from now());
  i int; midx int := -1;
  last_off double precision := 0; active_off int := 0; pending_off int := 0;
  cool constant double precision := 12*3600;      -- per-supplicant cooldown
  ttl  constant double precision := 30*60;        -- an offering nomination sits 30 minutes
  same_cool constant double precision := 24*3600; -- the same spirit can't be offered twice in 24h
  pub_cool  constant double precision := 6*3600;  -- the grove may raise one offering every 6h
  last_raise double precision := 0;               -- newest offer rite (applied or not)
  gate_cleared double precision := 0;             -- Keeper's public-cooldown reset
  tgt_offered double precision := 0;
  hrs_left int;
  v_pts int; v_thr int; ap int;
begin
  select data into d from public.grove_state where id = 1;
  if d is null then raise exception 'grove not seeded'; end if;

  nominator := coalesce(p_item->>'nominator','');
  kind      := coalesce(p_item->>'kind','');
  target    := coalesce(p_item->>'target','');
  rites     := coalesce(d->'rites','[]'::jsonb);
  members   := coalesce(d->'members','[]'::jsonb);

  -- the nominator must be a real spirit (server seeds them as the first approver)
  if not exists (select 1 from jsonb_array_elements(members) mm where mm->>'name' = nominator) then
    raise exception 'unknown nominator';
  end if;

  -- ===== Offering guard rails (only for kind = 'offer') =====
  if kind = 'offer' then
    gate_cleared := coalesce((d->>'offerGateClearedAt')::double precision, 0);

    -- one pass over the members: per-supplicant cooldown stamp, the target's own
    -- offered timer, and how many OTHER spirits currently stand offered.
    for i in 0 .. jsonb_array_length(members) - 1 loop
      if members->i->>'name' = nominator then
        midx := i;
        last_off := coalesce((members->i->>'lastOffer')::double precision, 0);
      end if;
      if members->i->>'name' = target then
        tgt_offered := coalesce((members->i->>'offered')::double precision, 0);
      end if;
      if coalesce((members->i->>'offered')::double precision, 0) > nowep
         and members->i->>'name' <> target then
        active_off := active_off + 1;
      end if;
    end loop;

    if tgt_offered > nowep then
      raise exception '% already stands offered to the Eye - none may be offered twice.', target;
    end if;
    if last_off > 0 and (nowep - last_off) < cool then
      hrs_left := ceil((cool - (nowep - last_off)) / 3600.0);
      raise exception 'You raised an offering recently - wait about % h before raising another.', hrs_left;
    end if;
    if active_off >= 3 then
      raise exception 'Three spirits are already offered - the Eye is full. Wait for one to fade.';
    end if;

    -- one pass over the offer rites: newest raise (for the public cooldown), the
    -- 24h per-target guard on applied offers, and the 30m pending-window guards.
    for i in 0 .. jsonb_array_length(rites) - 1 loop
      if rites->i->>'kind' = 'offer' then
        if coalesce((rites->i->>'created')::double precision, 0) > last_raise then
          last_raise := coalesce((rites->i->>'created')::double precision, 0);
        end if;
        if coalesce((rites->i->>'applied')::boolean, false) then
          if rites->i->>'target' = target
             and (nowep - coalesce((rites->i->>'created')::double precision, 0)) < same_cool then
            raise exception '% was offered within the last day - the same offering cannot be made twice in 24 hours.', target;
          end if;
        else
          if (nowep - coalesce((rites->i->>'created')::double precision, 0)) < ttl then
            pending_off := pending_off + 1;
            if rites->i->>'nominator' = nominator then
              raise exception 'You have already named an offering - one per supplicant. Wait for it to be judged.';
            end if;
            if rites->i->>'target' = target then
              raise exception '% is already before the Eye - wait for that offering to be judged.', target;
            end if;
          end if;
        end if;
      end if;
    end loop;

    if pending_off >= 3 then
      raise exception 'Three offerings already stand before the Eye. Wait for one to be judged.';
    end if;

    -- global 6h public cooldown, unless the Keeper cleared it since the last raise
    if last_raise > 0 and (nowep - last_raise) < pub_cool and gate_cleared < last_raise then
      hrs_left := ceil((pub_cool - (nowep - last_raise)) / 3600.0);
      raise exception 'The grove must wait - the next offering can be chosen in about % h.', hrs_left;
    end if;

    if midx >= 0 then
      d := jsonb_set(d, array['members', midx::text, 'lastOffer'], to_jsonb(nowep));
    end if;
  end if;

  -- ===== server-canonical points + approval threshold (client values are NOT trusted) =====
  ap := abs(coalesce((p_item->>'points')::int, 0));
  if kind = 'deed' then
    v_pts := greatest(-200, least(200, coalesce((p_item->>'points')::int, 0)));
    ap := abs(v_pts);
    v_thr := case when ap<=20 then 3 when ap<=49 then 4 when ap<=69 then 5
                  when ap<=100 then 6 when ap<=150 then 7 else 8 end;
  elsif kind = 'newdeed' then
    v_pts := greatest(-50, least(100, coalesce((p_item->>'points')::int, 0)));
    v_thr := 8;
  elsif kind = 'title' then v_pts := 0; v_thr := 10;
  elsif kind = 'badge' then v_pts := 0; v_thr := 7;
  elsif kind = 'offer' then v_pts := 0; v_thr := 7;
  elsif kind = 'oath'  then v_pts := 0; v_thr := 4;
  else v_pts := 0; v_thr := greatest(1, coalesce((p_item->>'threshold')::int, 5));
  end if;

  item := jsonb_build_object(
    'id',         gen_random_uuid()::text,
    'kind',       kind,
    'target',     target,
    'label',      p_item->>'label',
    'points',     v_pts,
    'threshold',  v_thr,
    'nominator',  nominator,
    'approvers',  jsonb_build_array(nominator),
    'applied',    false,
    'created',    nowep
  );

  rites := coalesce(d->'rites','[]'::jsonb) || jsonb_build_array(item);
  d := jsonb_set(d, '{rites}', rites);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return item;
end; $function$;
