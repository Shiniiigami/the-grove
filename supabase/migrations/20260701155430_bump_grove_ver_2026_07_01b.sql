-- Stamp the schema version after the target-validation + row-locking hardening.
CREATE OR REPLACE FUNCTION public.grove_ver()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$ select '2026-07-01b'::text; $function$;
