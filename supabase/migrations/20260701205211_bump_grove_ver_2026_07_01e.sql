-- Stamp the schema version after the agent-audit hardening (chalice cap, FOR UPDATE rollout,
-- server-side devotion, self-nomination rules, grove_save optimistic concurrency).
CREATE OR REPLACE FUNCTION public.grove_ver()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$ select '2026-07-01e'::text; $function$;
