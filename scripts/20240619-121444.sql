-- Make refresh_journaling delegate to refresh_journaling_native. We
-- need to keep both for the moment because of references from Scala
-- code, e.g., in lib-event-relation-mapper's TableSchemaManager.
CREATE OR REPLACE FUNCTION journal.refresh_journaling(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying)
 RETURNS character varying
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN journal.refresh_journaling_native(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name);
END;
$function$;

DROP FUNCTION IF EXISTS audit.setup;
DROP FUNCTION IF EXISTS queue.create_queue;
DROP FUNCTION IF EXISTS kinesis.create_kinesis_tables;
DROP FUNCTION IF EXISTS kinesis.partition_n_days;

-- Remove all _trig_func functions that were invoked by partitioning triggers.
DO LANGUAGE plpgsql $$
DECLARE r record;
BEGIN
	FOR r IN SELECT routine_schema, routine_name from information_schema.routines where routine_name like '%_part_trig_func'
	LOOP
		EXECUTE 'DROP FUNCTION ' || quote_ident(r.routine_schema) || '.' || quote_ident(r.routine_name);
	END LOOP;
END;
$$;

