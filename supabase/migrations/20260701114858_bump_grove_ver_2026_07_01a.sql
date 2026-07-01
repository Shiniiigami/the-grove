-- Stamp the schema version so clients know the offering/nominator parity update landed.
CREATE OR REPLACE FUNCTION public.grove_ver()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$ select '2026-07-01a'::text; $function$;
