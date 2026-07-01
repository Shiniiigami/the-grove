-- Stamp the schema version after the wager-dispute refund + stoke-cooldown fixes.
CREATE OR REPLACE FUNCTION public.grove_ver()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$ select '2026-07-01c'::text; $function$;
