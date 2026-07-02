-- ============================================================================
--  The Grove — canonical Supabase schema (source of truth)
-- ============================================================================
--  This is the full server-side backend for the live remote grove: the tables,
--  the single public-read RLS policy, and every `grove_*` RPC the client
--  (index.html) calls in MODE === 'remote'.
--
--  It is idempotent — safe to run whole against the project at any time. Older
--  builds referred to fragments of this as `grove_trials.sql` / `grove_thought.sql`;
--  this file supersedes them and is the one place the whole backend lives.
--
--  Design note: the app is a public, honour-system PWA. The `anon` key calls
--  these `SECURITY DEFINER` RPCs directly; Keeper-only mutations (grove_save,
--  grove_setpass, grove_clear_rites, grove_remove_rite) are gated by the keeper
--  passphrase *inside* the function. `grove_state` is publicly readable so the
--  client can hydrate; `grove_config` (holds the hashed keeper pass) and
--  `grove_push_subs` have RLS on with NO policy, so they are reachable only
--  through the definer functions. The linter's "RLS enabled, no policy" and
--  "anon can execute SECURITY DEFINER" notices are therefore expected and by
--  design, not defects.
--
--  Server DB version: see grove_ver() at the bottom (client EXPECTED_DB gate).
-- ============================================================================

-- pgcrypto (crypt / gen_salt) lives in the `extensions` schema on Supabase and
-- is referenced fully-qualified by the keeper-pass functions below.
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------------
create table if not exists public.grove_state (
  id         integer primary key,
  data       jsonb not null,
  updated_at timestamptz default now()
);

create table if not exists public.grove_config (
  k text primary key,
  v text not null
);

create table if not exists public.grove_push_subs (
  endpoint   text primary key,
  name       text not null,
  p256dh     text not null,
  auth       text not null,
  updated_at timestamptz default now()
);

alter table public.grove_state     enable row level security;
alter table public.grove_config    enable row level security;
alter table public.grove_push_subs enable row level security;

-- the only direct-table grant the client needs: read the shared state blob
drop policy if exists "public read state" on public.grove_state;
create policy "public read state" on public.grove_state for select using (true);

-- ---------------------------------------------------------------------------
--  Pure helpers (IMMUTABLE) — jsonb member math
-- ---------------------------------------------------------------------------
create or replace function public.grove_adj(m jsonb, delta integer)
 returns jsonb language sql immutable set search_path to 'public','pg_temp'
as $$
  select jsonb_set(
           jsonb_set(m, '{points}', to_jsonb(greatest(0, coalesce((m->>'points')::int,0)+delta))),
           '{season}', to_jsonb(greatest(0, coalesce((m->>'season')::int,0)+delta)));
$$;

create or replace function public.grove_credit(members jsonb, nm text, delta integer)
 returns jsonb language plpgsql immutable set search_path to 'public','pg_temp'
as $$
declare i int;
begin
  for i in 0 .. coalesce(jsonb_array_length(members),0)-1 loop
    if members->i->>'name' = nm then
      return jsonb_set(members, array[i::text], grove_adj(members->i, delta));
    end if;
  end loop;
  return members;
end; $$;

create or replace function public.grove_hist(m jsonb, label text, delta integer, t double precision)
 returns jsonb language sql immutable set search_path to 'public','pg_temp'
as $$
  select jsonb_set(m, '{history}',
    coalesce(m->'history','[]'::jsonb)
      || jsonb_build_array(jsonb_build_object('l', label, 'd', delta, 't', t)));
$$;

create or replace function public.grove_pts(members jsonb, nm text)
 returns integer language sql immutable set search_path to 'public','pg_temp'
as $$
  select coalesce((select (m->>'points')::int from jsonb_array_elements(members) m where m->>'name' = nm limit 1), 0);
$$;

create or replace function public.grove_rmbadge(badges jsonb, b text)
 returns jsonb language sql immutable set search_path to 'public','pg_temp'
as $$
  select coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(badges,'[]'::jsonb)) x where x <> to_jsonb(b)), '[]'::jsonb);
$$;

-- ---------------------------------------------------------------------------
--  Seed / save / keeper-pass
-- ---------------------------------------------------------------------------
create or replace function public.grove_seed(p_data jsonb)
 returns void language plpgsql security definer set search_path to 'public'
as $$
begin
  insert into public.grove_state (id, data) values (1, p_data)
  on conflict (id) do nothing;
end; $$;

create or replace function public.grove_check(p_pass text)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
begin
  return exists (
    select 1 from public.grove_config
    where k='keeper_pass'
      and v = case when v like '$2%' then extensions.crypt(p_pass, v) else p_pass end
  );
end; $$;

create or replace function public.grove_setpass(p_old text, p_new text)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
begin
  if not exists (
    select 1 from public.grove_config
    where k='keeper_pass'
      and v = case when v like '$2%' then extensions.crypt(p_old, v) else p_old end
  ) then
    raise exception 'bad passphrase';
  end if;
  update public.grove_config set v = extensions.crypt(p_new, extensions.gen_salt('bf')) where k='keeper_pass';
  return true;
end; $$;

-- legacy 2-arg keeper save (kept for older clients)
create or replace function public.grove_save(p_pass text, p_data jsonb)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
begin
  if not exists (
    select 1 from public.grove_config
    where k='keeper_pass'
      and v = case when v like '$2%' then extensions.crypt(p_pass, v) else p_pass end
  ) then
    raise exception 'bad passphrase';
  end if;
  insert into public.grove_state (id, data, updated_at) values (1, p_data, now())
  on conflict (id) do update set data = excluded.data, updated_at = now();
  return true;
end; $$;

-- current keeper save: optimistic-concurrency guard on updated_at, returns new stamp
create or replace function public.grove_save(p_pass text, p_data jsonb, p_expected text default null)
 returns text language plpgsql security definer set search_path to 'public'
as $$
declare v_ts timestamptz;
begin
  if not exists (
    select 1 from public.grove_config
    where k='keeper_pass'
      and v = case when v like '$2%' then extensions.crypt(p_pass, v) else p_pass end
  ) then
    raise exception 'bad passphrase';
  end if;
  if p_expected is not null and p_expected <> '' then
    if exists (select 1 from public.grove_state where id=1 and updated_at is distinct from p_expected::timestamptz) then
      raise exception 'stale grove: reload before saving';
    end if;
  end if;
  insert into public.grove_state (id, data, updated_at) values (1, p_data, now())
  on conflict (id) do update set data = excluded.data, updated_at = now()
  returning updated_at into v_ts;
  return v_ts::text;
end; $$;

create or replace function public.grove_set_chibi(p_name text, p_chibi jsonb)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
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
end; $$;

-- ---------------------------------------------------------------------------
--  Web-push subscriptions (definer-only; no direct table access)
-- ---------------------------------------------------------------------------
create or replace function public.grove_push_save(p_name text, p_sub jsonb)
 returns void language plpgsql security definer set search_path to 'public'
as $$
begin
  if p_sub is null or (p_sub->>'endpoint') is null then return; end if;
  insert into public.grove_push_subs(endpoint, name, p256dh, auth, updated_at)
  values (
    p_sub->>'endpoint',
    coalesce(nullif(p_name,''),'soul'),
    p_sub->'keys'->>'p256dh',
    p_sub->'keys'->>'auth',
    now()
  )
  on conflict (endpoint) do update
    set name=excluded.name, p256dh=excluded.p256dh, auth=excluded.auth, updated_at=now();
end; $$;

create or replace function public.grove_push_del(p_endpoint text)
 returns void language plpgsql security definer set search_path to 'public'
as $$
begin
  delete from public.grove_push_subs where endpoint = p_endpoint;
end; $$;

-- ---------------------------------------------------------------------------
--  Rites: propose / vote / withdraw / keeper clear+remove
-- ---------------------------------------------------------------------------
-- grove_propose: raises a rite. Server is canonical for points, thresholds and
-- (for offerings) the full guard-rail set: 12h per-supplicant cooldown, 30m
-- pending window, 24h same-target guard, 6h grove-wide public cooldown, max 3
-- standing / pending offerings, keeper-cleared gate.
create or replace function public.grove_propose(p_item jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
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
  select data into d from public.grove_state where id = 1 for update;
  if d is null then raise exception 'grove not seeded'; end if;

  nominator := coalesce(p_item->>'nominator','');
  kind      := coalesce(p_item->>'kind','');
  target    := coalesce(p_item->>'target','');
  rites     := coalesce(d->'rites','[]'::jsonb);
  members   := coalesce(d->'members','[]'::jsonb);

  if not exists (select 1 from jsonb_array_elements(members) mm where mm->>'name' = nominator) then
    raise exception 'unknown nominator';
  end if;
  if kind <> 'newdeed' and not exists (select 1 from jsonb_array_elements(members) mm where mm->>'name' = target) then
    raise exception 'unknown target';
  end if;
  if nominator = target and kind in ('title','badge','offer') then
    raise exception 'You cannot nominate yourself for a title, badge or offering.';
  end if;

  if kind = 'offer' then
    gate_cleared := coalesce((d->>'offerGateClearedAt')::double precision, 0);
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

    if last_raise > 0 and (nowep - last_raise) < pub_cool and gate_cleared < last_raise then
      hrs_left := ceil((pub_cool - (nowep - last_raise)) / 3600.0);
      raise exception 'The grove must wait - the next offering can be chosen in about % h.', hrs_left;
    end if;

    if midx >= 0 then
      d := jsonb_set(d, array['members', midx::text, 'lastOffer'], to_jsonb(nowep));
    end if;
  end if;

  -- server-canonical points + approval threshold (client values are NOT trusted)
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
end; $$;

-- grove_vote: one distinct approval; applies the rite's effect once the threshold
-- is crossed. Nominator bounties: title +25, badge +20, deed by size (5/10/15/20/
-- 25/30) but ONLY for a gain (never for a penalty), offering +50. Wheel/winMult
-- buff is consumed on a passing positive deed.
create or replace function public.grove_vote(p_id text, p_voter text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d jsonb; rites jsonb; r jsonb; appr jsonb; members jsonb; mem jsonb;
  i int; idx int := -1; midx int := -1;
  thr int; kind text; target text; pts int; lbl text;
  cur int; sea int; chibi jsonb;
  nowe double precision; cnt int; jj int;
  nomname text; nidx int; nommem jsonb; ncur int; nsea int;
  rew int := 0; nlabel text := '';
begin
  select data into d from public.grove_state where id = 1 for update;
  if d is null then raise exception 'grove not seeded'; end if;

  rites := coalesce(d->'rites','[]'::jsonb);
  for i in 0 .. jsonb_array_length(rites) - 1 loop
    if rites->i->>'id' = p_id then idx := i; exit; end if;
  end loop;
  if idx < 0 then raise exception 'no such rite'; end if;

  r := rites->idx;
  if coalesce((r->>'applied')::boolean, false) then return r; end if;

  if not exists (select 1 from jsonb_array_elements(coalesce(d->'members','[]'::jsonb)) mm
                 where mm->>'name' = p_voter) then
    return r;
  end if;

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
          pts := greatest(-200, least(200, coalesce((r->>'points')::int, 0)));
          rew := case when abs(pts)<=20 then 5 when abs(pts)<=49 then 10 when abs(pts)<=69 then 15
                      when abs(pts)<=100 then 20 when abs(pts)<=150 then 25 else 30 end;
          -- reward the nominator only for recognising a GAIN, never for a penalty
          -- (matches client: r.points>0 ? nominatorDeedReward : 0)
          if pts <= 0 then rew := 0; end if;
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
                  || jsonb_build_array(jsonb_build_object('l', r->>'label', 'd', pts)));
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

        -- reward the nominator of a passing title / badge / deed (offerings pay
        -- inline above; oaths and new deeds carry no nominator bounty)
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
end; $$;

create or replace function public.grove_withdraw(p_id text, p_who text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d jsonb; rites jsonb; out_rites jsonb := '[]'::jsonb; r jsonb;
  i int; found boolean := false;
  n int; thr int; applied boolean;
begin
  select data into d from public.grove_state where id = 1 for update;
  if d is null then raise exception 'grove not seeded'; end if;

  rites := coalesce(d->'rites','[]'::jsonb);
  for i in 0 .. jsonb_array_length(rites) - 1 loop
    r := rites->i;
    if r->>'id' = p_id then
      found   := true;
      applied := coalesce((r->>'applied')::boolean, false);
      n       := coalesce(jsonb_array_length(r->'approvers'), 0);
      thr     := coalesce((r->>'threshold')::int, 5);
      if r->>'nominator' <> p_who then
        raise exception 'Only the one who raised it can withdraw it.';
      end if;
      if applied then
        raise exception 'It has already passed — it cannot be withdrawn.';
      end if;
      if n * 2 >= thr then
        raise exception 'Too many have approved — it can no longer be withdrawn.';
      end if;
    else
      out_rites := out_rites || jsonb_build_array(r);
    end if;
  end loop;

  if not found then return d; end if;

  d := jsonb_set(d, '{rites}', out_rites);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return d;
end; $$;

create or replace function public.grove_clear_rites(p_pass text)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
declare d jsonb; rites jsonb; kept jsonb := '[]'::jsonb; i int;
begin
  if not exists (
    select 1 from public.grove_config
    where k='keeper_pass'
      and v = case when v like '$2%' then extensions.crypt(p_pass, v) else p_pass end
  ) then
    raise exception 'bad passphrase';
  end if;
  select data into d from public.grove_state where id = 1 for update;
  rites := coalesce(d->'rites','[]'::jsonb);
  for i in 0 .. jsonb_array_length(rites) - 1 loop
    if not coalesce((rites->i->>'applied')::boolean,false) then
      kept := kept || jsonb_build_array(rites->i);
    end if;
  end loop;
  d := jsonb_set(d, '{rites}', kept);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return true;
end; $$;

create or replace function public.grove_remove_rite(p_id text, p_pass text)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
declare d jsonb; rites jsonb; kept jsonb := '[]'::jsonb; i int;
begin
  if not exists (
    select 1 from public.grove_config
    where k='keeper_pass'
      and v = case when v like '$2%' then extensions.crypt(p_pass, v) else p_pass end
  ) then
    raise exception 'bad passphrase';
  end if;
  select data into d from public.grove_state where id = 1;
  rites := coalesce(d->'rites','[]'::jsonb);
  for i in 0 .. jsonb_array_length(rites) - 1 loop
    if rites->i->>'id' <> p_id then
      kept := kept || jsonb_build_array(rites->i);
    end if;
  end loop;
  d := jsonb_set(d, '{rites}', kept);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return true;
end; $$;

-- ---------------------------------------------------------------------------
--  Thought bubbles (stored as epoch SECONDS; client normalises but expects s)
-- ---------------------------------------------------------------------------
create or replace function public.grove_thought(p_name text, p_text text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d jsonb; members jsonb; m jsonb; i int; txt text; nowe double precision;
begin
  select data into d from public.grove_state where id = 1;
  if d is null then raise exception 'grove not seeded'; end if;
  nowe := extract(epoch from now());
  txt := left(btrim(coalesce(p_text, '')), 40);

  members := coalesce(d->'members', '[]'::jsonb);
  for i in 0 .. jsonb_array_length(members) - 1 loop
    if members->i->>'name' = p_name then
      m := members->i;
      if txt = '' then
        m := m - 'thought';
      else
        m := jsonb_set(m, '{thought}', jsonb_build_object('text', txt, 'at', nowe), true);
      end if;
      members := jsonb_set(members, array[i::text], m);
      exit;
    end if;
  end loop;

  d := jsonb_set(d, '{members}', members);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return d;
end; $$;

-- ---------------------------------------------------------------------------
--  The Wheel (Test of Devotion). 15 stake, one spin / 2h, outcome server-side.
-- ---------------------------------------------------------------------------
-- weighted outcome table (random()*100):
--   3% jackpot +250 · 6% +150 · 10% +100 · 12% +75 · 10% +50 · 6% free
--   6% x2 · 3% x3 · 13% zero · 5% x2neg · 12% -25 · 9% -50 · 5% -100
create or replace function public.grove_wheel_pick()
 returns jsonb language plpgsql set search_path to 'public','pg_temp'
as $$
declare r double precision := random()*100;
begin
  if    r < 3   then return '{"key":"jackpot","pts":250}'::jsonb;
  elsif r < 9   then return '{"key":"p150","pts":150}'::jsonb;
  elsif r < 19  then return '{"key":"p100","pts":100}'::jsonb;
  elsif r < 31  then return '{"key":"p75","pts":75}'::jsonb;
  elsif r < 41  then return '{"key":"p50","pts":50}'::jsonb;
  elsif r < 47  then return '{"key":"free","special":"free"}'::jsonb;
  elsif r < 53  then return '{"key":"x2","special":"x2"}'::jsonb;
  elsif r < 56  then return '{"key":"x3","special":"x3"}'::jsonb;
  elsif r < 69  then return '{"key":"zero","pts":0}'::jsonb;
  elsif r < 74  then return '{"key":"x2neg","special":"x2neg"}'::jsonb;
  elsif r < 86  then return '{"key":"m25","pts":-25}'::jsonb;
  elsif r < 95  then return '{"key":"m50","pts":-50}'::jsonb;
  else               return '{"key":"m100","pts":-100}'::jsonb;
  end if;
end; $$;

-- devotion.total tracks the TRUE net per spin = -15 stake (+15 refunded on a
-- free spin) + the verdict, so the "Test of Devotion" ledger line always sums to
-- the points actually moved (matches applyAction('wheel_spin') on the client).
create or replace function public.grove_wheel(p_name text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d jsonb; members jsonb; midx int := -1; i int; nowe double precision := extract(epoch from now());
  o jsonb; sp text; spv int;
begin
  select data into d from public.grove_state where id = 1;
  if d is null then raise exception 'grove not seeded'; end if;
  members := coalesce(d->'members','[]'::jsonb);
  for i in 0 .. jsonb_array_length(members)-1 loop
    if members->i->>'name' = p_name then midx := i; exit; end if;
  end loop;
  if midx < 0 then return '{"denied":true,"reason":"unknown"}'::jsonb; end if;
  if coalesce((members->midx->>'lastSpin')::double precision,0) + 7200 > nowe then
    return '{"denied":true,"reason":"cooldown"}'::jsonb;
  end if;
  if coalesce((members->midx->>'points')::int,0) < 15 then
    return '{"denied":true,"reason":"funds"}'::jsonb;
  end if;

  -- pay the toll (15), stamp the spin
  members := jsonb_set(members, array[midx::text], grove_adj(members->midx, -15));
  members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{lastSpin}', to_jsonb(nowe)));

  o  := grove_wheel_pick();
  sp := o->>'special';
  if sp = 'free' then
    members := jsonb_set(members, array[midx::text], grove_adj(members->midx, 15));
    members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{lastSpin}', to_jsonb(0)));
  elsif sp = 'x2' then
    members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{winMult}', to_jsonb(2)));
  elsif sp = 'x3' then
    members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{winMult}', to_jsonb(3)));
  elsif sp = 'x2neg' then
    members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{lossMult}', to_jsonb(2)));
  else
    spv := coalesce((o->>'pts')::int,0);
    if spv > 0 and coalesce((members->midx->>'winMult')::int,1) > 1 then
      spv := spv * coalesce((members->midx->>'winMult')::int,1);
      members := jsonb_set(members, array[midx::text], (members->midx) - 'winMult');
    end if;
    members := jsonb_set(members, array[midx::text], grove_adj(members->midx, spv));
    if spv > 0 and random() < least(1.0, spv::numeric/100.0) then
      members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{logs}', to_jsonb(coalesce((members->midx->>'logs')::int,0)+1)));
    end if;
  end if;

  members := jsonb_set(members, array[midx::text,'devotion'], jsonb_build_object(
      'spins', coalesce((members->midx#>>'{devotion,spins}')::int,0)+1,
      'total', coalesce((members->midx#>>'{devotion,total}')::int,0)
                 - 15
                 + case when sp = 'free' then 15 else 0 end
                 + case when o ? 'pts' then (o->>'pts')::int else 0 end), true);
  d := jsonb_set(d, '{members}', members);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return o;
end; $$;

-- ---------------------------------------------------------------------------
--  grove_action: the honour-system action funnel — fire, challenges, wagers,
--  group wagers, oath. Runs sweeps (fire decay, expiries, dispute timers) on
--  every call, then applies p_action->>'t'. See index.html applyAction() for the
--  client-side mirror of each branch.
--  (Note: the legacy 't'='wheel_spin' branch here is the old 50-stake wheel and
--   is no longer called by the client, which uses grove_wheel() above.)
-- ---------------------------------------------------------------------------
create or replace function public.grove_action(p_action jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d jsonb; t text; nowe double precision;
  members jsonb; chals jsonb; c jsonb; m jsonb; stokers jsonb; wagers jsonb;
  i int; midx int; cidx int; cnt int; widx int;
  nm text; owner_n text; acc text; cid text; wid text; win text;
  rew int; bud int; goal int; lvl int; blessed double precision; sea int; amt int;
  mult int; sp text; spv int; o jsonb;
  streak int; decn int; lastdec double precision; bless int; topn int; topname text;
  groups jsonb; g jsonb; gid text; gidx int; gside text; gstake int; gpot int; gshare int; gwin text;
  sidearr jsonb; totalp int; ccount int; cdist int; gav int; gbv int;
begin
  select data into d from public.grove_state where id = 1 for update;
  if d is null then raise exception 'grove not seeded'; end if;
  t     := p_action->>'t';
  nowe  := extract(epoch from now());
  members := coalesce(d->'members','[]'::jsonb);
  chals   := coalesce(d->'challenges','[]'::jsonb);
  wagers  := coalesce(d->'wagers','[]'::jsonb);
  groups  := coalesce(d->'groups','[]'::jsonb);

  -- decay the fire: it loses 1 log for every 3h of neglect
  lastdec := coalesce((d#>>'{fire,lastDecay}')::double precision, nowe);
  decn := floor((nowe - lastdec) / 10800)::int;
  if decn > 0 then
    lvl := greatest(0, coalesce((d#>>'{fire,level}')::int,0) - decn);
    stokers := coalesce(d#>'{fire,stokers}','[]'::jsonb);
    if lvl = 0 then stokers := '[]'::jsonb; end if;
    d := jsonb_set(d, '{fire}', jsonb_set(jsonb_set(jsonb_set(coalesce(d->'fire','{}'::jsonb),
            '{level}', to_jsonb(lvl)),
            '{lastDecay}', to_jsonb(lastdec + decn*10800)),
            '{stokers}', stokers), true);
  end if;

  -- sweep expired open wagers (refund proposer); age matched->disputed, disputed->forfeit
  for widx in 0 .. jsonb_array_length(wagers)-1 loop
    if wagers->widx->>'status' = 'open' and coalesce((wagers->widx->>'created')::double precision,nowe) + 86400 <= nowe then
      nm := wagers->widx->>'proposer'; amt := coalesce((wagers->widx->>'amount')::int,0);
      for midx in 0 .. jsonb_array_length(members)-1 loop
        if members->midx->>'name' = nm then
          members := jsonb_set(members, array[midx::text], grove_adj(members->midx, amt));
          exit;
        end if;
      end loop;
      wagers := jsonb_set(wagers, array[widx::text], jsonb_set(wagers->widx,'{status}', to_jsonb('expired'::text)));
    end if;
    if wagers->widx->>'status' = 'matched' and coalesce((wagers->widx->>'matchedAt')::double precision,(wagers->widx->>'created')::double precision,nowe) + 86400 <= nowe then
      wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('disputed'::text)), array[widx::text,'disputeAt'], to_jsonb(nowe));
    end if;
    if wagers->widx->>'status' = 'disputed' and coalesce((wagers->widx->>'disputeAt')::double precision,nowe) + 3600 <= nowe then
      wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('forfeit'::text)), array[widx::text,'winner'], to_jsonb('forfeit'::text));
    end if;
  end loop;

  -- sweep group wagers: expire unlocked >1h (refund all), force dispute on active >24h, void disputed >1h (refund all)
  for gidx in 0 .. jsonb_array_length(groups)-1 loop
    g := groups->gidx;
    if g->>'status' = 'pending' and coalesce((g->>'created')::double precision,nowe) + 3600 <= nowe then
      gstake := coalesce((g->>'stake')::int,0);
      for i in 0 .. jsonb_array_length(coalesce(g->'sideA','[]'::jsonb))-1 loop members := grove_credit(members, g->'sideA'->>i, gstake); end loop;
      for i in 0 .. jsonb_array_length(coalesce(g->'sideB','[]'::jsonb))-1 loop members := grove_credit(members, g->'sideB'->>i, gstake); end loop;
      groups := jsonb_set(groups, array[gidx::text], jsonb_set(g,'{status}', to_jsonb('expired'::text)));
    elsif g->>'status' = 'active' and coalesce((g->>'lockedAt')::double precision,nowe) + 86400 <= nowe then
      groups := jsonb_set(jsonb_set(groups, array[gidx::text,'status'], to_jsonb('disputed'::text)), array[gidx::text,'disputeAt'], to_jsonb(nowe));
    elsif g->>'status' = 'disputed' and coalesce((g->>'disputeAt')::double precision,nowe) + 3600 <= nowe then
      gstake := coalesce((g->>'stake')::int,0);
      for i in 0 .. jsonb_array_length(coalesce(g->'sideA','[]'::jsonb))-1 loop members := grove_credit(members, g->'sideA'->>i, gstake); end loop;
      for i in 0 .. jsonb_array_length(coalesce(g->'sideB','[]'::jsonb))-1 loop members := grove_credit(members, g->'sideB'->>i, gstake); end loop;
      groups := jsonb_set(jsonb_set(groups, array[gidx::text,'status'], to_jsonb('void'::text)), array[gidx::text,'winner'], to_jsonb('void'::text));
    end if;
  end loop;

  -- sweep expired challenges (refund the owner's budget)
  if jsonb_array_length(chals) > 0 then
    for cidx in 0 .. jsonb_array_length(chals)-1 loop
      c := chals->cidx;
      if ((c->>'status' in ('open','accepted'))
         and (coalesce((c->>'created')::double precision, nowe) + 86400) < nowe)
         or (c->>'status' = 'accepted' and (c->>'deadline') is not null and (c->>'deadline')::double precision < nowe) then
        owner_n := c->>'owner'; rew := coalesce((c->>'reward')::int,0);
        for midx in 0 .. jsonb_array_length(members)-1 loop
          if members->midx->>'name' = owner_n then
            bud := coalesce((members->midx->>'chalBudget')::int,150) + rew;
            members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{chalBudget}', to_jsonb(bud)));
            exit;
          end if;
        end loop;
        chals := jsonb_set(chals, array[cidx::text], jsonb_set(c,'{status}', to_jsonb('expired'::text)));
      end if;
    end loop;
  end if;

  -- ---- STOKE THE FIRE (needs a log; once per 3h; +20 spark + streak blessing up to +200) ----
  if t = 'stoke' then
    nm := p_action->>'name';
    for midx in 0 .. jsonb_array_length(members)-1 loop
      if members->midx->>'name' = nm then
        if coalesce((members->midx->>'lastStoke')::double precision,0) + 10800 <= nowe
           and coalesce((members->midx->>'logs')::int,0) >= 1 then
          members := jsonb_set(members, array[midx::text],
                       jsonb_set(jsonb_set(jsonb_set(members->midx,
                         '{logs}',     to_jsonb(coalesce((members->midx->>'logs')::int,0)-1)),
                         '{fireLogs}', to_jsonb(coalesce((members->midx->>'fireLogs')::int,0)+1)),
                         '{lastStoke}', to_jsonb(nowe)));
          goal    := coalesce((d#>>'{fire,goal}')::int, 8);
          lvl     := coalesce((d#>>'{fire,level}')::int, 0) + 1;
          streak  := coalesce((d#>>'{fire,streak}')::int, 0);
          blessed := coalesce((d#>>'{fire,lastBlessed}')::double precision, 0);
          stokers := coalesce(d#>'{fire,stokers}', '[]'::jsonb);
          if not stokers @> to_jsonb(nm) then stokers := stokers || to_jsonb(nm); end if;
          if lvl >= goal then
            if blessed > 0 and (nowe - blessed) >= 86400 then streak := 0; end if;
            bless := least(200, 50 + 25*streak);
            for cidx in 0 .. jsonb_array_length(stokers)-1 loop
              for i in 0 .. jsonb_array_length(members)-1 loop
                if members->i->>'name' = (stokers->>cidx) then
                  members := jsonb_set(members, array[i::text], grove_hist(grove_adj(members->i, bless), 'Tended the Sacred Fire', bless, nowe));
                  exit;
                end if;
              end loop;
            end loop;
            for i in 0 .. jsonb_array_length(members)-1 loop
              if members->i->>'name' = nm then
                members := jsonb_set(members, array[i::text], grove_hist(grove_adj(members->i, 20), 'Struck the Final Spark', 20, nowe));
                exit;
              end if;
            end loop;
            topn := 0; topname := null;
            for i in 0 .. jsonb_array_length(members)-1 loop
              if coalesce((members->i->>'fireLogs')::int,0) > topn then
                topn := coalesce((members->i->>'fireLogs')::int,0); topname := members->i->>'name';
              end if;
            end loop;
            for i in 0 .. jsonb_array_length(members)-1 loop
              m := jsonb_set(members->i, '{badges}', grove_rmbadge(members->i->'badges','Keeper of the Flame'));
              if topname is not null and topn > 0 and members->i->>'name' = topname then
                m := jsonb_set(m, '{badges}', coalesce(m->'badges','[]'::jsonb) || to_jsonb('Keeper of the Flame'::text));
              end if;
              members := jsonb_set(members, array[i::text], m);
            end loop;
            d := jsonb_set(d, '{fire}', jsonb_build_object('level',0,'goal',goal,'lastBlessed',nowe,'lastDecay',nowe,'stokers','[]'::jsonb,'streak',streak+1,'lastSpark',nm,'lastBless',bless), true);
          else
            d := jsonb_set(d, '{fire}', jsonb_build_object('level',lvl,'goal',goal,'lastBlessed',blessed,'lastDecay',nowe,'stokers',stokers,'streak',streak), true);
          end if;
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'chal_new' then
    owner_n := p_action->>'owner';
    rew := greatest(1, least(150, coalesce((p_action->>'reward')::int,0)));
    for midx in 0 .. jsonb_array_length(members)-1 loop
      if members->midx->>'name' = owner_n then
        bud := coalesce((members->midx->>'chalBudget')::int,150);
        if bud >= rew then
          members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{chalBudget}', to_jsonb(bud-rew)));
          chals := chals || jsonb_build_array(jsonb_build_object(
            'id',       'c'||substr(md5(random()::text || clock_timestamp()::text),1,12),
            'owner',    owner_n,
            'title',    coalesce(p_action->>'title','Challenge'),
            'reward',   rew,
            'accepter', null,
            'created',  nowe,
            'status',   'open'));
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'chal_accept' then
    cid := p_action->>'id'; nm := p_action->>'name';
    cnt := 0;
    for cidx in 0 .. jsonb_array_length(chals)-1 loop
      if chals->cidx->>'status' = 'accepted' and chals->cidx->>'accepter' = nm then cnt := cnt + 1; end if;
    end loop;
    if cnt < 3 then
      for cidx in 0 .. jsonb_array_length(chals)-1 loop
        if chals->cidx->>'id' = cid then
          if chals->cidx->>'status' = 'open' and chals->cidx->>'owner' <> nm then
            c := jsonb_set(chals->cidx, '{accepter}', to_jsonb(nm));
            c := jsonb_set(c, '{status}', to_jsonb('accepted'::text));
            chals := jsonb_set(chals, array[cidx::text], c);
          end if;
          exit;
        end if;
      end loop;
    end if;

  elsif t = 'chal_remove' then
    cid := p_action->>'id'; nm := p_action->>'by';
    for cidx in 0 .. jsonb_array_length(chals)-1 loop
      if chals->cidx->>'id' = cid and chals->cidx->>'owner' = nm then
        if chals->cidx->>'status' = 'open' then
          rew := coalesce((chals->cidx->>'reward')::int,0);
          for midx in 0 .. jsonb_array_length(members)-1 loop
            if members->midx->>'name' = nm then
              bud := coalesce((members->midx->>'chalBudget')::int,150) + rew;
              members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{chalBudget}', to_jsonb(bud)));
              exit;
            end if;
          end loop;
          chals := chals - cidx;
        elsif chals->cidx->>'status' = 'accepted' and (chals->cidx->>'removeReq') is null then
          chals := jsonb_set(chals, array[cidx::text], jsonb_set(chals->cidx, '{removeReq}', to_jsonb(nowe)));
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'chal_remove_resolve' then
    cid := p_action->>'id'; nm := p_action->>'name';
    for cidx in 0 .. jsonb_array_length(chals)-1 loop
      if chals->cidx->>'id' = cid and chals->cidx->>'status' = 'accepted'
         and (chals->cidx->>'removeReq') is not null and chals->cidx->>'accepter' = nm then
        if p_action->>'choice' = 'accept' then
          owner_n := chals->cidx->>'owner'; rew := coalesce((chals->cidx->>'reward')::int,0);
          for midx in 0 .. jsonb_array_length(members)-1 loop
            if members->midx->>'name' = owner_n then
              bud := coalesce((members->midx->>'chalBudget')::int,150) + rew;
              members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{chalBudget}', to_jsonb(bud)));
              exit;
            end if;
          end loop;
          chals := chals - cidx;
        else
          c := jsonb_set(chals->cidx, '{deadline}', to_jsonb(nowe + 3600));
          c := c - 'removeReq';
          chals := jsonb_set(chals, array[cidx::text], c);
        end if;
        exit;
      end if;
    end loop;

  -- owner approves; reward passes to the doer, x2/x3 buff applies; a maxed trial
  -- gamed with a wheel buff is flagged 'cheated' and penalised -100
  elsif t = 'chal_approve' then
    cid := p_action->>'id'; nm := p_action->>'approver';
    for cidx in 0 .. jsonb_array_length(chals)-1 loop
      if chals->cidx->>'id' = cid then
        if chals->cidx->>'status' = 'accepted' and chals->cidx->>'owner' = nm then
          acc := chals->cidx->>'accepter'; rew := coalesce((chals->cidx->>'reward')::int,0);
          for midx in 0 .. jsonb_array_length(members)-1 loop
            if members->midx->>'name' = acc then
              mult := coalesce((members->midx->>'winMult')::int,1);
              members := jsonb_set(members, array[midx::text], (case when mult > 1 and rew >= 145 then grove_hist(grove_adj(members->midx, -100) - 'winMult', 'Cheated the Eye — gamed a maxed trial with a wheel buff', -100, nowe) else (grove_adj(members->midx, rew*mult)) - 'winMult' end));
              if not (mult > 1 and rew >= 145) and random() < least(1.0, (rew*mult)::numeric/100.0) then
                members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{logs}', to_jsonb(coalesce((members->midx->>'logs')::int,0)+1)));
              end if;
              exit;
            end if;
          end loop;
          chals := jsonb_set(chals, array[cidx::text], jsonb_set(jsonb_set(chals->cidx,'{status}', to_jsonb('done'::text)), '{cheated}', to_jsonb(coalesce(mult,1) > 1 and coalesce(rew,0) >= 145)));
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'oath' then
    nm := p_action->>'name';
    for midx in 0 .. jsonb_array_length(members)-1 loop
      if members->midx->>'name' = nm then
        m := jsonb_set(members->midx, '{oath}', 'true'::jsonb);
        if not coalesce(m->'badges','[]'::jsonb) @> to_jsonb('Initiated'::text) then
          m := jsonb_set(m, '{badges}', coalesce(m->'badges','[]'::jsonb) || to_jsonb('Initiated'::text));
        end if;
        members := jsonb_set(members, array[midx::text], m);
        exit;
      end if;
    end loop;

  elsif t = 'wager_new' then
    nm := p_action->>'proposer'; amt := least(100, greatest(1, coalesce((p_action->>'amount')::int,0)));
    for midx in 0 .. jsonb_array_length(members)-1 loop
      if members->midx->>'name' = nm then
        sea := coalesce((members->midx->>'points')::int,0);
        if sea >= amt then
          members := jsonb_set(members, array[midx::text], grove_adj(members->midx, -amt));
          wagers := wagers || jsonb_build_array(jsonb_build_object(
            'id', md5(random()::text||clock_timestamp()::text),
            'proposer', nm, 'amount', amt, 'title', p_action->>'title',
            'taker', null::text, 'status', 'open', 'winner', null::text, 'created', nowe,
            'votes', '{}'::jsonb, 'tie', '[]'::jsonb));
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'wager_accept' then
    wid := p_action->>'id'; nm := p_action->>'name';
    for widx in 0 .. jsonb_array_length(wagers)-1 loop
      if wagers->widx->>'id' = wid and wagers->widx->>'status' = 'open' and wagers->widx->>'proposer' <> nm then
        amt := coalesce((wagers->widx->>'amount')::int,0);
        for midx in 0 .. jsonb_array_length(members)-1 loop
          if members->midx->>'name' = nm then
            sea := coalesce((members->midx->>'points')::int,0);
            if sea >= amt then
              members := jsonb_set(members, array[midx::text], grove_adj(members->midx, -amt));
              wagers := jsonb_set(wagers, array[widx::text], jsonb_set(jsonb_set(jsonb_set(wagers->widx,'{taker}', to_jsonb(nm)),'{status}', to_jsonb('matched'::text)),'{matchedAt}', to_jsonb(nowe)));
            end if;
            exit;
          end if;
        end loop;
        exit;
      end if;
    end loop;

  elsif t = 'wager_cancel' then
    wid := p_action->>'id'; nm := p_action->>'by';
    for widx in 0 .. jsonb_array_length(wagers)-1 loop
      if wagers->widx->>'id' = wid and wagers->widx->>'status' = 'open' and wagers->widx->>'proposer' = nm then
        amt := coalesce((wagers->widx->>'amount')::int,0);
        for midx in 0 .. jsonb_array_length(members)-1 loop
          if members->midx->>'name' = nm then
            members := jsonb_set(members, array[midx::text], grove_adj(members->midx, amt));
            exit;
          end if;
        end loop;
        wagers := wagers - widx;
        exit;
      end if;
    end loop;

  elsif t = 'wager_dispute' then
    wid := p_action->>'id'; nm := p_action->>'by';
    for widx in 0 .. jsonb_array_length(wagers)-1 loop
      if wagers->widx->>'id' = wid and wagers->widx->>'status' = 'matched'
         and (wagers->widx->>'proposer' = nm or wagers->widx->>'taker' = nm) then
        wagers := jsonb_set(jsonb_set(wagers, array[widx::text,'status'], to_jsonb('disputed'::text)), array[widx::text,'disputeAt'], to_jsonb(nowe));
        exit;
      end if;
    end loop;

  elsif t = 'wager_concede' then
    wid := p_action->>'id'; nm := p_action->>'name';
    for widx in 0 .. jsonb_array_length(wagers)-1 loop
      if wagers->widx->>'id' = wid and (wagers->widx->>'status' = 'matched' or wagers->widx->>'status' = 'disputed')
         and (wagers->widx->>'proposer' = nm or wagers->widx->>'taker' = nm) then
        amt := coalesce((wagers->widx->>'amount')::int,0);
        if wagers->widx->>'proposer' = nm then win := wagers->widx->>'taker'; else win := wagers->widx->>'proposer'; end if;
        for midx in 0 .. jsonb_array_length(members)-1 loop
          if members->midx->>'name' = win then
            members := jsonb_set(members, array[midx::text], grove_adj((members->midx) - 'winMult', amt * (1 + coalesce((members->midx->>'winMult')::int,1))));
            if random() < least(1.0, amt::numeric/100.0) then
              members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{logs}', to_jsonb(coalesce((members->midx->>'logs')::int,0)+1)));
            end if;
            exit;
          end if;
        end loop;
        wagers := jsonb_set(wagers, array[widx::text], jsonb_set(jsonb_set(wagers->widx,'{status}', to_jsonb('settled'::text)),'{winner}', to_jsonb(win)));
        exit;
      end if;
    end loop;

  elsif t = 'wager_vote' then
    wid := p_action->>'id'; nm := p_action->>'voter';
    for widx in 0 .. jsonb_array_length(wagers)-1 loop
      if wagers->widx->>'id' = wid and wagers->widx->>'status' = 'disputed'
         and (p_action->>'side' = 'proposer' or p_action->>'side' = 'taker')
         and not (coalesce(wagers->widx->'votes','{}'::jsonb) ? nm) and wagers->widx->>'proposer' <> nm and wagers->widx->>'taker' <> nm then
        wagers := jsonb_set(wagers, array[widx::text,'votes'], coalesce(wagers->widx->'votes','{}'::jsonb) || jsonb_build_object(nm, p_action->>'side'), true);
        select count(*) into cnt from jsonb_each_text(wagers->widx->'votes') as e(k,v) where e.v = 'proposer';
        select count(*) into i   from jsonb_each_text(wagers->widx->'votes') as e(k,v) where e.v = 'taker';
        if cnt >= 5 or i >= 5 then
          amt := coalesce((wagers->widx->>'amount')::int,0);
          if cnt >= 5 then win := wagers->widx->>'proposer'; else win := wagers->widx->>'taker'; end if;
          for midx in 0 .. jsonb_array_length(members)-1 loop
            if members->midx->>'name' = win then
              members := jsonb_set(members, array[midx::text], grove_adj((members->midx) - 'winMult', amt * (1 + coalesce((members->midx->>'winMult')::int,1))));
            if random() < least(1.0, amt::numeric/100.0) then
              members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{logs}', to_jsonb(coalesce((members->midx->>'logs')::int,0)+1)));
            end if;
              exit;
            end if;
          end loop;
          wagers := jsonb_set(wagers, array[widx::text], jsonb_set(jsonb_set(wagers->widx,'{status}', to_jsonb('settled'::text)),'{winner}', to_jsonb(win)));
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'wager_tie' then
    wid := p_action->>'id'; nm := p_action->>'name';
    for widx in 0 .. jsonb_array_length(wagers)-1 loop
      if wagers->widx->>'id' = wid and (wagers->widx->>'status' = 'matched' or wagers->widx->>'status' = 'disputed')
         and (wagers->widx->>'proposer' = nm or wagers->widx->>'taker' = nm) then
        if not (coalesce(wagers->widx->'tie','[]'::jsonb) @> to_jsonb(nm)) then
          wagers := jsonb_set(wagers, array[widx::text,'tie'], coalesce(wagers->widx->'tie','[]'::jsonb) || to_jsonb(nm), true);
        end if;
        if (wagers->widx->'tie' @> to_jsonb(wagers->widx->>'proposer')) and (wagers->widx->'tie' @> to_jsonb(wagers->widx->>'taker')) then
          amt := coalesce((wagers->widx->>'amount')::int,0);
          for midx in 0 .. jsonb_array_length(members)-1 loop
            if members->midx->>'name' = wagers->widx->>'proposer' or members->midx->>'name' = wagers->widx->>'taker' then
              members := jsonb_set(members, array[midx::text], grove_adj(members->midx, amt));
            end if;
          end loop;
          wagers := jsonb_set(wagers, array[widx::text], jsonb_set(jsonb_set(wagers->widx,'{status}', to_jsonb('settled'::text)),'{winner}', to_jsonb('tie'::text)));
        end if;
        exit;
      end if;
    end loop;

  -- legacy 50-stake wheel (superseded by grove_wheel(); no longer called by the client)
  elsif t = 'wheel_spin' then
    nm := p_action->>'name';
    for midx in 0 .. jsonb_array_length(members)-1 loop
      if members->midx->>'name' = nm then
        if coalesce((members->midx->>'lastSpin')::double precision,0) + 7200 <= nowe
           and coalesce((members->midx->>'points')::int,0) >= 50 then
          members := jsonb_set(members, array[midx::text], grove_adj(members->midx, -50));
          members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{lastSpin}', to_jsonb(nowe)));
          o := grove_wheel_pick();
          sp := o->>'special';
          if sp = 'free' then
            members := jsonb_set(members, array[midx::text], grove_adj(members->midx, 50));
            members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{lastSpin}', to_jsonb(0)));
          elsif sp = 'x2' then
            members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{winMult}', to_jsonb(2)));
          elsif sp = 'x3' then
            members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{winMult}', to_jsonb(3)));
          elsif sp = 'x2neg' then
            members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{lossMult}', to_jsonb(2)));
          else
            spv := coalesce((o->>'pts')::int,0);
            members := jsonb_set(members, array[midx::text], grove_adj(members->midx, spv));
            if spv > 0 and random() < least(1.0, spv::numeric/100.0) then
              members := jsonb_set(members, array[midx::text], jsonb_set(members->midx,'{logs}', to_jsonb(coalesce((members->midx->>'logs')::int,0)+1)));
            end if;
          end if;
        end if;
        exit;
      end if;
    end loop;

  -- ============ GROUP WAGERS ============
  elsif t = 'group_new' then
    nm := p_action->>'starter'; gstake := least(100, greatest(1, coalesce((p_action->>'stake')::int,0))); gside := p_action->>'side';
    if (gside = 'A' or gside = 'B') and grove_pts(members, nm) >= gstake then
      members := grove_credit(members, nm, -gstake);
      g := jsonb_build_object(
        'id', 'g'||substr(md5(random()::text||clock_timestamp()::text),1,12),
        'starter', nm, 'title', p_action->>'title', 'stake', gstake,
        'sideA', case when gside='A' then jsonb_build_array(nm) else '[]'::jsonb end,
        'sideB', case when gside='B' then jsonb_build_array(nm) else '[]'::jsonb end,
        'status', 'pending', 'created', nowe, 'lockedAt', null::double precision,
        'claims', '{}'::jsonb, 'votes', '{}'::jsonb, 'winner', null::text);
      groups := groups || jsonb_build_array(g);
    end if;

  elsif t = 'group_join' then
    gid := p_action->>'id'; nm := p_action->>'name'; gside := p_action->>'side';
    for gidx in 0 .. jsonb_array_length(groups)-1 loop
      if groups->gidx->>'id' = gid and groups->gidx->>'status' = 'pending' and (gside='A' or gside='B') then
        g := groups->gidx; sidearr := coalesce(g->('side'||gside), '[]'::jsonb);
        if not (coalesce(g->'sideA','[]'::jsonb) @> to_jsonb(nm) or coalesce(g->'sideB','[]'::jsonb) @> to_jsonb(nm))
           and jsonb_array_length(sidearr) < 6
           and grove_pts(members, nm) >= coalesce((g->>'stake')::int,0) then
          members := grove_credit(members, nm, -coalesce((g->>'stake')::int,0));
          g := jsonb_set(g, array['side'||gside], sidearr || to_jsonb(nm));
          groups := jsonb_set(groups, array[gidx::text], g);
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'group_leave' then
    gid := p_action->>'id'; nm := p_action->>'name';
    for gidx in 0 .. jsonb_array_length(groups)-1 loop
      if groups->gidx->>'id' = gid and groups->gidx->>'status' = 'pending' then
        g := groups->gidx;
        if nm <> coalesce(g->>'starter','') and (coalesce(g->'sideA','[]'::jsonb) @> to_jsonb(nm) or coalesce(g->'sideB','[]'::jsonb) @> to_jsonb(nm)) then
          members := grove_credit(members, nm, coalesce((g->>'stake')::int,0));
          g := jsonb_set(g, '{sideA}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(g->'sideA','[]'::jsonb)) x where x <> to_jsonb(nm)),'[]'::jsonb));
          g := jsonb_set(g, '{sideB}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(g->'sideB','[]'::jsonb)) x where x <> to_jsonb(nm)),'[]'::jsonb));
          groups := jsonb_set(groups, array[gidx::text], g);
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'group_revoke' then
    gid := p_action->>'id'; nm := p_action->>'by';
    for gidx in 0 .. jsonb_array_length(groups)-1 loop
      if groups->gidx->>'id' = gid and groups->gidx->>'status' = 'pending' and groups->gidx->>'starter' = nm then
        g := groups->gidx; gstake := coalesce((g->>'stake')::int,0);
        for i in 0 .. jsonb_array_length(coalesce(g->'sideA','[]'::jsonb))-1 loop members := grove_credit(members, g->'sideA'->>i, gstake); end loop;
        for i in 0 .. jsonb_array_length(coalesce(g->'sideB','[]'::jsonb))-1 loop members := grove_credit(members, g->'sideB'->>i, gstake); end loop;
        groups := coalesce((select jsonb_agg(x) from jsonb_array_elements(groups) x where x->>'id' <> gid),'[]'::jsonb);
        exit;
      end if;
    end loop;

  elsif t = 'group_lock' then
    gid := p_action->>'id'; nm := p_action->>'by';
    for gidx in 0 .. jsonb_array_length(groups)-1 loop
      if groups->gidx->>'id' = gid and groups->gidx->>'status' = 'pending' and groups->gidx->>'starter' = nm then
        g := groups->gidx;
        if jsonb_array_length(coalesce(g->'sideA','[]'::jsonb)) >= 1 and jsonb_array_length(coalesce(g->'sideB','[]'::jsonb)) >= 1 then
          groups := jsonb_set(jsonb_set(groups, array[gidx::text,'status'], to_jsonb('active'::text)), array[gidx::text,'lockedAt'], to_jsonb(nowe));
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'group_claim' then
    gid := p_action->>'id'; nm := p_action->>'name'; gside := p_action->>'side';
    for gidx in 0 .. jsonb_array_length(groups)-1 loop
      if groups->gidx->>'id' = gid and groups->gidx->>'status' = 'active' and (gside='A' or gside='B') then
        g := groups->gidx;
        if coalesce(g->'sideA','[]'::jsonb) @> to_jsonb(nm) or coalesce(g->'sideB','[]'::jsonb) @> to_jsonb(nm) then
          g := jsonb_set(g, array['claims', nm], to_jsonb(gside));
          totalp := jsonb_array_length(coalesce(g->'sideA','[]'::jsonb)) + jsonb_array_length(coalesce(g->'sideB','[]'::jsonb));
          ccount := (select count(*) from jsonb_object_keys(g->'claims'));
          if ccount >= totalp then
            cdist := (select count(distinct value) from jsonb_each_text(g->'claims'));
            if cdist = 1 then
              gwin := (select value from jsonb_each_text(g->'claims') limit 1);
              totalp := jsonb_array_length(coalesce(g->'sideA','[]'::jsonb)) + jsonb_array_length(coalesce(g->'sideB','[]'::jsonb));
              gpot := coalesce((g->>'stake')::int,0) * totalp;
              sidearr := coalesce(g->('side'||gwin),'[]'::jsonb);
              if jsonb_array_length(sidearr) > 0 then
                gshare := (gpot / jsonb_array_length(sidearr))::int;
                for i in 0 .. jsonb_array_length(sidearr)-1 loop members := grove_credit(members, sidearr->>i, gshare + (case when i < (gpot - gshare * jsonb_array_length(sidearr)) then 1 else 0 end)); end loop;
              end if;
              g := jsonb_set(jsonb_set(g,'{winner}',to_jsonb(gwin)),'{status}',to_jsonb('settled'::text));
            else
              g := jsonb_set(jsonb_set(g,'{status}',to_jsonb('disputed'::text)),'{disputeAt}',to_jsonb(nowe));
            end if;
          end if;
          groups := jsonb_set(groups, array[gidx::text], g);
        end if;
        exit;
      end if;
    end loop;

  elsif t = 'group_vote' then
    gid := p_action->>'id'; nm := p_action->>'voter'; gside := p_action->>'side';
    for gidx in 0 .. jsonb_array_length(groups)-1 loop
      if groups->gidx->>'id' = gid and groups->gidx->>'status' = 'disputed' and (gside='A' or gside='B') then
        g := groups->gidx;
        if not (coalesce(g->'sideA','[]'::jsonb) @> to_jsonb(nm) or coalesce(g->'sideB','[]'::jsonb) @> to_jsonb(nm))
           and not (coalesce(g->'votes','{}'::jsonb) ? nm) then
          g := jsonb_set(g, array['votes', nm], to_jsonb(gside));
          gav := (select count(*) from jsonb_each_text(g->'votes') where value = 'A');
          gbv := (select count(*) from jsonb_each_text(g->'votes') where value = 'B');
          if (gav >= 5 or gbv >= 5) and gav <> gbv then
            gwin := case when gav > gbv then 'A' else 'B' end;
            totalp := jsonb_array_length(coalesce(g->'sideA','[]'::jsonb)) + jsonb_array_length(coalesce(g->'sideB','[]'::jsonb));
            gpot := coalesce((g->>'stake')::int,0) * totalp;
            sidearr := coalesce(g->('side'||gwin),'[]'::jsonb);
            if jsonb_array_length(sidearr) > 0 then
              gshare := (gpot / jsonb_array_length(sidearr))::int;
              for i in 0 .. jsonb_array_length(sidearr)-1 loop members := grove_credit(members, sidearr->>i, gshare + (case when i < (gpot - gshare * jsonb_array_length(sidearr)) then 1 else 0 end)); end loop;
            end if;
            g := jsonb_set(jsonb_set(g,'{winner}',to_jsonb(gwin)),'{status}',to_jsonb('settled'::text));
          end if;
          groups := jsonb_set(groups, array[gidx::text], g);
        end if;
        exit;
      end if;
    end loop;
  end if;

  d := jsonb_set(d, '{members}',    members);
  d := jsonb_set(d, '{challenges}', chals);
  d := jsonb_set(d, '{wagers}',     wagers);
  d := jsonb_set(d, '{groups}',     groups);
  update public.grove_state set data = d, updated_at = now() where id = 1;
  return d;
end; $$;

-- ---------------------------------------------------------------------------
--  The Chalice (party mini-game): state blob + idempotent end-of-game commit
-- ---------------------------------------------------------------------------
create or replace function public.grove_chalice(p_action jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d jsonb; members jsonb; cm jsonb; m jsonb; hist jsonb; ch jsonb; bdg jsonb;
  nm text; delta int; games int; drained int; i int; idx int; nowe double precision;
  v_gid text;
begin
  select data into d from public.grove_state where id = 1 for update;
  if d is null then raise exception 'grove not seeded'; end if;
  nowe := extract(epoch from now());

  d := jsonb_set(d, '{chalice}', coalesce(p_action->'state', 'null'::jsonb), true);
  v_gid := coalesce(p_action->'state'->>'gid', '');

  -- end-of-game commit: each participant gets a Chalice aggregate, Devotion delta
  -- and (if drained) a badge. Idempotency guard on gid stops offline-replay/double-end.
  if p_action ? 'commit'
     and not (v_gid <> '' and coalesce(d->>'chalCommitGid','') = v_gid) then
    members := coalesce(d->'members','[]'::jsonb);
    for i in 0 .. coalesce(jsonb_array_length(p_action->'commit'),0) - 1 loop
      cm := p_action->'commit'->i;
      nm := cm->>'name';
      delta := greatest(-500, least(500, coalesce((cm->>'delta')::int, 0)));
      games := coalesce((cm->>'games')::int, 1);
      drained := coalesce((cm->>'drained')::int, 0);
      for idx in 0 .. jsonb_array_length(members) - 1 loop
        if members->idx->>'name' = nm then
          m := members->idx;
          if delta > 0 and coalesce((m->>'winMult')::int,1) > 1 then
            delta := delta * coalesce((m->>'winMult')::int,1);
            m := m - 'winMult';
          end if;
          m := jsonb_set(m, '{points}', to_jsonb(greatest(0, coalesce((m->>'points')::int,0) + delta)));
          m := jsonb_set(m, '{season}', to_jsonb(greatest(0, coalesce((m->>'season')::int,0) + delta)));
          ch := coalesce(m->'chalice', '{"total":0,"games":0,"drained":0}'::jsonb);
          ch := jsonb_set(ch, '{total}',   to_jsonb(coalesce((ch->>'total')::int,0)   + delta));
          ch := jsonb_set(ch, '{games}',   to_jsonb(coalesce((ch->>'games')::int,0)   + games));
          if drained <> 0 then
            ch := jsonb_set(ch, '{drained}', to_jsonb(coalesce((ch->>'drained')::int,0) + 1));
          end if;
          m := jsonb_set(m, '{chalice}', ch, true);
          if delta <> 0 then
            hist := coalesce(m->'history','[]'::jsonb)
                 || jsonb_build_array(jsonb_build_object('t', nowe, 'd', delta, 'l', 'Trial of the Chalice'));
            m := jsonb_set(m, '{history}', hist);
          end if;
          if drained <> 0 then
            bdg := coalesce(m->'badges','[]'::jsonb);
            if not (bdg @> '["Drained the Chalice"]'::jsonb) then
              bdg := bdg || '["Drained the Chalice"]'::jsonb;
            end if;
            m := jsonb_set(m, '{badges}', bdg, true);
          end if;
          members := jsonb_set(members, array[idx::text], m);
          exit;
        end if;
      end loop;
    end loop;
    d := jsonb_set(d, '{members}', members);
    if v_gid <> '' then
      d := jsonb_set(d, '{chalCommitGid}', to_jsonb(v_gid));
    end if;
  end if;

  update public.grove_state set data = d, updated_at = now() where id = 1;
  return d;
end; $$;

-- background sweeper for the Chalice turn/lobby timers (call from a cron/edge fn)
create or replace function public.grove_chalice_sweep()
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare
  d jsonb; ch jsonb; nowe double precision := extract(epoch from now());
  status text; phase text; L int; turn int; drawer text; ri int;
  is_slow boolean; timed_out boolean; drawer_away boolean;
  k int; cand int; newturn int := -1; s text; dl double precision; feed jsonb; lbl text;
begin
  select data into d from public.grove_state where id=1;
  if d is null then return; end if;
  ch := d->'chalice';
  if ch is null or jsonb_typeof(ch) <> 'object' then return; end if;
  status := ch->>'status';

  if status = 'lobby' then
    if coalesce((ch->>'lobbyAt')::double precision, nowe) + 900 <= nowe then
      ch := jsonb_set(ch, '{status}', to_jsonb('idle'::text));
      d  := jsonb_set(d, '{chalice}', ch);
      update public.grove_state set data=d, updated_at=now() where id=1;
    end if;
    return;
  end if;

  if status <> 'playing' then return; end if;

  phase := ch->>'phase';
  L := jsonb_array_length(coalesce(ch->'spirits','[]'::jsonb));
  if L = 0 then return; end if;
  turn := coalesce((ch->>'turn')::int, 0);
  if turn < 0 or turn >= L then turn := 0; end if;
  drawer := ch->'spirits'->>turn;

  ri := case when ch->'current' is not null and ch->'current' <> 'null'::jsonb
             then coalesce((ch->'current'->>'ri')::int, -1) else -1 end;
  is_slow := ri in (0,8,9);   -- Cascade / Incantation / Litany have no time limit
  dl := (ch->>'deadline')::double precision;

  timed_out  := phase in ('draw','resolve','confirm')
                and dl is not null and dl > 0 and dl < nowe and not is_slow;
  drawer_away := phase = 'draw'
                and ((coalesce(ch->'away','{}'::jsonb) ? drawer) or (coalesce(ch->'kicked','{}'::jsonb) ? drawer));

  if not (timed_out or drawer_away) then return; end if;

  for k in 1 .. L loop
    cand := (turn + k) % L;
    s := ch->'spirits'->>cand;
    if not ((coalesce(ch->'away','{}'::jsonb) ? s) or (coalesce(ch->'kicked','{}'::jsonb) ? s)) then
      newturn := cand; exit;
    end if;
  end loop;
  if newturn < 0 then return; end if;

  lbl := coalesce(drawer,'A spirit') || '’s turn ran out — the Eye moves on.';
  feed := (select coalesce(jsonb_agg(e order by ord),'[]'::jsonb)
           from jsonb_array_elements(
             jsonb_build_array(jsonb_build_object('t', floor(nowe), 'x', lbl))
             || coalesce(ch->'feed','[]'::jsonb)
           ) with ordinality as t(e, ord)
           where ord <= 30);

  ch := jsonb_set(ch, '{turn}',     to_jsonb(newturn));
  ch := jsonb_set(ch, '{phase}',    to_jsonb('draw'::text));
  ch := jsonb_set(ch, '{current}',  'null'::jsonb);
  ch := jsonb_set(ch, '{deadline}', to_jsonb(floor(nowe) + 120));
  ch := jsonb_set(ch, '{feed}',     feed);
  d  := jsonb_set(d, '{chalice}', ch);
  update public.grove_state set data=d, updated_at=now() where id=1;
end; $$;

-- ---------------------------------------------------------------------------
--  Version stamp — client compares against EXPECTED_DB and warns if older
-- ---------------------------------------------------------------------------
create or replace function public.grove_ver()
 returns text language sql set search_path to 'public','pg_temp'
as $$ select '2026-07-02a'::text; $$;

-- ---------------------------------------------------------------------------
--  Grants — the public PWA calls every RPC with the anon key
-- ---------------------------------------------------------------------------
grant execute on function
  public.grove_adj(jsonb,integer),
  public.grove_credit(jsonb,text,integer),
  public.grove_hist(jsonb,text,integer,double precision),
  public.grove_pts(jsonb,text),
  public.grove_rmbadge(jsonb,text),
  public.grove_seed(jsonb),
  public.grove_check(text),
  public.grove_setpass(text,text),
  public.grove_save(text,jsonb),
  public.grove_save(text,jsonb,text),
  public.grove_set_chibi(text,jsonb),
  public.grove_push_save(text,jsonb),
  public.grove_push_del(text),
  public.grove_propose(jsonb),
  public.grove_vote(text,text),
  public.grove_withdraw(text,text),
  public.grove_clear_rites(text),
  public.grove_remove_rite(text,text),
  public.grove_thought(text,text),
  public.grove_wheel_pick(),
  public.grove_wheel(text),
  public.grove_action(jsonb),
  public.grove_chalice(jsonb),
  public.grove_chalice_sweep(),
  public.grove_ver()
to anon, authenticated;
