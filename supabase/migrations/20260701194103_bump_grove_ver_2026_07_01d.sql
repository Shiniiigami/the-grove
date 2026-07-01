-- Stamp the schema version after the forfeit-restore, fire-decay parity, and blessing-scope work.
CREATE OR REPLACE FUNCTION public.grove_ver()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$ select '2026-07-01d'::text; $function$;
