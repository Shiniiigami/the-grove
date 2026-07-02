-- Stamp the schema version after the chibi shape-validation + cheat-guard-145 fixes.
CREATE OR REPLACE FUNCTION public.grove_ver()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$ select '2026-07-01g'::text; $function$;
