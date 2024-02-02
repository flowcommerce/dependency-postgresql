-- Drop the function first, can't replace it because the signature changed.
-- Can't assume the function exists either (e.g., tokendb doesn't have it).
DROP FUNCTION IF EXISTS journal.quote_column;
CREATE FUNCTION journal.quote_column(name information_schema.sql_identifier)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
begin
  return '"' || name || '"';
end;
$function$
