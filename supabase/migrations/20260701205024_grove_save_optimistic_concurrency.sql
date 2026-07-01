-- #2 grove_save was a blind full-blob upsert: a keeper saving a stale snapshot could revert
-- everyone's concurrent activity. Add optimistic concurrency — the caller passes the
-- updated_at it last read (p_expected); if the row changed since, reject so the client reloads.
-- Fail-open (no token => no guard) keeps older clients working. Returns the new updated_at so
-- the client can refresh its token after a successful save.
CREATE OR REPLACE FUNCTION public.grove_save(p_pass text, p_data jsonb, p_expected text default null)
 RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
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
end; $function$;
