--
-- PostgreSQL database dump
--

-- Dumped from database version 15.5
-- Dumped by pg_dump version 15.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: audit; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA audit;


ALTER SCHEMA audit OWNER TO api;

--
-- Name: journal; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA journal;


ALTER SCHEMA journal OWNER TO api;

--
-- Name: partman5; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA partman5;


ALTER SCHEMA partman5 OWNER TO api;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: root
--

-- *not* creating schema, since initdb creates it



--
-- Name: queue; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA queue;


ALTER SCHEMA queue OWNER TO api;

--
-- Name: schema_evolution_manager; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA schema_evolution_manager;


ALTER SCHEMA schema_evolution_manager OWNER TO api;

--
-- Name: util; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA util;


ALTER SCHEMA util OWNER TO api;

--
-- Name: vividcortex; Type: SCHEMA; Schema: -; Owner: vividcortex
--

CREATE SCHEMA vividcortex;



--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';


--
-- Name: check_default_table; Type: TYPE; Schema: partman5; Owner: api
--

CREATE TYPE partman5.check_default_table AS (
	default_table text,
	count bigint
);


ALTER TYPE partman5.check_default_table OWNER TO api;

--
-- Name: setup(text, text, text, text); Type: FUNCTION; Schema: audit; Owner: api
--

CREATE FUNCTION audit.setup(p_schema_name text, p_table_name text, p_journal_schema_name text DEFAULT 'journal'::text, p_journal_table_name text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
  v_journal_table_name text;
begin
  v_journal_table_name = coalesce(p_journal_table_name, p_table_name);

  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add created_at timestamptz default now() not null';
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add updated_by_user_id text not null';

  -- add journaling to this table
  perform journal.refresh_journaling(p_schema_name, p_table_name, p_journal_schema_name, v_journal_table_name);

  -- add partition management to journal table
  -- this will create 1 current, 4 past, and 4 future monthly time-based partitions for journal.table_name
  perform partman.create_parent(p_journal_schema_name || '.' || v_journal_table_name, 'journal_timestamp', 'time', 'monthly');
end;
$$;


ALTER FUNCTION audit.setup(p_schema_name text, p_table_name text, p_journal_schema_name text, p_journal_table_name text) OWNER TO api;

--
-- Name: add_primary_key_data(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.add_primary_key_data(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
  v_name text;
  v_columns character varying := '';
begin
  for v_name in (select * from journal.primary_key_columns(p_source_schema_name, p_source_table_name)) loop
    if v_columns != '' then
      v_columns := v_columns || ', ';
    end if;
    v_columns := v_columns || v_name;
    execute 'alter table ' || p_target_schema_name || '.' || p_target_table_name || ' alter column ' || v_name || ' set not null';
  end loop;

  if v_columns != '' then
    execute 'create index on ' || p_target_schema_name || '.' || p_target_table_name || '(' || v_columns || ')';
  end if;

end;
$$;


ALTER FUNCTION journal.add_primary_key_data(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: authorizations_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.authorizations_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.authorizations (journal_operation, id, user_id, scms, token, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.scms, old.token, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.authorizations_delete() OWNER TO api;

--
-- Name: authorizations_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.authorizations_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.authorizations] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.authorizations]';  end if;  insert into journal.authorizations (journal_operation, id, user_id, scms, token, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.scms, new.token, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.authorizations_insert() OWNER TO api;

--
-- Name: authorizations_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.authorizations_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.authorizations_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.authorizations_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.authorizations_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.authorizations_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.authorizations_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2023-12-01 00:00:00+00' AND NEW.journal_timestamp < '2024-01-01 00:00:00+00' THEN
                INSERT INTO journal.authorizations_p2023_12 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.authorizations_p2024_06 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('authorizations', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.authorizations_part_trig_func() OWNER TO api;

--
-- Name: binaries_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.binaries_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.binaries (journal_operation, id, organization_id, name, created_at, updated_by_user_id) values (TG_OP, old.id, old.organization_id, old.name, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.binaries_delete() OWNER TO api;

--
-- Name: binaries_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.binaries_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.binaries] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.binaries]';  end if;  insert into journal.binaries (journal_operation, id, organization_id, name, created_at, updated_by_user_id) values (TG_OP, new.id, new.organization_id, new.name, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.binaries_insert() OWNER TO api;

--
-- Name: binaries_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.binaries_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.binaries_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.binaries_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.binaries_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.binaries_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.binaries_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('binaries', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.binaries_part_trig_func() OWNER TO api;

--
-- Name: binary_versions_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.binary_versions_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.binary_versions (journal_operation, id, binary_id, version, sort_key, created_at, updated_by_user_id) values (TG_OP, old.id, old.binary_id, old.version, old.sort_key, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.binary_versions_delete() OWNER TO api;

--
-- Name: binary_versions_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.binary_versions_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.binary_versions] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.binary_versions]';  end if;  insert into journal.binary_versions (journal_operation, id, binary_id, version, sort_key, created_at, updated_by_user_id) values (TG_OP, new.id, new.binary_id, new.version, new.sort_key, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.binary_versions_insert() OWNER TO api;

--
-- Name: binary_versions_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.binary_versions_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.binary_versions_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.binary_versions_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('binary_versions', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.binary_versions_part_trig_func() OWNER TO api;

--
-- Name: create_event_trigger(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.create_event_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
  v_journal_name text;
  v_source_name text;
  v_function_sql text;
  v_trigger_sql text;
begin
  v_journal_name = p_target_schema_name || '.' || p_target_table_name;
  v_source_name = p_source_schema_name || '.' || p_source_table_name;
  if exists(select 1 from information_schema.tables where table_schema = p_target_schema_name and table_name = p_target_table_name) then
    v_function_sql =                    'CREATE OR REPLACE FUNCTION refresh_' || p_source_table_name || '_journal() RETURNS event_trigger AS ''';
    v_function_sql := v_function_sql || ' declare ';
    v_function_sql := v_function_sql || ' r RECORD; ';
    v_function_sql := v_function_sql || ' func_exists boolean; ';
    v_function_sql := v_function_sql || 'BEGIN ';
    --for postgres 9.4 compatability, so we don't throw errors
    v_function_sql := v_function_sql || 'select exists(select * from pg_proc where proname = ''pg_event_trigger_ddl_commands'') into func_exists; ';
    v_function_sql := v_function_sql || 'IF func_exists THEN ';
    v_function_sql := v_function_sql || '  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP ';
    v_function_sql := v_function_sql || '    IF r.object_identity = ''' || v_source_name || ''' THEN ';
    v_function_sql := v_function_sql || '      perform journal.refresh_journaling(''' || p_source_schema_name || ''', ''' || p_source_table_name || ''', ''' || p_target_schema_name || ''', ''' || p_target_table_name ||'''); ';
    v_function_sql := v_function_sql || '    END IF; ';
    v_function_sql := v_function_sql || '  END LOOP; ';
    v_function_sql := v_function_sql || 'END IF; ';
    v_function_sql := v_function_sql || 'END; ';
    v_function_sql := v_function_sql || '''';
    v_function_sql := v_function_sql || 'LANGUAGE plpgsql;';

    v_trigger_sql =                   'CREATE EVENT TRIGGER tr_refresh_' || p_source_table_name || 'journal ';
    v_trigger_sql := v_trigger_sql || 'ON ddl_command_end WHEN TAG IN (''ALTER TABLE'') ';
    v_trigger_sql := v_trigger_sql || 'EXECUTE PROCEDURE refresh_' || p_source_table_name || '_journal(); ';

    perform v_function_sql;
    perform v_trigger_sql;

  else
		raise exception 'Unable to create journal event trigger for table without journaling. Use journal.create_journaling instead';
  end if;
end;
$$;


ALTER FUNCTION journal.create_event_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: create_journaling(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.create_journaling(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_journal_name varchar;
begin
	select journal.refresh_journaling(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name) into v_journal_name;
  perform journal.create_event_trigger(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name);
	return v_journal_name;
end;
$$;


ALTER FUNCTION journal.create_journaling(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: create_prevent_delete_trigger(character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.create_prevent_delete_trigger(p_schema_name character varying, p_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_name varchar;
begin
  v_name = p_table_name || '_prevent_delete_trigger';
  execute 'create trigger ' || v_name || ' before delete on ' || p_schema_name || '.' || p_table_name || ' for each row execute procedure journal.prevent_delete()';
  return v_name;
end;
$$;


ALTER FUNCTION journal.create_prevent_delete_trigger(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_prevent_update_trigger(character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.create_prevent_update_trigger(p_schema_name character varying, p_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_name varchar;
begin
  v_name = p_table_name || '_prevent_update_trigger';
  execute 'create trigger ' || v_name || ' before update on ' || p_schema_name || '.' || p_table_name || ' for each row execute procedure journal.prevent_update()';
  return v_name;
end;
$$;


ALTER FUNCTION journal.create_prevent_update_trigger(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: get_data_type_string(information_schema.columns); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.get_data_type_string(p_column information_schema.columns) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
begin
  return case p_column.data_type
    when 'character' then 'text'
    when 'character varying' then 'text'
    when '"char"' then 'text'
    else p_column.data_type
    end;
end;
$$;


ALTER FUNCTION journal.get_data_type_string(p_column information_schema.columns) OWNER TO api;

--
-- Name: get_deleted_by_user_id(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.get_deleted_by_user_id() RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_result varchar;
begin
  -- will throw exception if not set:
  -- 'unrecognized configuration parameter "journal.deleted_by_user_id"
  select current_setting('journal.deleted_by_user_id') into v_result;
  return v_result;
exception when others then
  -- throw a better error message
  RAISE EXCEPTION 'journal.deleted_by_user_id is not set, Please use util.delete_by_id';
end;
$$;


ALTER FUNCTION journal.get_deleted_by_user_id() OWNER TO api;

--
-- Name: github_users_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.github_users_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.github_users (journal_operation, id, user_id, github_user_id, login, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.github_user_id, old.login, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.github_users_delete() OWNER TO api;

--
-- Name: github_users_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.github_users_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.github_users] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.github_users]';  end if;  insert into journal.github_users (journal_operation, id, user_id, github_user_id, login, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.github_user_id, new.login, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.github_users_insert() OWNER TO api;

--
-- Name: github_users_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.github_users_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.github_users_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.github_users_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.github_users_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.github_users_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.github_users_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('github_users', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.github_users_part_trig_func() OWNER TO api;

--
-- Name: items_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.items_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.items (journal_operation, id, organization_id, visibility, object_id, label, description, summary, contents, created_at, updated_by_user_id) values (TG_OP, old.id, old.organization_id, old.visibility, old.object_id, old.label, old.description, old.summary, old.contents, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.items_delete() OWNER TO api;

--
-- Name: items_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.items_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.items] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.items]';  end if;  insert into journal.items (journal_operation, id, organization_id, visibility, object_id, label, description, summary, contents, created_at, updated_by_user_id) values (TG_OP, new.id, new.organization_id, new.visibility, new.object_id, new.label, new.description, new.summary, new.contents, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.items_insert() OWNER TO api;

--
-- Name: items_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.items_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2016-08-01 00:00:00+00' AND NEW.journal_timestamp < '2016-09-01 00:00:00+00' THEN 
                INSERT INTO journal.items_p2016_08 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2016-07-01 00:00:00+00' AND NEW.journal_timestamp < '2016-08-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-09-01 00:00:00+00' AND NEW.journal_timestamp < '2016-10-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_09 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-06-01 00:00:00+00' AND NEW.journal_timestamp < '2016-07-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-10-01 00:00:00+00' AND NEW.journal_timestamp < '2016-11-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_10 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-05-01 00:00:00+00' AND NEW.journal_timestamp < '2016-06-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-11-01 00:00:00+00' AND NEW.journal_timestamp < '2016-12-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_11 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-04-01 00:00:00+00' AND NEW.journal_timestamp < '2016-05-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2016-12-01 00:00:00+00' AND NEW.journal_timestamp < '2017-01-01 00:00:00+00' THEN
                INSERT INTO journal.items_p2016_12 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('items', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.items_part_trig_func() OWNER TO api;

--
-- Name: last_emails_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.last_emails_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.last_emails (journal_operation, id, user_id, publication, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.publication, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.last_emails_delete() OWNER TO api;

--
-- Name: last_emails_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.last_emails_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.last_emails] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.last_emails]';  end if;  insert into journal.last_emails (journal_operation, id, user_id, publication, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.publication, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.last_emails_insert() OWNER TO api;

--
-- Name: last_emails_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.last_emails_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.last_emails_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.last_emails_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('last_emails', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.last_emails_part_trig_func() OWNER TO api;

--
-- Name: libraries_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.libraries_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.libraries (journal_operation, id, organization_id, group_id, artifact_id, resolver_id, created_at, updated_by_user_id) values (TG_OP, old.id, old.organization_id, old.group_id, old.artifact_id, old.resolver_id, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.libraries_delete() OWNER TO api;

--
-- Name: libraries_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.libraries_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.libraries] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.libraries]';  end if;  insert into journal.libraries (journal_operation, id, organization_id, group_id, artifact_id, resolver_id, created_at, updated_by_user_id) values (TG_OP, new.id, new.organization_id, new.group_id, new.artifact_id, new.resolver_id, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.libraries_insert() OWNER TO api;

--
-- Name: libraries_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.libraries_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.libraries_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.libraries_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('libraries', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.libraries_part_trig_func() OWNER TO api;

--
-- Name: library_versions_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.library_versions_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.library_versions (journal_operation, id, library_id, version, cross_build_version, sort_key, created_at, updated_by_user_id) values (TG_OP, old.id, old.library_id, old.version, old.cross_build_version, old.sort_key, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.library_versions_delete() OWNER TO api;

--
-- Name: library_versions_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.library_versions_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.library_versions] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.library_versions]';  end if;  insert into journal.library_versions (journal_operation, id, library_id, version, cross_build_version, sort_key, created_at, updated_by_user_id) values (TG_OP, new.id, new.library_id, new.version, new.cross_build_version, new.sort_key, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.library_versions_insert() OWNER TO api;

--
-- Name: library_versions_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.library_versions_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.library_versions_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.library_versions_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('library_versions', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.library_versions_part_trig_func() OWNER TO api;

--
-- Name: memberships_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.memberships_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.memberships (journal_operation, id, user_id, organization_id, role, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.organization_id, old.role, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.memberships_delete() OWNER TO api;

--
-- Name: memberships_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.memberships_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.memberships] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.memberships]';  end if;  insert into journal.memberships (journal_operation, id, user_id, organization_id, role, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.organization_id, new.role, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.memberships_insert() OWNER TO api;

--
-- Name: memberships_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.memberships_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.memberships_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.memberships_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('memberships', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.memberships_part_trig_func() OWNER TO api;

--
-- Name: organizations_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.organizations_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.organizations (journal_operation, id, user_id, key, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.key, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.organizations_delete() OWNER TO api;

--
-- Name: organizations_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.organizations_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.organizations] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.organizations]';  end if;  insert into journal.organizations (journal_operation, id, user_id, key, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.key, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.organizations_insert() OWNER TO api;

--
-- Name: organizations_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.organizations_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.organizations_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.organizations_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.organizations_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.organizations_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.organizations_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.organizations_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.organizations_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('organizations', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.organizations_part_trig_func() OWNER TO api;

--
-- Name: prevent_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.prevent_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  raise exception 'Physical deletes are not allowed on this table';
end;
$$;


ALTER FUNCTION journal.prevent_delete() OWNER TO api;

--
-- Name: prevent_update(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.prevent_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  raise exception 'Physical updates are not allowed on this table';
end;
$$;


ALTER FUNCTION journal.prevent_update() OWNER TO api;

--
-- Name: primary_key_columns(character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.primary_key_columns(p_schema_name character varying, p_table_name character varying) RETURNS SETOF text
    LANGUAGE plpgsql
    AS $$
declare
  row record;
begin
  for row in (
      select key_column_usage.column_name
        from information_schema.table_constraints
        join information_schema.key_column_usage
             on key_column_usage.table_name = table_constraints.table_name
            and key_column_usage.table_schema = table_constraints.table_schema
            and key_column_usage.constraint_name = table_constraints.constraint_name
       where table_constraints.constraint_type = 'PRIMARY KEY'
         and table_constraints.table_schema = p_schema_name
         and table_constraints.table_name = p_table_name
       order by coalesce(key_column_usage.position_in_unique_constraint, 0),
                coalesce(key_column_usage.ordinal_position, 0),
                key_column_usage.column_name
  ) loop
    return next row.column_name;
  end loop;
end;
$$;


ALTER FUNCTION journal.primary_key_columns(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: project_binaries_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.project_binaries_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.project_binaries (journal_operation, id, project_id, name, version, path, binary_id, created_at, updated_by_user_id) values (TG_OP, old.id, old.project_id, old.name, old.version, old.path, old.binary_id, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.project_binaries_delete() OWNER TO api;

--
-- Name: project_binaries_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.project_binaries_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.project_binaries] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.project_binaries]';  end if;  insert into journal.project_binaries (journal_operation, id, project_id, name, version, path, binary_id, created_at, updated_by_user_id) values (TG_OP, new.id, new.project_id, new.name, new.version, new.path, new.binary_id, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.project_binaries_insert() OWNER TO api;

--
-- Name: project_binaries_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.project_binaries_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.project_binaries_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.project_binaries_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('project_binaries', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.project_binaries_part_trig_func() OWNER TO api;

--
-- Name: project_libraries_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.project_libraries_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.project_libraries (journal_operation, id, project_id, group_id, artifact_id, version, cross_build_version, path, library_id, created_at, updated_by_user_id) values (TG_OP, old.id, old.project_id, old.group_id, old.artifact_id, old.version, old.cross_build_version, old.path, old.library_id, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.project_libraries_delete() OWNER TO api;

--
-- Name: project_libraries_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.project_libraries_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.project_libraries] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.project_libraries]';  end if;  insert into journal.project_libraries (journal_operation, id, project_id, group_id, artifact_id, version, cross_build_version, path, library_id, created_at, updated_by_user_id) values (TG_OP, new.id, new.project_id, new.group_id, new.artifact_id, new.version, new.cross_build_version, new.path, new.library_id, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.project_libraries_insert() OWNER TO api;

--
-- Name: project_libraries_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.project_libraries_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.project_libraries_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.project_libraries_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('project_libraries', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.project_libraries_part_trig_func() OWNER TO api;

--
-- Name: projects_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.projects_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.projects (journal_operation, id, organization_id, user_id, visibility, scms, name, uri, created_at, updated_by_user_id) values (TG_OP, old.id, old.organization_id, old.user_id, old.visibility, old.scms, old.name, old.uri, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.projects_delete() OWNER TO api;

--
-- Name: projects_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.projects_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.projects] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.projects]';  end if;  insert into journal.projects (journal_operation, id, organization_id, user_id, visibility, scms, name, uri, created_at, updated_by_user_id) values (TG_OP, new.id, new.organization_id, new.user_id, new.visibility, new.scms, new.name, new.uri, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.projects_insert() OWNER TO api;

--
-- Name: projects_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.projects_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.projects_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.projects_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.projects_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.projects_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.projects_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.projects_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.projects_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('projects', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.projects_part_trig_func() OWNER TO api;

--
-- Name: quote_column(information_schema.sql_identifier); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.quote_column(name information_schema.sql_identifier) RETURNS text
    LANGUAGE plpgsql
    AS $$
begin
  return '"' || name || '"';
end;
$$;


ALTER FUNCTION journal.quote_column(name information_schema.sql_identifier) OWNER TO api;

--
-- Name: recommendations_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.recommendations_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.recommendations (journal_operation, id, project_id, type, object_id, name, from_version, to_version, created_at, updated_by_user_id) values (TG_OP, old.id, old.project_id, old.type, old.object_id, old.name, old.from_version, old.to_version, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.recommendations_delete() OWNER TO api;

--
-- Name: recommendations_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.recommendations_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.recommendations] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.recommendations]';  end if;  insert into journal.recommendations (journal_operation, id, project_id, type, object_id, name, from_version, to_version, created_at, updated_by_user_id) values (TG_OP, new.id, new.project_id, new.type, new.object_id, new.name, new.from_version, new.to_version, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.recommendations_insert() OWNER TO api;

--
-- Name: recommendations_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.recommendations_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.recommendations_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.recommendations_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('recommendations', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.recommendations_part_trig_func() OWNER TO api;

--
-- Name: refresh_journal_delete_trigger(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.refresh_journal_delete_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  row record;
  v_journal_name text;
  v_source_name text;
  v_trigger_name text;
  v_sql text;
  v_target_sql text;
begin
  v_journal_name = p_target_schema_name || '.' || p_target_table_name;
  v_source_name = p_source_schema_name || '.' || p_source_table_name;
  v_trigger_name = p_target_table_name || '_journal_delete_trigger';
  -- create the function
  v_sql = 'create or replace function ' || v_journal_name || '_delete() returns trigger language plpgsql as ''';
  v_sql := v_sql || ' begin ';
  v_sql := v_sql || '  insert into ' || v_journal_name || ' (journal_operation';
  v_target_sql = 'TG_OP';

  for row in (select column_name from information_schema.columns where table_schema = p_source_schema_name and table_name = p_source_table_name order by ordinal_position) loop
    v_sql := v_sql || ', ' || journal.quote_column(row.column_name);
    v_target_sql := v_target_sql || ', old.' || journal.quote_column(row.column_name);
  end loop;

  v_sql := v_sql || ') values (' || v_target_sql || '); ';
  v_sql := v_sql || ' return null; end; ''';

  execute v_sql;

  -- create the trigger
  v_sql = 'drop trigger if exists ' || v_trigger_name || ' on ' || v_source_name || '; ' ||
          'create trigger ' || v_trigger_name || ' after delete on ' || v_source_name ||
          ' for each row execute procedure ' || v_journal_name || '_delete()';

  execute v_sql;

  return v_trigger_name;

end;
$$;


ALTER FUNCTION journal.refresh_journal_delete_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: refresh_journal_insert_trigger(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.refresh_journal_insert_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  row record;
  v_journal_name text;
  v_source_name text;
  v_trigger_name text;
  v_first boolean;
  v_sql text;
  v_target_sql text;
  v_name text;
begin
  v_journal_name = p_target_schema_name || '.' || p_target_table_name;
  v_source_name = p_source_schema_name || '.' || p_source_table_name;
  v_trigger_name = p_target_table_name || '_journal_insert_trigger';
  -- create the function
  v_sql = 'create or replace function ' || v_journal_name || '_insert() returns trigger language plpgsql as ''';
  v_sql := v_sql || ' begin ';

  for v_name in (select * from journal.primary_key_columns(p_source_schema_name, p_source_table_name)) loop
    v_sql := v_sql || '  if (TG_OP=''''UPDATE'''' and (old.' || v_name || ' != new.' || v_name || ')) then';
    v_sql := v_sql || '    raise exception ''''Table[' || v_source_name || '] is journaled. Updates to primary key column[' || v_name || '] are not supported as this would make it impossible to follow the history of this row in the journal table[' || v_journal_name || ']'''';';
    v_sql := v_sql || '  end if;';
  end loop;

  v_sql := v_sql || '  insert into ' || v_journal_name || ' (journal_operation';
  v_target_sql = 'TG_OP';

  for row in (select column_name from information_schema.columns where table_schema = p_source_schema_name and table_name = p_source_table_name order by ordinal_position) loop
    v_sql := v_sql || ', ' || journal.quote_column(row.column_name);
    v_target_sql := v_target_sql || ', new.' || journal.quote_column(row.column_name);
  end loop;

  v_sql := v_sql || ') values (' || v_target_sql || '); ';
  v_sql := v_sql || ' return null; end; ''';

  execute v_sql;

  -- create the trigger
  v_sql = 'drop trigger if exists ' || v_trigger_name || ' on ' || v_source_name || '; ' ||
          'create trigger ' || v_trigger_name || ' after insert or update on ' || v_source_name ||
          ' for each row execute procedure ' || v_journal_name || '_insert()';

  execute v_sql;

  return v_trigger_name;

end;
$$;


ALTER FUNCTION journal.refresh_journal_insert_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: refresh_journal_trigger(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.refresh_journal_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying DEFAULT 'journal'::character varying, p_target_table_name character varying DEFAULT NULL::character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_insert_trigger_name text;
  v_delete_trigger_name text;
begin
  v_insert_trigger_name := journal.refresh_journal_insert_trigger(p_source_schema_name, p_source_table_name, p_target_schema_name, coalesce(p_target_table_name, p_source_table_name));
  v_delete_trigger_name := journal.refresh_journal_delete_trigger(p_source_schema_name, p_source_table_name, p_target_schema_name, coalesce(p_target_table_name, p_source_table_name));

  return v_insert_trigger_name || ' ' || v_delete_trigger_name;
end;
$$;


ALTER FUNCTION journal.refresh_journal_trigger(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: refresh_journaling(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.refresh_journaling(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  row record;
  v_journal_name text;
  v_data_type character varying;
begin
  v_journal_name = p_target_schema_name || '.' || p_target_table_name;
  if exists(select 1 from information_schema.tables where table_schema = p_target_schema_name and table_name = p_target_table_name) then
    for row in (select column_name, journal.get_data_type_string(information_schema.columns.*) as data_type from information_schema.columns where table_schema = p_source_schema_name and table_name = p_source_table_name order by ordinal_position) loop

      -- NB: Specifically choosing to not drop deleted columns from the journal table, to preserve the data.
      -- There are no constraints (other than not null on primary key columns) on the journaling table
      -- columns anyway, so leaving it populated with null will be fine.
      select journal.get_data_type_string(information_schema.columns.*) into v_data_type from information_schema.columns where table_schema = p_target_schema_name and table_name = p_target_table_name and column_name = row.column_name;
      if not found then
        execute 'alter table ' || v_journal_name || ' add ' || journal.quote_column(row.column_name) || ' ' || row.data_type;
      elsif (row.data_type != v_data_type) then
        execute 'alter table ' || v_journal_name || ' alter column ' || journal.quote_column(row.column_name) || ' type ' || row.data_type;
      end if;

    end loop;
  else
    execute 'create table ' || v_journal_name || ' as select * from ' || p_source_schema_name || '.' || p_source_table_name || ' limit 0';
    execute 'alter table ' || v_journal_name || ' add journal_timestamp timestamp with time zone not null default now() ';
    execute 'alter table ' || v_journal_name || ' add journal_operation text not null ';
    execute 'alter table ' || v_journal_name || ' add journal_id bigserial primary key ';
    execute 'comment on table ' || v_journal_name || ' is ''Created by plsql function refresh_journaling to shadow all inserts and updates on the table ' || p_source_schema_name || '.' || p_source_table_name || '''';
    perform journal.add_primary_key_data(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name);
  end if;

  perform journal.refresh_journal_trigger(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name);
  
  return v_journal_name;

end;
$$;


ALTER FUNCTION journal.refresh_journaling(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: refresh_journaling_native(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.refresh_journaling_native(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  row record;
  v_journal_name text;
  v_data_type character varying;
  v_create bool;
begin
  v_journal_name = p_target_schema_name || '.' || p_target_table_name;

  v_create = not exists(select 1 from information_schema.tables where table_schema = p_target_schema_name and table_name = p_target_table_name);

  if v_create then
    execute 'create table ' || v_journal_name || ' (journal_timestamp timestamp with time zone not null default now(), journal_operation text not null, journal_id bigserial not null) partition by range (journal_timestamp)';
    execute 'create table partman5.template_' || p_target_schema_name || '_' || p_target_table_name || ' (journal_id bigserial primary key)';
    execute 'comment on table ' || v_journal_name || ' is ''Created by plsql function refresh_journaling_native to shadow all inserts and updates on the table ' || p_source_schema_name || '.' || p_source_table_name || '''';
  end if;

  for row in (select column_name, journal.get_data_type_string(information_schema.columns.*) as data_type from information_schema.columns where table_schema = p_source_schema_name and table_name = p_source_table_name order by ordinal_position) loop

    -- NB: Specifically choosing to not drop deleted columns from the journal table, to preserve the data.
    -- There are no constraints (other than not null on primary key columns) on the journaling table
    -- columns anyway, so leaving it populated with null will be fine.
    select journal.get_data_type_string(information_schema.columns.*) into v_data_type from information_schema.columns where table_schema = p_target_schema_name and table_name = p_target_table_name and column_name = row.column_name;
    if not found then
      execute 'alter table ' || v_journal_name || ' add ' || journal.quote_column(row.column_name) || ' ' || row.data_type;
    elsif (row.data_type != v_data_type) then
      execute 'alter table ' || v_journal_name || ' alter column ' || journal.quote_column(row.column_name) || ' type ' || row.data_type;
    end if;

  end loop;

  if v_create then
    perform journal.add_primary_key_data(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name);
  end if;

  perform journal.refresh_journal_trigger(p_source_schema_name, p_source_table_name, p_target_schema_name, p_target_table_name);

  return v_journal_name;

end;
$$;


ALTER FUNCTION journal.refresh_journaling_native(p_source_schema_name character varying, p_source_table_name character varying, p_target_schema_name character varying, p_target_table_name character varying) OWNER TO api;

--
-- Name: resolvers_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.resolvers_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.resolvers (journal_operation, id, visibility, organization_id, uri, position, credentials, created_at, updated_by_user_id) values (TG_OP, old.id, old.visibility, old.organization_id, old.uri, old.position, old.credentials, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.resolvers_delete() OWNER TO api;

--
-- Name: resolvers_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.resolvers_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.resolvers] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.resolvers]';  end if;  insert into journal.resolvers (journal_operation, id, visibility, organization_id, uri, position, credentials, created_at, updated_by_user_id) values (TG_OP, new.id, new.visibility, new.organization_id, new.uri, new.position, new.credentials, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.resolvers_insert() OWNER TO api;

--
-- Name: resolvers_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.resolvers_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.resolvers_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.resolvers_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.resolvers_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.resolvers_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.resolvers_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('resolvers', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.resolvers_part_trig_func() OWNER TO api;

--
-- Name: subscriptions_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.subscriptions_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.subscriptions (journal_operation, id, user_id, publication, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.publication, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.subscriptions_delete() OWNER TO api;

--
-- Name: subscriptions_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.subscriptions_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.subscriptions] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.subscriptions]';  end if;  insert into journal.subscriptions (journal_operation, id, user_id, publication, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.publication, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.subscriptions_insert() OWNER TO api;

--
-- Name: subscriptions_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.subscriptions_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.subscriptions_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.subscriptions_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('subscriptions', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.subscriptions_part_trig_func() OWNER TO api;

--
-- Name: tokens_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.tokens_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.tokens (journal_operation, id, user_id, tag, token, number_views, description, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.tag, old.token, old.number_views, old.description, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.tokens_delete() OWNER TO api;

--
-- Name: tokens_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.tokens_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.tokens] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.tokens]';  end if;  insert into journal.tokens (journal_operation, id, user_id, tag, token, number_views, description, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.tag, new.token, new.number_views, new.description, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.tokens_insert() OWNER TO api;

--
-- Name: tokens_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.tokens_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN 
                INSERT INTO journal.tokens_p2024_04 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_03 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_07 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-08-01 00:00:00+00' AND NEW.journal_timestamp < '2024-09-01 00:00:00+00' THEN
                INSERT INTO journal.tokens_p2024_08 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('tokens', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.tokens_part_trig_func() OWNER TO api;

--
-- Name: user_identifiers_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.user_identifiers_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.user_identifiers (journal_operation, id, user_id, value, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.value, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.user_identifiers_delete() OWNER TO api;

--
-- Name: user_identifiers_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.user_identifiers_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.user_identifiers] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.user_identifiers]';  end if;  insert into journal.user_identifiers (journal_operation, id, user_id, value, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.value, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.user_identifiers_insert() OWNER TO api;

--
-- Name: user_identifiers_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.user_identifiers_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.user_identifiers_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.user_identifiers_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.user_identifiers_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.user_identifiers_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.user_identifiers_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.user_identifiers_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.user_identifiers_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('user_identifiers', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.user_identifiers_part_trig_func() OWNER TO api;

--
-- Name: user_organizations_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.user_organizations_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.user_organizations (journal_operation, id, user_id, organization_id, created_at, updated_by_user_id) values (TG_OP, old.id, old.user_id, old.organization_id, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.user_organizations_delete() OWNER TO api;

--
-- Name: user_organizations_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.user_organizations_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.user_organizations] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.user_organizations]';  end if;  insert into journal.user_organizations (journal_operation, id, user_id, organization_id, created_at, updated_by_user_id) values (TG_OP, new.id, new.user_id, new.organization_id, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.user_organizations_insert() OWNER TO api;

--
-- Name: user_organizations_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.user_organizations_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.user_organizations_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.user_organizations_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.user_organizations_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.user_organizations_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.user_organizations_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.user_organizations_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.user_organizations_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('user_organizations', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.user_organizations_part_trig_func() OWNER TO api;

--
-- Name: users_delete(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.users_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   insert into journal.users (journal_operation, id, email, first_name, last_name, avatar_url, created_at, updated_by_user_id) values (TG_OP, old.id, old.email, old.first_name, old.last_name, old.avatar_url, old.created_at, journal.get_deleted_by_user_id());  return null; end; $$;


ALTER FUNCTION journal.users_delete() OWNER TO api;

--
-- Name: users_insert(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.users_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ begin   if (TG_OP='UPDATE' and (old.id != new.id)) then    raise exception 'Table[public.users] is journaled. Updates to primary key column[id] are not supported as this would make it impossible to follow the history of this row in the journal table[journal.users]';  end if;  insert into journal.users (journal_operation, id, email, first_name, last_name, avatar_url, created_at, updated_by_user_id) values (TG_OP, new.id, new.email, new.first_name, new.last_name, new.avatar_url, new.created_at, new.updated_by_user_id);  return null; end; $$;


ALTER FUNCTION journal.users_insert() OWNER TO api;

--
-- Name: users_part_trig_func(); Type: FUNCTION; Schema: journal; Owner: api
--

CREATE FUNCTION journal.users_part_trig_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN
        IF TG_OP = 'INSERT' THEN
            v_partition_timestamp := date_trunc('month', NEW.journal_timestamp);
            IF NEW.journal_timestamp >= '2024-03-01 00:00:00+00' AND NEW.journal_timestamp < '2024-04-01 00:00:00+00' THEN 
                INSERT INTO journal.users_p2024_03 VALUES (NEW.*); 
            ELSIF NEW.journal_timestamp >= '2024-02-01 00:00:00+00' AND NEW.journal_timestamp < '2024-03-01 00:00:00+00' THEN
                INSERT INTO journal.users_p2024_02 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-04-01 00:00:00+00' AND NEW.journal_timestamp < '2024-05-01 00:00:00+00' THEN
                INSERT INTO journal.users_p2024_04 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-01-01 00:00:00+00' AND NEW.journal_timestamp < '2024-02-01 00:00:00+00' THEN
                INSERT INTO journal.users_p2024_01 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-05-01 00:00:00+00' AND NEW.journal_timestamp < '2024-06-01 00:00:00+00' THEN
                INSERT INTO journal.users_p2024_05 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-06-01 00:00:00+00' AND NEW.journal_timestamp < '2024-07-01 00:00:00+00' THEN
                INSERT INTO journal.users_p2024_06 VALUES (NEW.*);
            ELSIF NEW.journal_timestamp >= '2024-07-01 00:00:00+00' AND NEW.journal_timestamp < '2024-08-01 00:00:00+00' THEN
                INSERT INTO journal.users_p2024_07 VALUES (NEW.*);
            ELSE
                v_partition_name := partman.check_name_length('users', to_char(v_partition_timestamp, 'YYYY_MM'), TRUE);
                SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname = 'journal' AND tablename = v_partition_name;
                IF v_count > 0 THEN
                    EXECUTE format('INSERT INTO %I.%I VALUES($1.*)', 'journal', v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;
        END IF;
        RETURN NULL;
        END $_$;


ALTER FUNCTION journal.users_part_trig_func() OWNER TO api;

--
-- Name: apply_cluster(text, text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.apply_cluster(p_parent_schema text, p_parent_tablename text, p_child_schema text, p_child_tablename text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_old_search_path   text;
    v_parent_indexdef   text;
    v_relkind           char;
    v_row               record;
    v_sql               text;
BEGIN
/*
* Function to apply cluster from parent to child table
* Adapted from code fork by https://github.com/dturon/pg_partman
*/

SELECT c.relkind INTO v_relkind
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = p_parent_schema
AND c.relname = p_parent_tablename;

IF v_relkind = 'p' THEN
    RAISE EXCEPTION 'This function cannot run on natively partitioned tables';
ELSIF v_relkind IS NULL THEN
    RAISE EXCEPTION 'Unable to find given table in system catalogs: %.%', p_parent_schema, p_parent_tablename;
END IF;

WITH parent_info AS (
    SELECT c.oid AS parent_oid
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = p_parent_schema::name
    AND c.relname = p_parent_tablename::name
)
SELECT substring(pg_get_indexdef(i.indexrelid) from ' USING .*$') AS index_def
INTO v_parent_indexdef
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class c ON i.indexrelid = c.oid
JOIN parent_info p ON p.parent_oid = indrelid
WHERE i.indisclustered = true;

-- Loop over all existing indexes in child table to find one with matching definition
FOR v_row IN
    WITH child_info AS (
        SELECT c.oid AS child_oid
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = p_child_schema::name
        AND c.relname = p_child_tablename::name
    )
    SELECT substring(pg_get_indexdef(i.indexrelid) from ' USING .*$') AS child_indexdef
        , c.relname AS child_indexname
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_class c ON i.indexrelid = c.oid
    JOIN child_info p ON p.child_oid = indrelid
LOOP
    IF v_row.child_indexdef = v_parent_indexdef THEN
        v_sql = format('ALTER TABLE %I.%I CLUSTER ON %I', p_child_schema, p_child_tablename, v_row.child_indexname);
        RAISE DEBUG '%', v_sql;
        EXECUTE v_sql;
    END IF;
END LOOP;

END;
$_$;


ALTER FUNCTION partman5.apply_cluster(p_parent_schema text, p_parent_tablename text, p_child_schema text, p_child_tablename text) OWNER TO api;

--
-- Name: apply_constraints(text, text, boolean, bigint); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.apply_constraints(p_parent_table text, p_child_table text DEFAULT NULL::text, p_analyze boolean DEFAULT false, p_job_id bigint DEFAULT NULL::bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_child_exists                  text;
v_child_tablename               text;
v_col                           text;
v_constraint_cols               text[];
v_constraint_name               text;
v_constraint_valid              boolean;
v_constraint_values             record;
v_control                       text;
v_control_type                  text;
v_datetime_string               text;
v_epoch                         text;
v_existing_constraint_name      text;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_last_partition                text;
v_last_partition_id             bigint;
v_last_partition_timestamp      timestamptz;
v_new_search_path               text;
v_old_search_path               text;
v_optimize_constraint           int;
v_parent_schema                 text;
v_parent_table                  text;
v_parent_tablename              text;
v_partition_interval            text;
v_partition_suffix              text;
v_premake                       int;
v_sql                           text;
v_step_id                       bigint;

BEGIN
/*
 * Apply constraints managed by partman extension
 */

SELECT parent_table
    , control
    , premake
    , partition_interval
    , optimize_constraint
    , epoch
    , datetime_string
    , constraint_cols
    , jobmon
    , constraint_valid
INTO v_parent_table
    , v_control
    , v_premake
    , v_partition_interval
    , v_optimize_constraint
    , v_epoch
    , v_datetime_string
    , v_constraint_cols
    , v_jobmon
    , v_constraint_valid
FROM partman5.part_config
WHERE parent_table = p_parent_table
AND constraint_cols IS NOT NULL;

IF v_constraint_cols IS NULL THEN
    RAISE DEBUG 'apply_constraints: Given parent table (%) not set up for constraint management (constraint_cols is NULL)', p_parent_table;
    -- Returns silently to allow this function to be simply called by maintenance processes without having to check if config options are set.
    RETURN;
END IF;

SELECT schemaname, tablename
INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(v_parent_table, '.', 1)::name
AND tablename = split_part(v_parent_table, '.', 2)::name;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

IF v_jobmon_schema IS NOT NULL THEN
    IF p_job_id IS NULL THEN
        v_job_id := add_job(format('PARTMAN CREATE CONSTRAINT: %s', v_parent_table));
    ELSE
        v_job_id = p_job_id;
    END IF;
END IF;

-- If p_child_table is null, figure out the partition that is the one right before the optimize_constraint value backwards.
IF p_child_table IS NULL THEN
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Applying additional constraints: Automatically determining most recent child on which to apply constraints');
    END IF;

    SELECT partition_tablename INTO v_last_partition FROM partman5.show_partitions(v_parent_table, 'DESC') LIMIT 1;

    IF v_control_type = 'time' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN
        SELECT child_start_time INTO v_last_partition_timestamp FROM partman5.show_partition_info(v_parent_schema||'.'||v_last_partition, v_partition_interval, v_parent_table);
        v_partition_suffix := to_char(v_last_partition_timestamp - (v_partition_interval::interval * (v_optimize_constraint + v_premake + 1) ), v_datetime_string);
    ELSIF v_control_type = 'id' THEN
        SELECT child_start_id INTO v_last_partition_id FROM partman5.show_partition_info(v_parent_schema||'.'||v_last_partition, v_partition_interval, v_parent_table);
        v_partition_suffix := (v_last_partition_id - (v_partition_interval::bigint * (v_optimize_constraint + v_premake + 1) ))::text;
    END IF;

    RAISE DEBUG 'apply_constraint: v_parent_tablename: %, v_last_partition: %, v_last_partition_timestamp: %, v_partition_suffix: %'
                , v_parent_tablename, v_last_partition, v_last_partition_timestamp, v_partition_suffix;

    v_child_tablename := partman5.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', format('Target child table: %s.%s', v_parent_schema, v_child_tablename));
    END IF;
ELSE
    v_child_tablename = split_part(p_child_table, '.', 2);
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Applying additional constraints: Checking if target child table exists');
END IF;

SELECT tablename FROM pg_catalog.pg_tables INTO v_child_exists WHERE schemaname = v_parent_schema::name AND tablename = v_child_tablename::name;
IF v_child_exists IS NULL THEN
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'NOTICE', format('Target child table (%s) does not exist. Skipping constraint creation.', v_child_tablename));
        IF p_job_id IS NULL THEN
            PERFORM close_job(v_job_id);
        END IF;
    END IF;
    RAISE DEBUG 'Target child table (%) does not exist. Skipping constraint creation.', v_child_tablename;
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
    RETURN;
ELSE
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

FOREACH v_col IN ARRAY v_constraint_cols
LOOP
    SELECT con.conname
    INTO v_existing_constraint_name
    FROM pg_catalog.pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    JOIN pg_catalog.pg_attribute a ON con.conrelid = a.attrelid
    WHERE c.relname = v_child_tablename::name
        AND n.nspname = v_parent_schema::name
        AND con.conname LIKE 'partmanconstr_%'
        AND con.contype = 'c'
        AND a.attname = v_col::name
        AND ARRAY[a.attnum] OPERATOR(pg_catalog.<@) con.conkey
        AND a.attisdropped = false;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Applying additional constraints: Applying new constraint on column: %s', v_col));
    END IF;

    IF v_existing_constraint_name IS NOT NULL THEN
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'NOTICE', format('Partman managed constraint already exists on this table (%s) and column (%s). Skipping creation.', v_child_tablename, v_col));
        END IF;
        RAISE DEBUG 'Partman managed constraint already exists on this table (%) and column (%). Skipping creation.', v_child_tablename, v_col ;
        CONTINUE;
    END IF;

    -- Ensure column name gets put on end of constraint name to help avoid naming conflicts
    v_constraint_name := partman5.check_name_length('partmanconstr_'||v_child_tablename, p_suffix := '_'||v_col);

    EXECUTE format('SELECT min(%I)::text AS min, max(%I)::text AS max FROM %I.%I', v_col, v_col, v_parent_schema, v_child_tablename) INTO v_constraint_values;

    IF v_constraint_values IS NOT NULL THEN
        v_sql := format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I >= %L AND %I <= %L)'
                            , v_parent_schema
                            , v_child_tablename
                            , v_constraint_name
                            , v_col
                            , v_constraint_values.min
                            , v_col
                            , v_constraint_values.max);

        IF v_constraint_valid = false THEN
            v_sql := format('%s NOT VALID', v_sql);
        END IF;

        RAISE DEBUG 'Constraint creation query: %', v_sql;
        EXECUTE v_sql;

        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', format('New constraint created: %s', v_sql));
        END IF;
    ELSE
        RAISE DEBUG 'Given column (%) contains all NULLs. No constraint created', v_col;
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'NOTICE', format('Given column (%s) contains all NULLs. No constraint created', v_col));
        END IF;
    END IF;

END LOOP;

IF p_analyze THEN
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Applying additional constraints: Running analyze on partition set: %s', v_parent_table));
    END IF;
    RAISE DEBUG 'Running analyze on partition set: %', v_parent_table;
    EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE CONSTRAINT: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.apply_constraints(p_parent_table text, p_child_table text, p_analyze boolean, p_job_id bigint) OWNER TO api;

--
-- Name: apply_privileges(text, text, text, text, bigint); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.apply_privileges(p_parent_schema text, p_parent_tablename text, p_child_schema text, p_child_tablename text, p_job_id bigint DEFAULT NULL::bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context          text;
ex_detail           text;
ex_hint             text;
ex_message          text;
v_all               text[] := ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'];
v_child_grant       record;
v_child_owner       text;
v_grantees          text[];
v_job_id            bigint;
v_jobmon            boolean;
v_jobmon_schema     text;
v_match             boolean;
v_parent_grant      record;
v_parent_owner      text;
v_revoke            text;
v_row_revoke        record;
v_sql               text;
v_step_id           bigint;

BEGIN
/*
 * Apply privileges and ownership that exist on a given parent to the given child table
 */

SELECT jobmon INTO v_jobmon FROM partman5.part_config WHERE parent_table = p_parent_schema ||'.'|| p_parent_tablename;
IF v_jobmon IS NULL THEN
    RAISE EXCEPTION 'Given table is not managed by this extention: %.%', p_parent_schema, p_parent_tablename;
END IF;

SELECT pg_get_userbyid(c.relowner) INTO v_parent_owner
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = p_parent_schema::name
AND c.relname = p_parent_tablename::name;

SELECT pg_get_userbyid(c.relowner) INTO v_child_owner
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = p_child_schema::name
AND c.relname = p_child_tablename::name;

IF v_parent_owner IS NULL THEN
    RAISE EXCEPTION 'Given parent table does not exist: %.%', p_parent_schema, p_parent_tablename;
END IF;
IF v_child_owner IS NULL THEN
    RAISE EXCEPTION 'Given child table does not exist: %.%', p_child_schema, p_child_tablename;
END IF;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    IF p_job_id IS NULL THEN
        EXECUTE format('SELECT %I.add_job(%L)', v_jobmon_schema, format('PARTMAN APPLYING PRIVILEGES TO CHILD TABLE: %s.%s', p_child_schema, p_child_tablename)) INTO v_job_id;
    ELSE
        v_job_id := p_job_id;
    END IF;
    EXECUTE format('SELECT %I.add_step(%L, %L)', v_jobmon_schema, v_job_id, format('Setting new child table privileges for %s.%s', p_child_schema, p_child_tablename)) INTO v_step_id;
END IF;

IF v_jobmon_schema IS NOT NULL THEN

    EXECUTE format('SELECT %I.update_step(%L, %L, %L)'
            , v_jobmon_schema
            , v_step_id
            , 'PENDING'
            , format('Applying privileges on child partition: %s.%s'
                , p_child_schema
                , p_child_tablename)
            );
END IF;

FOR v_parent_grant IN
    SELECT array_agg(DISTINCT privilege_type::text ORDER BY privilege_type::text) AS types
            , grantee
    FROM partman5.table_privs
    WHERE table_schema = p_parent_schema::name AND table_name = p_parent_tablename::name
    GROUP BY grantee
LOOP
    -- Compare parent & child grants. Don't re-apply if it already exists
    v_match := false;
    v_sql := NULL;
    FOR v_child_grant IN
        SELECT array_agg(DISTINCT privilege_type::text ORDER BY privilege_type::text) AS types
                , grantee
        FROM partman5.table_privs
        WHERE table_schema = p_child_schema::name AND table_name = p_child_tablename::name
        GROUP BY grantee
    LOOP
        IF v_parent_grant.types = v_child_grant.types AND v_parent_grant.grantee = v_child_grant.grantee THEN
            v_match := true;
        END IF;
    END LOOP;

    IF v_match = false THEN
        IF v_parent_grant.grantee = 'PUBLIC' THEN
            v_sql := 'GRANT %s ON %I.%I TO %s';
        ELSE
            v_sql := 'GRANT %s ON %I.%I TO %I';
        END IF;
        EXECUTE format(v_sql
                        , array_to_string(v_parent_grant.types, ',')
                        , p_child_schema
                        , p_child_tablename
                        , v_parent_grant.grantee);
        v_sql := NULL;
        SELECT string_agg(r, ',') INTO v_revoke FROM (SELECT unnest(v_all) AS r EXCEPT SELECT unnest(v_parent_grant.types)) x;
        IF v_revoke IS NOT NULL THEN
            IF v_parent_grant.grantee = 'PUBLIC' THEN
                v_sql := 'REVOKE %s ON %I.%I FROM %s CASCADE';
            ELSE
                v_sql := 'REVOKE %s ON %I.%I FROM %I CASCADE';
            END IF;
            EXECUTE format(v_sql
                        , v_revoke
                        , p_child_schema
                        , p_child_tablename
                        , v_parent_grant.grantee);
            v_sql := NULL;
        END IF;
    END IF;

    v_grantees := array_append(v_grantees, v_parent_grant.grantee::text);

END LOOP;

-- Revoke all privileges from roles that have none on the parent
IF v_grantees IS NOT NULL THEN
    FOR v_row_revoke IN
        SELECT role FROM (
            SELECT DISTINCT grantee::text AS role FROM partman5.table_privs WHERE table_schema = p_child_schema::name AND table_name = p_child_tablename::name
            EXCEPT
            SELECT unnest(v_grantees)) x
    LOOP
        IF v_row_revoke.role IS NOT NULL THEN
            IF v_row_revoke.role = 'PUBLIC' THEN
                v_sql := 'REVOKE ALL ON %I.%I FROM %s';
            ELSE
                v_sql := 'REVOKE ALL ON %I.%I FROM %I';
            END IF;
            EXECUTE format(v_sql
                        , p_child_schema
                        , p_child_tablename
                        , v_row_revoke.role);
        END IF;
    END LOOP;

END IF;

IF v_parent_owner <> v_child_owner THEN
    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I'
                , p_child_schema
                , p_child_tablename
                , v_parent_owner);
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    EXECUTE format('SELECT %I.update_step(%L, %L, %L)', v_jobmon_schema, v_step_id, 'OK', 'Done');
    IF p_job_id IS NULL THEN
        EXECUTE format('SELECT %I.close_job(%L)', v_jobmon_schema, v_job_id);
    END IF;
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN RE-APPLYING PRIVILEGES TO ALL CHILD TABLES OF: %s'')', v_jobmon_schema, p_parent_tablename) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_tablename) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.apply_privileges(p_parent_schema text, p_parent_tablename text, p_child_schema text, p_child_tablename text, p_job_id bigint) OWNER TO api;

--
-- Name: autovacuum_off(text, text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.autovacuum_off(p_parent_schema text, p_parent_tablename text, p_source_schema text DEFAULT NULL::text, p_source_tablename text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

v_row       record;
v_sql       text;

BEGIN

    v_sql = format('ALTER TABLE %I.%I SET (autovacuum_enabled = false, toast.autovacuum_enabled = false)', p_parent_schema, p_parent_tablename);
    RAISE DEBUG 'partition_data sql: %', v_sql;
    EXECUTE v_sql;

    IF p_source_tablename IS NOT NULL THEN
        v_sql = format('ALTER TABLE %I.%I SET (autovacuum_enabled = false, toast.autovacuum_enabled = false)', p_source_schema, p_source_tablename);
        RAISE DEBUG 'partition_data sql: %', v_sql;
        EXECUTE v_sql;
    END IF;

    FOR v_row IN
        SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_schema||'.'||p_parent_tablename, 'ASC')
    LOOP
        v_sql = format('ALTER TABLE %I.%I SET (autovacuum_enabled = false, toast.autovacuum_enabled = false)', v_row.partition_schemaname, v_row.partition_tablename);
        RAISE DEBUG 'partition_data sql: %', v_sql;
        EXECUTE v_sql;
    END LOOP;

    RETURN true;

END
$$;


ALTER FUNCTION partman5.autovacuum_off(p_parent_schema text, p_parent_tablename text, p_source_schema text, p_source_tablename text) OWNER TO api;

--
-- Name: autovacuum_reset(text, text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.autovacuum_reset(p_parent_schema text, p_parent_tablename text, p_source_schema text DEFAULT NULL::text, p_source_tablename text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

v_row       record;
v_sql       text;

BEGIN

    v_sql = format('ALTER TABLE %I.%I RESET (autovacuum_enabled, toast.autovacuum_enabled)', p_parent_schema, p_parent_tablename);
    RAISE DEBUG 'partition_data sql: %', v_sql;
    EXECUTE v_sql;

    IF p_source_tablename IS NOT NULL THEN
        v_sql = format('ALTER TABLE %I.%I RESET (autovacuum_enabled, toast.autovacuum_enabled)', p_source_schema, p_source_tablename);
        RAISE DEBUG 'partition_data sql: %', v_sql;
        EXECUTE v_sql;
    END IF;

    FOR v_row IN
        SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_schema||'.'||p_parent_tablename, 'ASC')
    LOOP
        v_sql = format('ALTER TABLE %I.%I RESET (autovacuum_enabled, toast.autovacuum_enabled)', v_row.partition_schemaname, v_row.partition_tablename);
        RAISE DEBUG 'partition_data sql: %', v_sql;
        EXECUTE v_sql;
    END LOOP;

    RETURN true;
END
$$;


ALTER FUNCTION partman5.autovacuum_reset(p_parent_schema text, p_parent_tablename text, p_source_schema text, p_source_tablename text) OWNER TO api;

--
-- Name: calculate_time_partition_info(interval, timestamp with time zone, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.calculate_time_partition_info(p_time_interval interval, p_start_time timestamp with time zone, p_date_trunc_interval text DEFAULT NULL::text, OUT base_timestamp timestamp with time zone, OUT datetime_string text) RETURNS record
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN

-- Built-in datetime string suffixes are YYYYMMDD, YYYYMMDD_HH24MISS
datetime_string := 'YYYYMMDD';
IF p_time_interval < '1 day' THEN
    datetime_string := datetime_string || '_HH24MISS';
END IF;

IF p_date_trunc_interval IS NOT NULL THEN
    base_timestamp := date_trunc(p_date_trunc_interval, p_start_time);

ELSE
    IF p_time_interval >= '1 year' THEN
        base_timestamp := date_trunc('year', p_start_time);
        IF p_time_interval >= '10 years' THEN
            base_timestamp := date_trunc('decade', p_start_time);
            IF p_time_interval >= '100 years' THEN
                base_timestamp := date_trunc('century', p_start_time);
                IF p_time_interval >= '1000 years' THEN
                    base_timestamp := date_trunc('millennium', p_start_time);
                END IF; -- 1000
            END IF; -- 100
        END IF; -- 10
    END IF; -- 1

    IF p_time_interval < '1 year' THEN
        base_timestamp := date_trunc('month', p_start_time);
        IF p_time_interval < '1 month' THEN
            base_timestamp := date_trunc('day', p_start_time);
            IF p_time_interval < '1 day' THEN
                base_timestamp := date_trunc('hour', p_start_time);
                IF p_time_interval < '1 minute' THEN
                    base_timestamp := date_trunc('minute', p_start_time);
                END IF; -- minute
            END IF; -- day
        END IF; -- month
    END IF; -- year

END IF;
END
$$;


ALTER FUNCTION partman5.calculate_time_partition_info(p_time_interval interval, p_start_time timestamp with time zone, p_date_trunc_interval text, OUT base_timestamp timestamp with time zone, OUT datetime_string text) OWNER TO api;

--
-- Name: check_automatic_maintenance_value(text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_automatic_maintenance_value(p_automatic_maintenance text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
v_result    boolean;
BEGIN
    SELECT p_automatic_maintenance IN ('on', 'off') INTO v_result;
    RETURN v_result;
END
$$;


ALTER FUNCTION partman5.check_automatic_maintenance_value(p_automatic_maintenance text) OWNER TO api;

--
-- Name: check_control_type(text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_control_type(p_parent_schema text, p_parent_tablename text, p_control text) RETURNS TABLE(general_type text, exact_type text)
    LANGUAGE sql STABLE
    AS $$
/*
 * Return column type for given table & column in that table
 * Returns NULL if objects don't match compatible types
 */

SELECT CASE
        WHEN typname IN ('timestamptz', 'timestamp', 'date') THEN
            'time'
        WHEN typname IN ('int2', 'int4', 'int8', 'numeric' ) THEN
            'id'
       END
    , typname::text
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_attribute a ON t.oid = a.atttypid
    JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = p_parent_schema::name
    AND c.relname = p_parent_tablename::name
    AND a.attname = p_control::name
$$;


ALTER FUNCTION partman5.check_control_type(p_parent_schema text, p_parent_tablename text, p_control text) OWNER TO api;

--
-- Name: check_default(boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_default(p_exact_count boolean DEFAULT true) RETURNS SETOF partman5.check_default_table
    LANGUAGE plpgsql STABLE
    SET search_path TO 'partman5', 'pg_temp'
    AS $$
DECLARE

v_count                     bigint = 0;
v_default_schemaname        text;
v_default_tablename         text;
v_parent_schemaname         text;
v_parent_tablename          text;
v_row                       record;
v_sql                       text;
v_trouble                   partman5.check_default_table%rowtype;

BEGIN
/*
 * Function to monitor for data getting inserted into default table
 */

FOR v_row IN
    SELECT parent_table FROM partman5.part_config
LOOP
    SELECT schemaname, tablename
    INTO v_parent_schemaname, v_parent_tablename
    FROM pg_catalog.pg_tables
    WHERE schemaname = split_part(v_row.parent_table, '.', 1)::name
    AND tablename = split_part(v_row.parent_table, '.', 2)::name;

    v_sql := format('SELECT n.nspname::text, c.relname::text FROM
            pg_catalog.pg_inherits h
            JOIN pg_catalog.pg_class c ON c.oid = h.inhrelid
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
            WHERE h.inhparent = ''%I.%I''::regclass
            AND pg_get_expr(relpartbound, c.oid) = ''DEFAULT'''
        , v_parent_schemaname
        , v_parent_tablename);

    EXECUTE v_sql INTO v_default_schemaname, v_default_tablename;

    IF v_default_schemaname IS NOT NULL AND v_default_tablename IS NOT NULL THEN

        IF p_exact_count THEN
            v_sql := format('SELECT count(1) AS n FROM ONLY %I.%I', v_default_schemaname, v_default_tablename);
        ELSE
            v_sql := format('SELECT count(1) AS n FROM (SELECT 1 FROM ONLY %I.%I LIMIT 1) x', v_default_schemaname, v_default_tablename);
        END IF;

        EXECUTE v_sql INTO v_count;

        IF v_count > 0 THEN
            v_trouble.default_table := v_default_schemaname ||'.'|| v_default_tablename;
            v_trouble.count := v_count;
            RETURN NEXT v_trouble;
        END IF;

    END IF;

    v_count := 0;

END LOOP;

RETURN;

END
$$;


ALTER FUNCTION partman5.check_default(p_exact_count boolean) OWNER TO api;

--
-- Name: check_epoch_type(text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_epoch_type(p_type text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
v_result    boolean;
BEGIN
    SELECT p_type IN ('none', 'seconds', 'milliseconds', 'nanoseconds') INTO v_result;
    RETURN v_result;
END
$$;


ALTER FUNCTION partman5.check_epoch_type(p_type text) OWNER TO api;

--
-- Name: check_name_length(text, text, boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_name_length(p_object_name text, p_suffix text DEFAULT NULL::text, p_table_partition boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
    v_new_name      text;
    v_suffix        text;
BEGIN
/*
 * Truncate the name of the given object if it is greater than the postgres default max (63 characters).
 * Also appends given suffix and schema if given and truncates the name so that the entire suffix will fit.
 * Returns original name (with suffix if given) if it doesn't require truncation
 * Retains SECURITY DEFINER since it is called by trigger functions and did not want to break installations prior to 4.0.0
 */

IF p_table_partition IS TRUE AND (NULLIF(p_suffix, '') IS NULL) THEN
    RAISE EXCEPTION 'Table partition name requires a suffix value';
END IF;


v_suffix := format('%s%s', CASE WHEN p_table_partition THEN '_p' END, p_suffix);
-- Use optimistic behavior: in almost all cases `v_new_name` will be less than allowed maximum.
-- Do "heavy" work only in rare cases.
v_new_name := p_object_name || v_suffix;

-- Postgres' relation name limit is in bytes, not characters; also it can be compiled with bigger allowed length.
-- Use its internals to detect where to cut new object name.
IF v_new_name::name != v_new_name THEN
    -- Here we need to detect how many chars (not bytes) we need to get from the `p_object_name`.
    -- Use suffix as prefix and get the rest of `p_object_name`.
    v_new_name := (v_suffix || p_object_name)::name;
    -- `substr` starts from 1, that is why we need to add 1 below.
    -- Edge case: `v_suffix` is empty, length is 0, but need to start from 1.
    v_new_name := substr(v_new_name, length(v_suffix) + 1) || v_suffix;
END IF;

RETURN v_new_name;

END
$$;


ALTER FUNCTION partman5.check_name_length(p_object_name text, p_suffix text, p_table_partition boolean) OWNER TO api;

--
-- Name: check_partition_type(text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_partition_type(p_type text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
v_result    boolean;
BEGIN
    SELECT p_type IN ('range', 'list') INTO v_result;
    RETURN v_result;
END
$$;


ALTER FUNCTION partman5.check_partition_type(p_type text) OWNER TO api;

--
-- Name: check_subpart_sameconfig(text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_subpart_sameconfig(p_parent_table text) RETURNS TABLE(sub_control text, sub_partition_interval text, sub_partition_type text, sub_premake integer, sub_automatic_maintenance text, sub_template_table text, sub_retention text, sub_retention_schema text, sub_retention_keep_index boolean, sub_retention_keep_table boolean, sub_epoch text, sub_constraint_cols text[], sub_optimize_constraint integer, sub_infinite_time_partitions boolean, sub_jobmon boolean, sub_inherit_privileges boolean, sub_constraint_valid boolean, sub_date_trunc_interval text, sub_ignore_default_data boolean, sub_default_table boolean, sub_maintenance_order integer, sub_retention_keep_publication boolean)
    LANGUAGE sql STABLE
    SET search_path TO 'partman5', 'pg_temp'
    AS $$
/*
 * Check for consistent data in part_config_sub table. Was unable to get this working properly as either a constraint or trigger.
 * Would either delay raising an error until the next write (which I cannot predict) or disallow future edits to update a sub-partition set's configuration.
 * This is called by run_maintainance() and at least provides a consistent way to check that I know will run.
 * If anyone can get a working constraint/trigger, please help!
*/

    WITH parent_info AS (
        SELECT c1.oid
        FROM pg_catalog.pg_class c1
        JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid
        WHERE n1.nspname = split_part(p_parent_table, '.', 1)::name
        AND c1.relname = split_part(p_parent_table, '.', 2)::name
    )
    , child_tables AS (
        SELECT n.nspname||'.'||c.relname AS tablename
        FROM pg_catalog.pg_inherits h
        JOIN pg_catalog.pg_class c ON c.oid = h.inhrelid
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        JOIN parent_info pi ON h.inhparent = pi.oid
    )
    -- Column order here must match the RETURNS TABLE definition
    -- This column list must be kept consistent between:
    --   create_parent, check_subpart_sameconfig, create_partition_id, create_partition_time, dump_partitioned_table_definition, and table definition
    --   Also check return table list from this function
    SELECT DISTINCT
        a.sub_control
        , a.sub_partition_interval
        , a.sub_partition_type
        , a.sub_premake
        , a.sub_automatic_maintenance
        , a.sub_template_table
        , a.sub_retention
        , a.sub_retention_schema
        , a.sub_retention_keep_index
        , a.sub_retention_keep_table
        , a.sub_epoch
        , a.sub_constraint_cols
        , a.sub_optimize_constraint
        , a.sub_infinite_time_partitions
        , a.sub_jobmon
        , a.sub_inherit_privileges
        , a.sub_constraint_valid
        , a.sub_date_trunc_interval
        , a.sub_ignore_default_data
        , a.sub_default_table
        , a.sub_maintenance_order
        , a.sub_retention_keep_publication
    FROM partman5.part_config_sub a
    JOIN child_tables b on a.sub_parent = b.tablename;
$$;


ALTER FUNCTION partman5.check_subpart_sameconfig(p_parent_table text) OWNER TO api;

--
-- Name: check_subpartition_limits(text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.check_subpartition_limits(p_parent_table text, p_type text, OUT sub_min text, OUT sub_max text) RETURNS record
    LANGUAGE plpgsql
    AS $$
DECLARE

v_parent_schema         text;
v_parent_tablename      text;
v_top_control           text;
v_top_control_type      text;
v_top_epoch             text;
v_top_interval          text;
v_top_schema            text;
v_top_tablename         text;

BEGIN
/*
 * Check if parent table is a subpartition of an already existing partition set managed by pg_partman
 *  If so, return the limits of what child tables can be created under the given parent table based on its own suffix
 *  If not, return NULL. Allows caller to check for NULL and then know if the given parent has sub-partition limits.
 */

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;

WITH top_oid AS (
    SELECT i.inhparent AS top_parent_oid
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_inherits i ON c.oid = i.inhrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_parent_schema
    AND c.relname = v_parent_tablename
)
SELECT n.nspname, c.relname, p.partition_interval, p.control, p.epoch
INTO v_top_schema, v_top_tablename, v_top_interval, v_top_control, v_top_epoch
FROM pg_catalog.pg_class c
JOIN top_oid t ON c.oid = t.top_parent_oid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN partman5.part_config p ON p.parent_table = n.nspname||'.'||c.relname
WHERE c.oid = t.top_parent_oid;

SELECT general_type INTO v_top_control_type
FROM partman5.check_control_type(v_top_schema, v_top_tablename, v_top_control);

IF v_top_control_type = 'id' AND v_top_epoch <> 'none' THEN
    v_top_control_type := 'time';
END IF;

-- If sub-partition is different type than top parent, no need to set limits
IF p_type = v_top_control_type THEN
    IF p_type = 'time' THEN
        SELECT child_start_time::text, child_end_time::text
        INTO sub_min, sub_max
        FROM partman5.show_partition_info(p_parent_table, v_top_interval, v_top_schema||'.'||v_top_tablename);
    ELSIF p_type = 'id' THEN
        -- Trunc to handle numeric values
        SELECT trunc(child_start_id)::text, trunc(child_end_id)::text
        INTO sub_min, sub_max
        FROM partman5.show_partition_info(p_parent_table, v_top_interval, v_top_schema||'.'||v_top_tablename);
    ELSE
        RAISE EXCEPTION 'Reached unknown state in check_subpartition_limits(). Please report what lead to this condition to author';
    END IF;
END IF;

RETURN;

END
$$;


ALTER FUNCTION partman5.check_subpartition_limits(p_parent_table text, p_type text, OUT sub_min text, OUT sub_max text) OWNER TO api;

--
-- Name: create_parent(text, text, text, text, text, integer, text, boolean, text, text[], text, boolean, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.create_parent(p_parent_table text, p_control text, p_interval text, p_type text DEFAULT 'range'::text, p_epoch text DEFAULT 'none'::text, p_premake integer DEFAULT 4, p_start_partition text DEFAULT NULL::text, p_default_table boolean DEFAULT true, p_automatic_maintenance text DEFAULT 'on'::text, p_constraint_cols text[] DEFAULT NULL::text[], p_template_table text DEFAULT NULL::text, p_jobmon boolean DEFAULT true, p_date_trunc_interval text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_base_timestamp                timestamptz;
v_count                         int := 1;
v_control_type                  text;
v_control_exact_type            text;
v_datetime_string               text;
v_default_partition             text;
v_higher_control_type           text;
v_higher_parent_control         text;
v_higher_parent_epoch           text;
v_higher_parent_schema          text := split_part(p_parent_table, '.', 1);
v_higher_parent_table           text := split_part(p_parent_table, '.', 2);
v_id_interval                   bigint;
v_inherit_privileges            boolean := false; -- This is false by default so initial partition set creation doesn't require superuser.
v_job_id                        bigint;
v_jobmon_schema                 text;
v_last_partition_created        boolean;
v_max                           bigint;
v_notnull                       boolean;
v_new_search_path               text;
v_old_search_path               text;
v_parent_owner                  text;
v_parent_partition_id           bigint;
v_parent_partition_timestamp    timestamptz;
v_parent_schema                 text;
v_parent_tablename              text;
v_parent_tablespace             name;
v_part_col                      text;
v_part_type                     text;
v_partattrs                     smallint[];
v_partition_time                timestamptz;
v_partition_time_array          timestamptz[];
v_partition_id_array            bigint[];
v_partstrat                     char;
v_row                           record;
v_sql                           text;
v_start_time                    timestamptz;
v_starting_partition_id         bigint;
v_step_id                       bigint;
v_step_overflow_id              bigint;
v_success                       boolean := false;
v_template_schema               text;
v_template_tablename            text;
v_time_interval                 interval;
v_top_parent_schema             text := split_part(p_parent_table, '.', 1);
v_top_parent_table              text := split_part(p_parent_table, '.', 2);
v_unlogged                      char;

BEGIN
/*
 * Function to turn a table into the parent of a partition set
 */

IF array_length(string_to_array(p_parent_table, '.'), 1) < 2 THEN
    RAISE EXCEPTION 'Parent table must be schema qualified';
ELSIF array_length(string_to_array(p_parent_table, '.'), 1) > 2 THEN
    RAISE EXCEPTION 'pg_partman does not support objects with periods in their names';
END IF;

IF p_interval = 'yearly'
    OR p_interval = 'quarterly'
    OR p_interval = 'monthly'
    OR p_interval  = 'weekly'
    OR p_interval = 'daily'
    OR p_interval = 'hourly'
    OR p_interval = 'half-hour'
    OR p_interval = 'quarter-hour'
THEN
    RAISE EXCEPTION 'Special partition interval values from old pg_partman versions (%) are no longer supported. Please use a supported interval time value from core PostgreSQL (https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-INTERVAL-INPUT)', p_interval;
END IF;

SELECT n.nspname
    , c.relname
    , c.relpersistence
    , t.spcname
INTO v_parent_schema
    , v_parent_tablename
    , v_unlogged
    , v_parent_tablespace
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
LEFT OUTER JOIN pg_catalog.pg_tablespace t ON c.reltablespace = t.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs. Please create parent table first: %', p_parent_table;
    END IF;

SELECT attnotnull INTO v_notnull
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE c.relname = v_parent_tablename::name
AND n.nspname = v_parent_schema::name
AND a.attname = p_control::name;
    IF (v_notnull = false OR v_notnull IS NULL) THEN
        RAISE EXCEPTION 'Control column given (%) for parent table (%) does not exist or must be set to NOT NULL', p_control, p_parent_table;
    END IF;

SELECT general_type, exact_type INTO v_control_type, v_control_exact_type
FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, p_control);

IF v_control_type IS NULL THEN
    RAISE EXCEPTION 'pg_partman only supports partitioning of data types that are integer, numeric or date/timestamp. Supplied column is of type %', v_control_exact_type;
END IF;

IF (p_epoch <> 'none' AND v_control_type <> 'id') THEN
    RAISE EXCEPTION 'p_epoch can only be used with an integer based control column';
END IF;


IF NOT partman5.check_partition_type(p_type) THEN
    RAISE EXCEPTION '% is not a valid partitioning type for pg_partman', p_type;
END IF;

IF current_setting('server_version_num')::int < 140000 THEN
    RAISE EXCEPTION 'pg_partman requires PostgreSQL 14 or greater';
END IF;
-- Check if given parent table has been already set up as a partitioned table
SELECT p.partstrat
    , p.partattrs
INTO v_partstrat
    , v_partattrs
FROM pg_catalog.pg_partitioned_table p
JOIN pg_catalog.pg_class c ON p.partrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = v_parent_schema::name
AND c.relname = v_parent_tablename::name;

IF v_partstrat NOT IN ('r', 'l') OR v_partstrat IS NULL THEN
    RAISE EXCEPTION 'You must have created the given parent table as ranged or list partitioned already. Ex: CREATE TABLE ... PARTITION BY [RANGE|LIST] ...)';
END IF;

IF array_length(v_partattrs, 1) > 1 THEN
    RAISE NOTICE 'pg_partman only supports single column partitioning at this time. Found % columns in given parent definition.', array_length(v_partattrs, 1);
END IF;

SELECT a.attname, t.typname
INTO v_part_col, v_part_type
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
JOIN pg_type t ON a.atttypid = t.oid
WHERE n.nspname = v_parent_schema::name
AND c.relname = v_parent_tablename::name
AND attnum IN (SELECT unnest(partattrs) FROM pg_partitioned_table p WHERE a.attrelid = p.partrelid);

IF p_control <> v_part_col OR v_control_exact_type <> v_part_type THEN
    RAISE EXCEPTION 'Control column and type given in arguments (%, %) does not match the control column and type of the given partition set (%, %)', p_control, v_control_exact_type, v_part_col, v_part_type;
END IF;

-- Check that control column is a usable type for pg_partman.
IF v_control_type NOT IN ('time', 'id') THEN
    RAISE EXCEPTION 'Only date/time or integer types are allowed for the control column.';
END IF;

-- Table to handle properties not managed by core PostgreSQL yet
IF p_template_table IS NULL THEN
    v_template_schema := 'partman5';
    v_template_tablename := partman5.check_name_length('template_'||v_parent_schema||'_'||v_parent_tablename);
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I (LIKE %I.%I)', v_template_schema, v_template_tablename, v_parent_schema, v_parent_tablename);

    SELECT pg_get_userbyid(c.relowner) INTO v_parent_owner
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = v_parent_schema::name
    AND c.relname = v_parent_tablename::name;

    EXECUTE format('ALTER TABLE %s.%I OWNER TO %I'
            , 'partman5'
            , v_template_tablename
            , v_parent_owner);
ELSIF lower(p_template_table) IN ('false', 'f') THEN
    v_template_schema := NULL;
    v_template_tablename := NULL;
    RAISE DEBUG 'create_parent(): parent_table: %, skipped template table creation', p_parent_table;
ELSE
    SELECT n.nspname, c.relname INTO v_template_schema, v_template_tablename
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = split_part(p_template_table, '.', 1)::name
    AND c.relname = split_part(p_template_table, '.', 2)::name;
        IF v_template_tablename IS NULL THEN
            RAISE EXCEPTION 'Unable to find given template table in system catalogs (%). Please create template table first or leave parameter NULL to have a default one created for you.', p_parent_table;
        END IF;
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF p_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

EXECUTE format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE', v_parent_schema, v_parent_tablename);

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN SETUP PARENT: %s', p_parent_table));
    v_step_id := add_step(v_job_id, format('Creating initial partitions on new parent table: %s', p_parent_table));
END IF;

-- If this parent table has siblings that are also partitioned (subpartitions), ensure this parent gets added to part_config_sub table so future maintenance will subpartition it
-- Just doing in a loop to avoid having to assign a bunch of variables (should only run once, if at all; constraint should enforce only one value.)
FOR v_row IN
    WITH parent_table AS (
        SELECT h.inhparent AS parent_oid
        FROM pg_catalog.pg_inherits h
        JOIN pg_catalog.pg_class c ON h.inhrelid = c.oid
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relname = v_parent_tablename::name
        AND n.nspname = v_parent_schema::name
    ), sibling_children AS (
        SELECT i.inhrelid::regclass::text AS tablename
        FROM pg_inherits i
        JOIN parent_table p ON i.inhparent = p.parent_oid
    )
    -- This column list must be kept consistent between:
    --   create_parent, check_subpart_sameconfig, create_partition_id, create_partition_time, dump_partitioned_table_definition and table definition
    SELECT DISTINCT
        a.sub_control
        , a.sub_partition_interval
        , a.sub_partition_type
        , a.sub_premake
        , a.sub_automatic_maintenance
        , a.sub_template_table
        , a.sub_retention
        , a.sub_retention_schema
        , a.sub_retention_keep_index
        , a.sub_retention_keep_table
        , a.sub_epoch
        , a.sub_constraint_cols
        , a.sub_optimize_constraint
        , a.sub_infinite_time_partitions
        , a.sub_jobmon
        , a.sub_inherit_privileges
        , a.sub_constraint_valid
        , a.sub_date_trunc_interval
        , a.sub_ignore_default_data
        , a.sub_default_table
        , a.sub_retention_keep_publication
    FROM partman5.part_config_sub a
    JOIN sibling_children b on a.sub_parent = b.tablename LIMIT 1
LOOP
    INSERT INTO partman5.part_config_sub (
        sub_parent
        , sub_partition_type
        , sub_control
        , sub_partition_interval
        , sub_constraint_cols
        , sub_premake
        , sub_retention
        , sub_retention_schema
        , sub_retention_keep_table
        , sub_retention_keep_index
        , sub_automatic_maintenance
        , sub_epoch
        , sub_optimize_constraint
        , sub_infinite_time_partitions
        , sub_jobmon
        , sub_template_table
        , sub_inherit_privileges
        , sub_constraint_valid
        , sub_date_trunc_interval
        , sub_ignore_default_data
        , sub_retention_keep_publication)
    VALUES (
        p_parent_table
        , v_row.sub_partition_type
        , v_row.sub_control
        , v_row.sub_partition_interval
        , v_row.sub_constraint_cols
        , v_row.sub_premake
        , v_row.sub_retention
        , v_row.sub_retention_schema
        , v_row.sub_retention_keep_index
        , v_row.sub_retention_keep_table
        , v_row.sub_automatic_maintenance
        , v_row.sub_epoch
        , v_row.sub_optimize_constraint
        , v_row.sub_infinite_time_partitions
        , v_row.sub_jobmon
        , v_row.sub_template_table
        , v_row.sub_inherit_privileges
        , v_row.sub_constraint_valid
        , v_row.sub_date_trunc_interval
        , v_row.sub_ignore_default_data
        , v_row.sub_retention_keep_publication);

    -- Set this equal to sibling configs so that newly created child table
    -- privileges are set properly below during initial setup.
    -- This setting is special because it applies immediately to the new child
    -- tables of a given parent, not just during maintenance like most other settings.
    v_inherit_privileges = v_row.sub_inherit_privileges;
END LOOP;

IF v_control_type = 'time' OR (v_control_type = 'id' AND p_epoch <> 'none') THEN

    v_time_interval := p_interval::interval;
    IF v_time_interval < '1 second'::interval THEN
        RAISE EXCEPTION 'Partitioning interval must be 1 second or greater';
    END IF;

   -- First partition is either the min premake or p_start_partition
    v_start_time := COALESCE(p_start_partition::timestamptz, CURRENT_TIMESTAMP - (v_time_interval * p_premake));

    SELECT base_timestamp, datetime_string
    INTO v_base_timestamp, v_datetime_string
    FROM partman5.calculate_time_partition_info(v_time_interval, v_start_time, p_date_trunc_interval);

    RAISE DEBUG 'create_parent(): parent_table: %, v_base_timestamp: %', p_parent_table, v_base_timestamp;

    v_partition_time_array := array_append(v_partition_time_array, v_base_timestamp);
    LOOP
        -- If current loop value is less than or equal to the value of the max premake, add time to array.
        IF (v_base_timestamp + (v_time_interval * v_count)) < (CURRENT_TIMESTAMP + (v_time_interval * p_premake)) THEN
            BEGIN
                v_partition_time := (v_base_timestamp + (v_time_interval * v_count))::timestamptz;
                v_partition_time_array := array_append(v_partition_time_array, v_partition_time);
            EXCEPTION WHEN datetime_field_overflow THEN
                RAISE WARNING 'Attempted partition time interval is outside PostgreSQL''s supported time range.
                    Child partition creation after time % skipped', v_partition_time;
                v_step_overflow_id := add_step(v_job_id, 'Attempted partition time interval is outside PostgreSQL''s supported time range.');
                PERFORM update_step(v_step_overflow_id, 'CRITICAL', 'Child partition creation after time '||v_partition_time||' skipped');
                CONTINUE;
            END;
        ELSE
            EXIT; -- all needed partitions added to array. Exit the loop.
        END IF;
        v_count := v_count + 1;
    END LOOP;

    INSERT INTO partman5.part_config (
        parent_table
        , partition_type
        , partition_interval
        , epoch
        , control
        , premake
        , constraint_cols
        , datetime_string
        , automatic_maintenance
        , jobmon
        , template_table
        , inherit_privileges
        , default_table
        , date_trunc_interval)
    VALUES (
        p_parent_table
        , p_type
        , v_time_interval
        , p_epoch
        , p_control
        , p_premake
        , p_constraint_cols
        , v_datetime_string
        , p_automatic_maintenance
        , p_jobmon
        , v_template_schema||'.'||v_template_tablename
        , v_inherit_privileges
        , p_default_table
        , p_date_trunc_interval);

    RAISE DEBUG 'create_parent: v_partition_time_array: %', v_partition_time_array;

    v_last_partition_created := partman5.create_partition_time(p_parent_table, v_partition_time_array);

    IF v_last_partition_created = false THEN
        -- This can happen with subpartitioning when future or past partitions prevent child creation because they're out of range of the parent
        -- First see if this parent is a subpartition managed by pg_partman
        WITH top_oid AS (
            SELECT i.inhparent AS top_parent_oid
            FROM pg_catalog.pg_inherits i
            JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = v_parent_tablename::name
            AND n.nspname = v_parent_schema::name
        ) SELECT n.nspname, c.relname
        INTO v_top_parent_schema, v_top_parent_table
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN top_oid t ON c.oid = t.top_parent_oid
        JOIN partman5.part_config p ON p.parent_table = n.nspname||'.'||c.relname;

        IF v_top_parent_table IS NOT NULL THEN
            -- If so create the lowest possible partition that is within the boundary of the parent
            SELECT child_start_time INTO v_parent_partition_timestamp FROM partman5.show_partition_info(p_parent_table, p_parent_table := v_top_parent_schema||'.'||v_top_parent_table);
            IF v_base_timestamp >= v_parent_partition_timestamp THEN
                WHILE v_base_timestamp >= v_parent_partition_timestamp LOOP
                    v_base_timestamp := v_base_timestamp - v_time_interval;
                END LOOP;
                v_base_timestamp := v_base_timestamp + v_time_interval; -- add one back since while loop set it one lower than is needed
            ELSIF v_base_timestamp < v_parent_partition_timestamp THEN
                WHILE v_base_timestamp < v_parent_partition_timestamp LOOP
                    v_base_timestamp := v_base_timestamp + v_time_interval;
                END LOOP;
                -- Don't need to remove one since new starting time will fit in top parent interval
            END IF;
            v_partition_time_array := NULL;
            v_partition_time_array := array_append(v_partition_time_array, v_base_timestamp);
            v_last_partition_created := partman5.create_partition_time(p_parent_table, v_partition_time_array);
        ELSE
            RAISE WARNING 'No child tables created. Check that all child tables did not already exist and may not have been part of partition set. Given parent has still been configured with pg_partman, but may not have expected children. Please review schema and config to confirm things are ok.';

            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', 'Done');
                IF v_step_overflow_id IS NOT NULL THEN
                    PERFORM fail_job(v_job_id);
                ELSE
                    PERFORM close_job(v_job_id);
                END IF;
            END IF;

            EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

            RETURN v_success;
        END IF;
    END IF; -- End v_last_partition IF

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', format('Time partitions premade: %s', p_premake));
    END IF;

END IF;

IF v_control_type = 'id' AND p_epoch = 'none' THEN
    v_id_interval := p_interval::bigint;
    IF v_id_interval < 2 AND p_type != 'list' THEN
       RAISE EXCEPTION 'Interval for range partitioning must be greater than or equal to 2. Use LIST partitioning for single value partitions. (Values given: p_interval: %, p_type: %)', p_interval, p_type;
    END IF;

    -- Check if parent table is a subpartition of an already existing id partition set managed by pg_partman.
    WHILE v_higher_parent_table IS NOT NULL LOOP -- initially set in DECLARE
        WITH top_oid AS (
            SELECT i.inhparent AS top_parent_oid
            FROM pg_catalog.pg_inherits i
            JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_higher_parent_schema::name
            AND c.relname = v_higher_parent_table::name
        ) SELECT n.nspname, c.relname, p.control, p.epoch
        INTO v_higher_parent_schema, v_higher_parent_table, v_higher_parent_control, v_higher_parent_epoch
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN top_oid t ON c.oid = t.top_parent_oid
        JOIN partman5.part_config p ON p.parent_table = n.nspname||'.'||c.relname;

        IF v_higher_parent_table IS NOT NULL THEN
            SELECT general_type INTO v_higher_control_type
            FROM partman5.check_control_type(v_higher_parent_schema, v_higher_parent_table, v_higher_parent_control);
            IF v_higher_control_type <> 'id' or (v_higher_control_type = 'id' AND v_higher_parent_epoch <> 'none') THEN
                -- The parent above the p_parent_table parameter is not partitioned by ID
                --   so don't check for max values in parents that aren't partitioned by ID.
                -- This avoids missing child tables in subpartition sets that have differing ID data
                EXIT;
            END IF;
            -- v_top_parent initially set in DECLARE
            v_top_parent_schema := v_higher_parent_schema;
            v_top_parent_table := v_higher_parent_table;
        END IF;
    END LOOP;

    -- If custom start partition is set, use that.
    -- If custom start is not set and there is already data, start partitioning with the highest current value and ensure it's grabbed from highest top parent table
    IF p_start_partition IS NOT NULL THEN
        v_max := p_start_partition::bigint;
    ELSE
        v_sql := format('SELECT COALESCE(trunc(max(%I))::bigint, 0) FROM %I.%I LIMIT 1'
                    , p_control
                    , v_top_parent_schema
                    , v_top_parent_table);
        EXECUTE v_sql INTO v_max;
    END IF;

    v_starting_partition_id := (v_max - (v_max % v_id_interval));
    FOR i IN 0..p_premake LOOP
        -- Only make previous partitions if ID value is less than the starting value and positive (and custom start partition wasn't set)
        IF p_start_partition IS NULL AND
            (v_starting_partition_id - (v_id_interval*i)) > 0 AND
            (v_starting_partition_id - (v_id_interval*i)) < v_starting_partition_id
        THEN
            v_partition_id_array = array_append(v_partition_id_array, (v_starting_partition_id - v_id_interval*i));
        END IF;
        v_partition_id_array = array_append(v_partition_id_array, (v_id_interval*i) + v_starting_partition_id);
    END LOOP;

    INSERT INTO partman5.part_config (
        parent_table
        , partition_type
        , partition_interval
        , control
        , premake
        , constraint_cols
        , automatic_maintenance
        , jobmon
        , template_table
        , inherit_privileges
        , default_table
        , date_trunc_interval)
    VALUES (
        p_parent_table
        , p_type
        , v_id_interval
        , p_control
        , p_premake
        , p_constraint_cols
        , p_automatic_maintenance
        , p_jobmon
        , v_template_schema||'.'||v_template_tablename
        , v_inherit_privileges
        , p_default_table
        , p_date_trunc_interval);

    v_last_partition_created := partman5.create_partition_id(p_parent_table, v_partition_id_array);

    IF v_last_partition_created = false THEN
        -- This can happen with subpartitioning when future or past partitions prevent child creation because they're out of range of the parent
        -- See if it's actually a subpartition of a parent id partition
        WITH top_oid AS (
            SELECT i.inhparent AS top_parent_oid
            FROM pg_catalog.pg_inherits i
            JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = v_parent_tablename::name
            AND n.nspname = v_parent_schema::name
        ) SELECT n.nspname||'.'||c.relname
        INTO v_top_parent_table
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN top_oid t ON c.oid = t.top_parent_oid
        JOIN partman5.part_config p ON p.parent_table = n.nspname||'.'||c.relname;

        IF v_top_parent_table IS NOT NULL THEN
            -- Create the lowest possible partition that is within the boundary of the parent
             SELECT child_start_id INTO v_parent_partition_id FROM partman5.show_partition_info(p_parent_table, p_parent_table := v_top_parent_table);
            IF v_starting_partition_id >= v_parent_partition_id THEN
                WHILE v_starting_partition_id >= v_parent_partition_id LOOP
                    v_starting_partition_id := v_starting_partition_id - v_id_interval;
                END LOOP;
                v_starting_partition_id := v_starting_partition_id + v_id_interval; -- add one back since while loop set it one lower than is needed
            ELSIF v_starting_partition_id < v_parent_partition_id THEN
                WHILE v_starting_partition_id < v_parent_partition_id LOOP
                    v_starting_partition_id := v_starting_partition_id + v_id_interval;
                END LOOP;
                -- Don't need to remove one since new starting id will fit in top parent interval
            END IF;
            v_partition_id_array = NULL;
            v_partition_id_array = array_append(v_partition_id_array, v_starting_partition_id);
            v_last_partition_created := partman5.create_partition_id(p_parent_table, v_partition_id_array);
        ELSE
            -- Currently unknown edge case if code gets here
            RAISE WARNING 'No child tables created. Check that all child tables did not already exist and may not have been part of partition set. Given parent has still been configured with pg_partman, but may not have expected children. Please review schema and config to confirm things are ok.';
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', 'Done');
                IF v_step_overflow_id IS NOT NULL THEN
                    PERFORM fail_job(v_job_id);
                ELSE
                    PERFORM close_job(v_job_id);
                END IF;
            END IF;

            EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

            RETURN v_success;
        END IF;
    END IF; -- End v_last_partition_created IF

END IF; -- End IF id

IF p_default_table THEN
    -- Add default partition

    v_default_partition := partman5.check_name_length(v_parent_tablename, '_default', FALSE);
    v_sql := 'CREATE';

    -- Left this here as reminder to revisit once core PG figures out how it is handling changing unlogged stats
    -- Currently handed via template table below
    /*
    IF v_unlogged = 'u' THEN
         v_sql := v_sql ||' UNLOGGED';
    END IF;
    */

    -- Same INCLUDING list is used in create_partition_*(). INDEXES is handled when partition is attached if it's supported.
    v_sql := v_sql || format(' TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE INCLUDING COMMENTS INCLUDING GENERATED)'
        , v_parent_schema, v_default_partition, v_parent_schema, v_parent_tablename);
    IF v_parent_tablespace IS NOT NULL THEN
        v_sql := format('%s TABLESPACE %I ', v_sql, v_parent_tablespace);
    END IF;
    EXECUTE v_sql;

    v_sql := format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I DEFAULT'
        , v_parent_schema, v_parent_tablename, v_parent_schema, v_default_partition);
    EXECUTE v_sql;

    PERFORM partman5.inherit_replica_identity(v_parent_schema, v_parent_tablename, v_default_partition);

    -- Manage template inherited properties
    PERFORM partman5.inherit_template_properties(p_parent_table, v_parent_schema, v_default_partition);

END IF;


IF v_jobmon_schema IS NOT NULL THEN
    PERFORM update_step(v_step_id, 'OK', 'Done');
    IF v_step_overflow_id IS NOT NULL THEN
        PERFORM fail_job(v_job_id);
    ELSE
        PERFORM close_job(v_job_id);
    END IF;
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

v_success := true;

RETURN v_success;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE PARENT: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''Partition creation for table '||p_parent_table||' failed'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.create_parent(p_parent_table text, p_control text, p_interval text, p_type text, p_epoch text, p_premake integer, p_start_partition text, p_default_table boolean, p_automatic_maintenance text, p_constraint_cols text[], p_template_table text, p_jobmon boolean, p_date_trunc_interval text) OWNER TO api;

--
-- Name: create_partition_id(text, bigint[], text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.create_partition_id(p_parent_table text, p_partition_ids bigint[], p_start_partition text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_control                       text;
v_control_type                  text;
v_exists                        text;
v_id                            bigint;
v_inherit_privileges            boolean;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_new_search_path               text;
v_old_search_path               text;
v_parent_oid                    oid;
v_parent_schema                 text;
v_parent_tablename              text;
v_parent_tablespace             name;
v_partition_interval            bigint;
v_partition_created             boolean := false;
v_partition_name                text;
v_partition_type                text;
v_row                           record;
v_sql                           text;
v_step_id                       bigint;
v_sub_control                   text;
v_sub_partition_type            text;
v_sub_id_max                    bigint;
v_sub_id_min                    bigint;
v_template_table                text;

BEGIN
/*
 * Function to create id partitions
 */

SELECT control
    , partition_interval::bigint -- this shared field also used in partition_time as interval
    , partition_type
    , jobmon
    , template_table
    , inherit_privileges
INTO v_control
    , v_partition_interval
    , v_partition_type
    , v_jobmon
    , v_template_table
    , v_inherit_privileges
FROM partman5.part_config
WHERE parent_table = p_parent_table;

IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

SELECT n.nspname
    , c.relname
    , c.oid
    , t.spcname
INTO v_parent_schema
    , v_parent_tablename
    , v_parent_oid
    , v_parent_tablespace
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
LEFT OUTER JOIN pg_catalog.pg_tablespace t ON c.reltablespace = t.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);
IF v_control_type <> 'id' THEN
    RAISE EXCEPTION 'ERROR: Given parent table is not set up for id/serial partitioning';
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

-- Determine if this table is a child of a subpartition parent. If so, get limits of what child tables can be created based on parent suffix
SELECT sub_min::bigint, sub_max::bigint INTO v_sub_id_min, v_sub_id_max FROM partman5.check_subpartition_limits(p_parent_table, 'id');

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN CREATE TABLE: %s', p_parent_table));
END IF;

FOREACH v_id IN ARRAY p_partition_ids LOOP
-- Do not create the child table if it's outside the bounds of the top parent.
    IF v_sub_id_min IS NOT NULL THEN
        IF v_id < v_sub_id_min OR v_id >= v_sub_id_max THEN
            CONTINUE;
        END IF;
    END IF;

    v_partition_name := partman5.check_name_length(v_parent_tablename, v_id::text, TRUE);
    -- If child table already exists, skip creation
    -- Have to check pg_class because if subpartitioned, table will not be in pg_tables
    SELECT c.relname INTO v_exists
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = v_parent_schema::name AND c.relname = v_partition_name::name;
    IF v_exists IS NOT NULL THEN
        CONTINUE;
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Creating new partition '||v_partition_name||' with interval from '||v_id||' to '||(v_id + v_partition_interval)-1);
    END IF;

    -- Close parentheses on LIKE are below due to differing requirements of subpartitioning
    -- Same INCLUDING list is used in create_parent()
    v_sql := format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE INCLUDING COMMENTS INCLUDING GENERATED) '
            , v_parent_schema
            , v_partition_name
            , v_parent_schema
            , v_parent_tablename);

    IF v_parent_tablespace IS NOT NULL THEN
        v_sql := format('%s TABLESPACE %I ', v_sql, v_parent_tablespace);
    END IF;

    SELECT sub_partition_type, sub_control INTO v_sub_partition_type, v_sub_control
    FROM partman5.part_config_sub
    WHERE sub_parent = p_parent_table;
    IF v_sub_partition_type = 'range' THEN
        v_sql :=  format('%s PARTITION BY RANGE (%I) ', v_sql, v_sub_control);
    ELSIF v_sub_partition_type = 'list' THEN
        v_sql :=  format('%s PARTITION BY LIST (%I) ', v_sql, v_sub_control);
    END IF;

    RAISE DEBUG 'create_partition_id v_sql: %', v_sql;
    EXECUTE v_sql;

    IF v_template_table IS NOT NULL THEN
        PERFORM partman5.inherit_template_properties(p_parent_table, v_parent_schema, v_partition_name);
    END IF;

    IF v_partition_type = 'range' THEN
        EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)'
            , v_parent_schema
            , v_parent_tablename
            , v_parent_schema
            , v_partition_name
            , v_id
            , v_id + v_partition_interval);
    ELSIF v_partition_type = 'list' THEN
        EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES IN (%L)'
            , v_parent_schema
            , v_parent_tablename
            , v_parent_schema
            , v_partition_name
            , v_id);
    ELSE
        RAISE EXCEPTION 'create_partition_id: Unexpected partition type (%) encountered in part_config table for parent table %', v_partition_type, p_parent_table;
    END IF;

    -- NOTE: Privileges not automatically inherited. Only do so if config flag is set
    IF v_inherit_privileges = TRUE THEN
        PERFORM partman5.apply_privileges(v_parent_schema, v_parent_tablename, v_parent_schema, v_partition_name, v_job_id);
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    -- Will only loop once and only if sub_partitioning is actually configured
    -- This seemed easier than assigning a bunch of variables then doing an IF condition
    -- This column list must be kept consistent between:
    --   create_parent, check_subpart_sameconfig, create_partition_id, create_partition_time, dump_partitioned_table_definition, and table definition
    FOR v_row IN
        SELECT
            sub_parent
            , sub_control
            , sub_partition_interval
            , sub_partition_type
            , sub_premake
            , sub_automatic_maintenance
            , sub_template_table
            , sub_retention
            , sub_retention_schema
            , sub_retention_keep_index
            , sub_retention_keep_table
            , sub_epoch
            , sub_constraint_cols
            , sub_optimize_constraint
            , sub_infinite_time_partitions
            , sub_jobmon
            , sub_inherit_privileges
            , sub_constraint_valid
            , sub_date_trunc_interval
            , sub_ignore_default_data
            , sub_default_table
            , sub_maintenance_order
            , sub_retention_keep_publication
        FROM partman5.part_config_sub
        WHERE sub_parent = p_parent_table
    LOOP
        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, 'Subpartitioning '||v_partition_name);
        END IF;
        v_sql := format('SELECT partman5.create_parent(
                 p_parent_table := %L
                , p_control := %L
                , p_type := %L
                , p_interval := %L
                , p_default_table := %L
                , p_constraint_cols := %L
                , p_premake := %L
                , p_automatic_maintenance := %L
                , p_epoch := %L
                , p_template_table := %L
                , p_jobmon := %L
                , p_start_partition := %L
                , p_date_trunc_interval := %L )'
            , v_parent_schema||'.'||v_partition_name
            , v_row.sub_control
            , v_row.sub_partition_type
            , v_row.sub_partition_interval
            , v_row.sub_default_table
            , v_row.sub_constraint_cols
            , v_row.sub_premake
            , v_row.sub_automatic_maintenance
            , v_row.sub_epoch
            , v_row.sub_template_table
            , v_row.sub_jobmon
            , p_start_partition
            , v_row.sub_date_trunc_interval);
        RAISE DEBUG 'create_partition_id (create_parent loop): %', v_sql;
        EXECUTE v_sql;

        UPDATE partman5.part_config SET
            retention_schema = v_row.sub_retention_schema
            , retention_keep_table = v_row.sub_retention_keep_table
            , optimize_constraint = v_row.sub_optimize_constraint
            , infinite_time_partitions = v_row.sub_infinite_time_partitions
            , inherit_privileges = v_row.sub_inherit_privileges
            , constraint_valid = v_row.sub_constraint_valid
            , ignore_default_data = v_row.sub_ignore_default_data
            , maintenance_order = v_row.sub_maintenance_order
            , retention_keep_publication = v_row.sub_retention_keep_publication
        WHERE parent_table = v_parent_schema||'.'||v_partition_name;

        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', 'Done');
        END IF;

    END LOOP; -- end sub partitioning LOOP

    -- NOTE: Replication identity not automatically inherited as of PG16 (revisit in future versions)
    PERFORM partman5.inherit_replica_identity(v_parent_schema, v_parent_tablename, v_partition_name);

    -- Manage additional constraints if set
    PERFORM partman5.apply_constraints(p_parent_table, p_job_id := v_job_id);

    v_partition_created := true;

END LOOP;

IF v_jobmon_schema IS NOT NULL THEN
    IF v_partition_created = false THEN
        v_step_id := add_step(v_job_id, format('No partitions created for partition set: %s', p_parent_table));
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    PERFORM close_job(v_job_id);
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

RETURN v_partition_created;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE TABLE: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.create_partition_id(p_parent_table text, p_partition_ids bigint[], p_start_partition text) OWNER TO api;

--
-- Name: create_partition_time(text, timestamp with time zone[], text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.create_partition_time(p_parent_table text, p_partition_times timestamp with time zone[], p_start_partition text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_control                       text;
v_control_type                  text;
v_datetime_string               text;
v_epoch                         text;
v_exists                        smallint;
v_inherit_privileges            boolean;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_new_search_path               text;
v_old_search_path               text;
v_parent_oid                    oid;
v_parent_schema                 text;
v_parent_tablename              text;
v_parent_tablespace             name;
v_partition_created             boolean := false;
v_partition_name                text;
v_partition_suffix              text;
v_partition_expression          text;
v_partition_interval            interval;
v_partition_timestamp_end       timestamptz;
v_partition_timestamp_start     timestamptz;
v_row                           record;
v_sql                           text;
v_step_id                       bigint;
v_step_overflow_id              bigint;
v_sub_control                   text;
v_sub_partition_type            text;
v_sub_timestamp_max             timestamptz;
v_sub_timestamp_min             timestamptz;
v_template_table                text;
v_time                          timestamptz;

BEGIN
/*
 * Function to create a child table in a time-based partition set
 */

SELECT control
    , partition_interval::interval -- this shared field also used in partition_id as bigint
    , epoch
    , jobmon
    , datetime_string
    , template_table
    , inherit_privileges
INTO v_control
    , v_partition_interval
    , v_epoch
    , v_jobmon
    , v_datetime_string
    , v_template_table
    , v_inherit_privileges
FROM partman5.part_config
WHERE parent_table = p_parent_table;

IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

SELECT n.nspname
    , c.relname
    , c.oid
    , t.spcname
INTO v_parent_schema
    , v_parent_tablename
    , v_parent_oid
    , v_parent_tablespace
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
LEFT OUTER JOIN pg_catalog.pg_tablespace t ON c.reltablespace = t.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);
IF v_control_type <> 'time' THEN
    IF (v_control_type = 'id' AND v_epoch = 'none') OR v_control_type <> 'id' THEN
        RAISE EXCEPTION 'Cannot run on partition set without time based control column or epoch flag set with an id column. Found control: %, epoch: %', v_control_type, v_epoch;
    END IF;
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

-- Determine if this table is a child of a subpartition parent. If so, get limits of what child tables can be created based on parent suffix
SELECT sub_min::timestamptz, sub_max::timestamptz INTO v_sub_timestamp_min, v_sub_timestamp_max FROM partman5.check_subpartition_limits(p_parent_table, 'time');

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN CREATE TABLE: %s', p_parent_table));
END IF;

v_partition_expression := CASE
    WHEN v_epoch = 'seconds' THEN format('to_timestamp(%I)', v_control)
    WHEN v_epoch = 'milliseconds' THEN format('to_timestamp((%I/1000)::float)', v_control)
    WHEN v_epoch = 'nanoseconds' THEN format('to_timestamp((%I/1000000000)::float)', v_control)
    ELSE format('%I', v_control)
END;
RAISE DEBUG 'create_partition_time: v_partition_expression: %', v_partition_expression;

FOREACH v_time IN ARRAY p_partition_times LOOP
    v_partition_timestamp_start := v_time;
    BEGIN
        v_partition_timestamp_end := v_time + v_partition_interval;
    EXCEPTION WHEN datetime_field_overflow THEN
        RAISE WARNING 'Attempted partition time interval is outside PostgreSQL''s supported time range.
            Child partition creation after time % skipped', v_time;
        v_step_overflow_id := add_step(v_job_id, 'Attempted partition time interval is outside PostgreSQL''s supported time range.');
        PERFORM update_step(v_step_overflow_id, 'CRITICAL', 'Child partition creation after time '||v_time||' skipped');

        CONTINUE;
    END;

    -- Do not create the child table if it's outside the bounds of the top parent.
    IF v_sub_timestamp_min IS NOT NULL THEN
        IF v_time < v_sub_timestamp_min OR v_time >= v_sub_timestamp_max THEN

            RAISE DEBUG 'create_partition_time: p_parent_table: %, v_time: %, v_sub_timestamp_min: %, v_sub_timestamp_max: %'
                    , p_parent_table, v_time, v_sub_timestamp_min, v_sub_timestamp_max;

            CONTINUE;
        END IF;
    END IF;

    -- This suffix generation code is in partition_data_time() as well
    v_partition_suffix := to_char(v_time, v_datetime_string);
    v_partition_name := partman5.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);
    -- Check if child exists.
    SELECT count(*) INTO v_exists
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = v_parent_schema::name
    AND c.relname = v_partition_name::name;

    IF v_exists > 0 THEN
        CONTINUE;
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Creating new partition %s.%s with interval from %s to %s'
                                                , v_parent_schema
                                                , v_partition_name
                                                , v_partition_timestamp_start
                                                , v_partition_timestamp_end-'1sec'::interval));
    END IF;

    v_sql := 'CREATE';

    /*
    -- As of PG12, the unlogged/logged status of a parent table cannot be changed via an ALTER TABLE in order to affect its children.
    -- As of partman v4.2x, the unlogged state will be managed via the template table
    -- TODO Test UNLOGGED status in PG17 to see if this can be done without template yet. Add to create_partition_id then as well.
    SELECT relpersistence INTO v_unlogged
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_parent_tablename::name
    AND n.nspname = v_parent_schema::name;

    IF v_unlogged = 'u' THEN
        v_sql := v_sql || ' UNLOGGED';
    END IF;
    */

    -- Same INCLUDING list is used in create_parent()
    v_sql := v_sql || format(' TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE INCLUDING COMMENTS INCLUDING GENERATED) '
                                , v_parent_schema
                                , v_partition_name
                                , v_parent_schema
                                , v_parent_tablename);

    IF v_parent_tablespace IS NOT NULL THEN
        v_sql := format('%s TABLESPACE %I ', v_sql, v_parent_tablespace);
    END IF;

    SELECT sub_partition_type, sub_control INTO v_sub_partition_type, v_sub_control
    FROM partman5.part_config_sub
    WHERE sub_parent = p_parent_table;
    IF v_sub_partition_type = 'range' THEN
        v_sql :=  format('%s PARTITION BY RANGE (%I) ', v_sql, v_sub_control);
    END IF;

    RAISE DEBUG 'create_partition_time v_sql: %', v_sql;
    EXECUTE v_sql;

    IF v_template_table IS NOT NULL THEN
        PERFORM partman5.inherit_template_properties(p_parent_table, v_parent_schema, v_partition_name);
    END IF;

    IF v_epoch = 'none' THEN
        -- Attach with normal, time-based values for built-in constraint
        EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)'
            , v_parent_schema
            , v_parent_tablename
            , v_parent_schema
            , v_partition_name
            , v_partition_timestamp_start
            , v_partition_timestamp_end);
    ELSE
        -- Must attach with integer based values for built-in constraint and epoch
        IF v_epoch = 'seconds' THEN
            EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)'
                , v_parent_schema
                , v_parent_tablename
                , v_parent_schema
                , v_partition_name
                , EXTRACT('epoch' FROM v_partition_timestamp_start)::bigint
                , EXTRACT('epoch' FROM v_partition_timestamp_end)::bigint);
        ELSIF v_epoch = 'milliseconds' THEN
            EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)'
                , v_parent_schema
                , v_parent_tablename
                , v_parent_schema
                , v_partition_name
                , EXTRACT('epoch' FROM v_partition_timestamp_start)::bigint * 1000
                , EXTRACT('epoch' FROM v_partition_timestamp_end)::bigint * 1000);
        ELSIF v_epoch = 'nanoseconds' THEN
            EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)'
                , v_parent_schema
                , v_parent_tablename
                , v_parent_schema
                , v_partition_name
                , EXTRACT('epoch' FROM v_partition_timestamp_start)::bigint * 1000000000
                , EXTRACT('epoch' FROM v_partition_timestamp_end)::bigint * 1000000000);
        END IF;
        -- Create secondary, time-based constraint since built-in's constraint is already integer based
        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%s >= %L AND %4$s < %6$L)'
            , v_parent_schema
            , v_partition_name
            , v_partition_name||'_partition_check'
            , v_partition_expression
            , v_partition_timestamp_start
            , v_partition_timestamp_end);
    END IF;

    -- NOTE: Privileges not automatically inherited. Only do so if config flag is set
    IF v_inherit_privileges = TRUE THEN
        PERFORM partman5.apply_privileges(v_parent_schema, v_parent_tablename, v_parent_schema, v_partition_name, v_job_id);
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    -- Will only loop once and only if sub_partitioning is actually configured
    -- This seemed easier than assigning a bunch of variables and doing an IF condition
    -- This column list must be kept consistent between:
    --   create_parent, check_subpart_sameconfig, create_partition_id, create_partition_time, dump_partitioned_table_definition, and table definition
    FOR v_row IN
        SELECT
            sub_parent
            , sub_control
            , sub_partition_interval
            , sub_partition_type
            , sub_premake
            , sub_automatic_maintenance
            , sub_template_table
            , sub_retention
            , sub_retention_schema
            , sub_retention_keep_index
            , sub_retention_keep_table
            , sub_epoch
            , sub_constraint_cols
            , sub_optimize_constraint
            , sub_infinite_time_partitions
            , sub_jobmon
            , sub_inherit_privileges
            , sub_constraint_valid
            , sub_date_trunc_interval
            , sub_ignore_default_data
            , sub_default_table
            , sub_maintenance_order
            , sub_retention_keep_publication
        FROM partman5.part_config_sub
        WHERE sub_parent = p_parent_table
    LOOP
        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, format('Subpartitioning %s.%s', v_parent_schema, v_partition_name));
        END IF;
        v_sql := format('SELECT partman5.create_parent(
                 p_parent_table := %L
                , p_control := %L
                , p_interval := %L
                , p_type := %L
                , p_default_table := %L
                , p_constraint_cols := %L
                , p_premake := %L
                , p_automatic_maintenance := %L
                , p_epoch := %L
                , p_template_table := %L
                , p_jobmon := %L
                , p_start_partition := %L
                , p_date_trunc_interval := %L )'
            , v_parent_schema||'.'||v_partition_name
            , v_row.sub_control
            , v_row.sub_partition_interval
            , v_row.sub_partition_type
            , v_row.sub_default_table
            , v_row.sub_constraint_cols
            , v_row.sub_premake
            , v_row.sub_automatic_maintenance
            , v_row.sub_epoch
            , v_row.sub_template_table
            , v_row.sub_jobmon
            , p_start_partition
            , v_row.sub_date_trunc_interval);

        RAISE DEBUG 'create_partition_time (create_parent loop): %', v_sql;
        EXECUTE v_sql;

        UPDATE partman5.part_config SET
            retention_schema = v_row.sub_retention_schema
            , retention_keep_table = v_row.sub_retention_keep_table
            , optimize_constraint = v_row.sub_optimize_constraint
            , infinite_time_partitions = v_row.sub_infinite_time_partitions
            , inherit_privileges = v_row.sub_inherit_privileges
            , constraint_valid = v_row.sub_constraint_valid
            , ignore_default_data = v_row.sub_ignore_default_data
            , maintenance_order = v_row.sub_maintenance_order
            , retention_keep_publication = v_row.sub_retention_keep_publication
        WHERE parent_table = v_parent_schema||'.'||v_partition_name;

    END LOOP; -- end sub partitioning LOOP

    -- NOTE: Replication identity not automatically inherited as of PG16 (revisit in future versions)
    PERFORM partman5.inherit_replica_identity(v_parent_schema, v_parent_tablename, v_partition_name);

    -- Manage additional constraints if set
    PERFORM partman5.apply_constraints(p_parent_table, p_job_id := v_job_id);

    v_partition_created := true;

END LOOP;

IF v_jobmon_schema IS NOT NULL THEN
    IF v_partition_created = false THEN
        v_step_id := add_step(v_job_id, format('No partitions created for partition set: %s. Attempted intervals: %s', p_parent_table, p_partition_times));
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    IF v_step_overflow_id IS NOT NULL THEN
        PERFORM fail_job(v_job_id);
    ELSE
        PERFORM close_job(v_job_id);
    END IF;
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

RETURN v_partition_created;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE TABLE: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$_$;


ALTER FUNCTION partman5.create_partition_time(p_parent_table text, p_partition_times timestamp with time zone[], p_start_partition text) OWNER TO api;

--
-- Name: create_sub_parent(text, text, text, text, boolean, text, text[], integer, text, text, boolean, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.create_sub_parent(p_top_parent text, p_control text, p_interval text, p_type text DEFAULT 'range'::text, p_default_table boolean DEFAULT true, p_declarative_check text DEFAULT NULL::text, p_constraint_cols text[] DEFAULT NULL::text[], p_premake integer DEFAULT 4, p_start_partition text DEFAULT NULL::text, p_epoch text DEFAULT 'none'::text, p_jobmon boolean DEFAULT true, p_date_trunc_interval text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

v_child_interval        interval;
v_child_start_id        bigint;
v_child_start_time      timestamptz;
v_control               text;
v_control_parent_type   text;
v_control_sub_type      text;
v_parent_epoch          text;
v_parent_interval       text;
v_parent_schema         text;
v_parent_tablename      text;
v_part_col              text;
v_partition_id_array    bigint[];
v_partition_time_array  timestamptz[];
v_relkind               char;
v_recreate_child        boolean := false;
v_row                   record;
v_sql                   text;
v_success               boolean := false;
v_template_table        text;

BEGIN
/*
 * Create a partition set that is a subpartition of an already existing partition set.
 * Given the parent table of any current partition set, it will turn all existing children into parent tables of their own partition sets
 *      using the configuration options given as parameters to this function.
 * Uses another config table that allows for turning all future child partitions into a new parent automatically.
 */

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_top_parent, '.', 1)::name
AND c.relname = split_part(p_top_parent, '.', 2)::name;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs. Please create parent table first: %', p_top_parent;
    END IF;

IF NOT partman5.check_partition_type(p_type) THEN
    RAISE EXCEPTION '% is not a valid partitioning type', p_type;
END IF;

SELECT partition_interval, control, epoch, template_table
INTO v_parent_interval, v_control, v_parent_epoch, v_template_table
FROM partman5.part_config
WHERE parent_table = p_top_parent;
IF v_parent_interval IS NULL THEN
    RAISE EXCEPTION 'Cannot subpartition a table that is not managed by pg_partman already. Given top parent table not found in partman5.part_config: %', p_top_parent;
END IF;

IF (lower(p_declarative_check) <> 'yes' OR p_declarative_check IS NULL) THEN
    RAISE EXCEPTION 'Subpartitioning is a DESTRUCTIVE process unless all child tables are already themselves subpartitioned. All child tables, and therefore ALL DATA, may be destroyed since the parent table must be declared as partitioned on first creation and cannot be altered later. See docs for more info. Set p_declarative_check parameter to "yes" if you are sure this is ok.';
END IF;

SELECT general_type INTO v_control_parent_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

-- Add the given parameters to the part_config_sub table first in case create_partition_* functions are called below
-- All sub-partition parents must use the same template table, so ensure the one from the given parent is obtained and used.
INSERT INTO partman5.part_config_sub (
    sub_parent
    , sub_control
    , sub_partition_interval
    , sub_partition_type
    , sub_default_table
    , sub_constraint_cols
    , sub_premake
    , sub_automatic_maintenance
    , sub_epoch
    , sub_jobmon
    , sub_template_table
    , sub_date_trunc_interval)
VALUES (
    p_top_parent
    , p_control
    , p_interval
    , p_type
    , p_default_table
    , p_constraint_cols
    , p_premake
    , 'on'
    , p_epoch
    , p_jobmon
    , v_template_table
    , p_date_trunc_interval);

FOR v_row IN
    -- Loop through all current children to turn them into partitioned tables
    SELECT partition_schemaname AS child_schema, partition_tablename AS child_tablename FROM partman5.show_partitions(p_top_parent)
LOOP

    SELECT general_type INTO v_control_sub_type FROM partman5.check_control_type(v_row.child_schema, v_row.child_tablename, p_control);

    SELECT c.relkind INTO v_relkind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = v_row.child_schema
    AND c.relname = v_row.child_tablename;

    -- If both parent and sub-parent are the same partition type (time/id), ensure intereval of sub-parent is less than parent
    IF (v_control_parent_type = 'time' AND v_control_sub_type = 'time') OR
       (v_control_parent_type = 'id' AND v_parent_epoch <> 'none' AND v_control_sub_type = 'id' AND p_epoch <> 'none') THEN

        v_child_interval := p_interval::interval;
        IF v_child_interval < '1 second'::interval THEN
            RAISE EXCEPTION 'Partitioning interval must be 1 second or greater';
        END IF;

        IF v_child_interval >= v_parent_interval::interval THEN
            RAISE EXCEPTION 'Sub-partition interval cannot be greater than or equal to the given parent interval';
        END IF;
        IF (v_child_interval = '1 week' AND v_parent_interval::interval > '1 week'::interval)
            OR (p_date_trunc_interval = 'week') THEN
            RAISE EXCEPTION 'Due to conflicting data boundaries between weeks and any larger interval of time, pg_partman cannot support a sub-partition interval of weekly time periods';
        END IF;

    ELSIF v_control_parent_type = 'id' AND v_control_sub_type = 'id' AND v_parent_epoch = 'none' AND p_epoch = 'none' THEN
        IF p_interval::bigint >= v_parent_interval::bigint THEN
            RAISE EXCEPTION 'Sub-partition interval cannot be greater than or equal to the given parent interval';
        END IF;
    END IF;

    IF v_relkind <> 'p' THEN
        -- Not partitioned already. Drop it and recreate as such.
        RAISE WARNING 'Child table % is not partitioned. Dropping and recreating with partitioning'
                        , v_row.child_schema||'.'||v_row.child_tablename;
        SELECT child_start_time, child_start_id INTO v_child_start_time, v_child_start_id
        FROM partman5.show_partition_info(v_row.child_schema||'.'||v_row.child_tablename
                                                , v_parent_interval
                                                , p_top_parent);
        EXECUTE format('DROP TABLE %I.%I', v_row.child_schema, v_row.child_tablename);
        v_recreate_child := true;

        IF v_child_start_id IS NOT NULL THEN
            v_partition_id_array[0] := v_child_start_id;
            PERFORM partman5.create_partition_id(p_top_parent, v_partition_id_array, p_start_partition);
        ELSIF v_child_start_time IS NOT NULL THEN
            v_partition_time_array[0] := v_child_start_time;
            PERFORM partman5.create_partition_time(p_top_parent, v_partition_time_array, p_start_partition);
        END IF;
    ELSE
        SELECT a.attname
        INTO v_part_col
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = v_row.child_schema::name
        AND c.relname = v_row.child_tablename::name
        AND attnum IN (SELECT unnest(partattrs) FROM pg_partitioned_table p WHERE a.attrelid = p.partrelid);

        IF p_control <> v_part_col THEN
            RAISE EXCEPTION 'Attempted to sub-partition an existing table that has the partition column (%) defined differently than the control column given (%)', v_part_col, p_control;
        ELSE -- Child table is already subpartitioned properly. Skip the rest.
            CONTINUE;
        END IF;
    END IF; -- end 'p' relkind check

IF v_recreate_child = false THEN
    -- Always call create_parent() if child table wasn't recreated above.
    -- If it was, the create_partition_*() functions called above also call create_parent if any of the tables
    --  it creates are in the part_config_sub table. Since it was inserted there above,
    --  it should call it appropriately
        v_sql := format('SELECT partman5.create_parent(
                 p_parent_table := %L
                , p_control := %L
                , p_interval := %L
                , p_type := %L
                , p_default_table := %L
                , p_constraint_cols := %L
                , p_premake := %L
                , p_automatic_maintenance := %L
                , p_start_partition := %L
                , p_epoch := %L
                , p_template_table := %L
                , p_jobmon := %L
                , p_date_trunc_interval := %L)'
            , v_row.child_schema||'.'||v_row.child_tablename
            , p_control
            , p_interval
            , p_type
            , p_default_table
            , p_constraint_cols
            , p_premake
            , 'on'
            , p_start_partition
            , p_epoch
            , v_template_table
            , p_jobmon
            , p_date_trunc_interval);
        RAISE DEBUG 'create_sub_parent: create parent v_sql: %', v_sql;
        EXECUTE v_sql;
    END IF; -- end recreate check

END LOOP;

v_success := true;

RETURN v_success;

END
$$;


ALTER FUNCTION partman5.create_sub_parent(p_top_parent text, p_control text, p_interval text, p_type text, p_default_table boolean, p_declarative_check text, p_constraint_cols text[], p_premake integer, p_start_partition text, p_epoch text, p_jobmon boolean, p_date_trunc_interval text) OWNER TO api;

--
-- Name: drop_constraints(text, text, boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.drop_constraints(p_parent_table text, p_child_table text, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_child_schemaname              text;
v_child_tablename               text;
v_col                           text;
v_constraint_cols               text[];
v_existing_constraint_name      text;
v_exists                        boolean := FALSE;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_new_search_path               text;
v_old_search_path               text;
v_sql                           text;
v_step_id                       bigint;

BEGIN

SELECT constraint_cols
    , jobmon
INTO v_constraint_cols
    , v_jobmon
FROM partman5.part_config
WHERE parent_table = p_parent_table;

IF v_constraint_cols IS NULL THEN
    RAISE EXCEPTION 'Given parent table (%) not set up for constraint management (constraint_cols is NULL)', p_parent_table;
END IF;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        IF length(v_old_search_path) > 0 THEN
           v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
        ELSE
            v_new_search_path := 'partman5,pg_temp';
        END IF;
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');
    END IF;
END IF;

SELECT schemaname, tablename INTO v_child_schemaname, v_child_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(p_child_table, '.', 1)::name
AND tablename = split_part(p_child_table, '.', 2)::name;
IF v_child_tablename IS NULL THEN
    RAISE EXCEPTION 'Unable to find given child table in system catalogs: %', p_child_table;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN DROP CONSTRAINT: %s', p_parent_table));
    v_step_id := add_step(v_job_id, 'Entering constraint drop loop');
    PERFORM update_step(v_step_id, 'OK', 'Done');
END IF;


FOREACH v_col IN ARRAY v_constraint_cols
LOOP
    SELECT con.conname
    INTO v_existing_constraint_name
    FROM pg_catalog.pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    JOIN pg_catalog.pg_attribute a ON con.conrelid = a.attrelid
    WHERE c.relname = v_child_tablename
        AND n.nspname = v_child_schemaname
        AND con.conname LIKE 'partmanconstr_%'
        AND con.contype = 'c'
        AND a.attname = v_col
        AND ARRAY[a.attnum] OPERATOR(pg_catalog.<@) con.conkey
        AND a.attisdropped = false;

    IF v_existing_constraint_name IS NOT NULL THEN
        v_exists := TRUE;
        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, format('Dropping constraint on column: %s', v_col));
        END IF;
        v_sql := format('ALTER TABLE %I.%I DROP CONSTRAINT %I', v_child_schemaname, v_child_tablename, v_existing_constraint_name);
        IF p_debug THEN
            RAISE NOTICE 'Constraint drop query: %', v_sql;
        END IF;
        EXECUTE v_sql;
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', format('Drop constraint query: %s', v_sql));
        END IF;
    END IF;

END LOOP;

IF v_jobmon_schema IS NOT NULL AND v_exists IS FALSE THEN
    v_step_id := add_step(v_job_id, format('No constraints found to drop on child table: %s', p_child_table));
    PERFORM update_step(v_step_id, 'OK', 'Done');
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN DROP CONSTRAINT: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.drop_constraints(p_parent_table text, p_child_table text, p_debug boolean) OWNER TO api;

--
-- Name: drop_partition_id(text, bigint, boolean, boolean, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.drop_partition_id(p_parent_table text, p_retention bigint DEFAULT NULL::bigint, p_keep_table boolean DEFAULT NULL::boolean, p_keep_index boolean DEFAULT NULL::boolean, p_retention_schema text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                          text;
ex_detail                           text;
ex_hint                             text;
ex_message                          text;
v_adv_lock                          boolean;
v_control                           text;
v_control_type                      text;
v_count                             int;
v_drop_count                        int := 0;
v_index                             record;
v_job_id                            bigint;
v_jobmon                            boolean;
v_jobmon_schema                     text;
v_max                               bigint;
v_new_search_path                   text;
v_old_search_path                   text;
v_parent_schema                     text;
v_parent_tablename                  text;
v_partition_interval                bigint;
v_partition_id                      bigint;
v_pubname_row                       record;
v_retention                         bigint;
v_retention_keep_index              boolean;
v_retention_keep_table              boolean;
v_retention_keep_publication        boolean;
v_retention_schema                  text;
v_row                               record;
v_row_max_id                        record;
v_sql                               text;
v_step_id                           bigint;
v_sub_parent                        text;

BEGIN
/*
 * Function to drop child tables from an id-based partition set.
 * Options to move table to different schema or actually drop the table from the database.
 */

v_adv_lock := pg_try_advisory_xact_lock(hashtext('pg_partman drop_partition_id'));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'drop_partition_id already running.';
    RETURN 0;
END IF;

IF p_retention IS NULL THEN
    SELECT
        partition_interval::bigint
        , control
        , retention::bigint
        , retention_keep_table
        , retention_keep_index
        , retention_keep_publication
        , retention_schema
        , jobmon
    INTO
        v_partition_interval
        , v_control
        , v_retention
        , v_retention_keep_table
        , v_retention_keep_index
        , v_retention_keep_publication
        , v_retention_schema
        , v_jobmon
    FROM partman5.part_config
    WHERE parent_table = p_parent_table
    AND retention IS NOT NULL;

    IF v_partition_interval IS NULL THEN
        RAISE EXCEPTION 'Configuration for given parent table with a retention period not found: %', p_parent_table;
    END IF;
ELSE -- Allow override of configuration options
     SELECT
        partition_interval::bigint
        , control
        , retention_keep_table
        , retention_keep_index
        , retention_keep_publication
        , retention_schema
        , jobmon
    INTO
        v_partition_interval
        , v_control
        , v_retention_keep_table
        , v_retention_keep_index
        , v_retention_keep_publication
        , v_retention_schema
        , v_jobmon
    FROM partman5.part_config
    WHERE parent_table = p_parent_table;
    v_retention := p_retention;

    IF v_partition_interval IS NULL THEN
        RAISE EXCEPTION 'Configuration for given parent table not found: %', p_parent_table;
    END IF;
END IF;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);
IF v_control_type <> 'id' THEN
    RAISE EXCEPTION 'Data type of control column in given partition set is not an integer type';
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

IF p_keep_table IS NOT NULL THEN
    v_retention_keep_table = p_keep_table;
END IF;
IF p_keep_index IS NOT NULL THEN
    v_retention_keep_index = p_keep_index;
END IF;
IF p_retention_schema IS NOT NULL THEN
    v_retention_schema = p_retention_schema;
END IF;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(p_parent_table, '.', 1)::name
AND tablename = split_part(p_parent_table, '.', 2)::name;

-- Loop through child tables starting from highest to get current max value in partition set
-- Avoids doing a scan on entire partition set and/or getting any values accidentally in default.
FOR v_row_max_id IN
    SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_table, 'DESC')
LOOP
        EXECUTE format('SELECT trunc(max(%I)) FROM %I.%I', v_control, v_row_max_id.partition_schemaname, v_row_max_id.partition_tablename) INTO v_max;
        IF v_max IS NOT NULL THEN
            EXIT;
        END IF;
END LOOP;

SELECT sub_parent INTO v_sub_parent FROM partman5.part_config_sub WHERE sub_parent = p_parent_table;

-- Loop through child tables of the given parent
-- Must go in ascending order to avoid dropping what may be the "last" partition in the set after dropping tables that match retention period
FOR v_row IN
    SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_table, 'ASC')
LOOP
     SELECT child_start_id INTO v_partition_id FROM partman5.show_partition_info(v_row.partition_schemaname||'.'||v_row.partition_tablename
        , v_partition_interval::text
        , p_parent_table);

    -- Add one interval to the start of the constraint period
    RAISE DEBUG 'drop_partition_id: v_retention: %, v_max: %, v_partition_id: %, v_partition_interval: %', v_retention, v_max, v_partition_id, v_partition_interval;
    IF v_retention <= (v_max - (v_partition_id + v_partition_interval)) THEN

        -- Do not allow final partition to be dropped if it is not a sub-partition parent
        SELECT count(*) INTO v_count FROM partman5.show_partitions(p_parent_table);
        IF v_count = 1 AND v_sub_parent IS NULL THEN
            RAISE WARNING 'Attempt to drop final partition in partition set % as part of retention policy. If you see this message multiple times for the same table, advise reviewing retention policy and/or data entry into the partition set. Also consider setting "infinite_time_partitions = true" if there are large gaps in data insertion.', p_parent_table;
            CONTINUE;
        END IF;

        -- Only create a jobmon entry if there's actual retention work done
        IF v_jobmon_schema IS NOT NULL AND v_job_id IS NULL THEN
            v_job_id := add_job(format('PARTMAN DROP ID PARTITION: %s', p_parent_table));
        END IF;

        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, format('Detach/Uninherit table %s.%s from %s', v_row.partition_schemaname, v_row.partition_tablename, p_parent_table));
        END IF;

        IF v_retention_keep_table = true OR v_retention_schema IS NOT NULL THEN
            -- No need to detach partition before dropping since it's going away anyway
            -- TODO Review this to see how to handle based on recent FK issues
            -- Avoids issue of FKs not allowing detachment (Github Issue #294).
            v_sql := format('ALTER TABLE %I.%I DETACH PARTITION %I.%I'
                , v_parent_schema
                , v_parent_tablename
                , v_row.partition_schemaname
                , v_row.partition_tablename);
            EXECUTE v_sql;

            IF v_retention_keep_index = false THEN
                FOR v_index IN
                     WITH child_info AS (
                        SELECT c1.oid
                        FROM pg_catalog.pg_class c1
                        JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid
                        WHERE c1.relname = v_row.partition_tablename::name
                        AND n1.nspname = v_row.partition_schemaname::name
                    )
                    SELECT c.relname as name
                        , con.conname
                    FROM pg_catalog.pg_index i
                    JOIN pg_catalog.pg_class c ON i.indexrelid = c.oid
                    LEFT JOIN pg_catalog.pg_constraint con ON i.indexrelid = con.conindid
                    JOIN child_info ON i.indrelid = child_info.oid
                LOOP
                    IF v_jobmon_schema IS NOT NULL THEN
                        v_step_id := add_step(v_job_id, format('Drop index %s from %s.%s'
                            , v_index.name
                            , v_row.partition_schemaname
                            , v_row.partition_tablename));
                    END IF;
                    IF v_index.conname IS NOT NULL THEN
                        EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', v_row.partition_schemaname, v_row.partition_tablename, v_index.conname);
                    ELSE
                        EXECUTE format('DROP INDEX %I.%I', v_row.partition_schemaname, v_index.name);
                    END IF;
                    IF v_jobmon_schema IS NOT NULL THEN
                        PERFORM update_step(v_step_id, 'OK', 'Done');
                    END IF;
                END LOOP;
            END IF; -- end v_retention_keep_index IF

            -- Remove table from publication(s) if desired
            IF v_retention_keep_publication = false THEN
                FOR v_pubname_row IN
                    SELECT p.pubname
                    FROM pg_catalog.pg_publication_rel pr
                    JOIN pg_catalog.pg_publication p ON p.oid = pr.prpubid
                    JOIN pg_catalog.pg_class c ON c.oid = pr.prrelid
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = v_row.partition_schemaname
                    AND c.relname = v_row.partition_tablename
                LOOP
                    EXECUTE format('ALTER PUBLICATION %I DROP TABLE %I.%I', v_pubname_row.pubname, v_row.partition_schemaname, v_row.partition_tablename);
                END LOOP;
            END IF;

        END IF;

        IF v_retention_schema IS NULL THEN
            IF v_retention_keep_table = false THEN
                IF v_jobmon_schema IS NOT NULL THEN
                    v_step_id := add_step(v_job_id, format('Drop table %s.%s', v_row.partition_schemaname, v_row.partition_tablename));
                END IF;
                v_sql := 'DROP TABLE %I.%I';
                EXECUTE format(v_sql, v_row.partition_schemaname, v_row.partition_tablename);
                IF v_jobmon_schema IS NOT NULL THEN
                    PERFORM update_step(v_step_id, 'OK', 'Done');
                END IF;
            END IF;
        ELSE -- Move to new schema
            IF v_jobmon_schema IS NOT NULL THEN
                v_step_id := add_step(v_job_id, format('Moving table %s.%s to schema %s'
                                                        , v_row.partition_schemaname
                                                        , v_row.partition_tablename
                                                        , v_retention_schema));
            END IF;

            EXECUTE format('ALTER TABLE %I.%I SET SCHEMA %I'
                    , v_row.partition_schemaname
                    , v_row.partition_tablename
                    , v_retention_schema);

            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', 'Done');
            END IF;
        END IF; -- End retention schema if

        -- If child table is a subpartition, remove it from part_config & part_config_sub (should cascade due to FK)
        DELETE FROM partman5.part_config WHERE parent_table = v_row.partition_schemaname ||'.'||v_row.partition_tablename;

        v_drop_count := v_drop_count + 1;
    END IF; -- End retention check IF

END LOOP; -- End child table loop

IF v_jobmon_schema IS NOT NULL THEN
    IF v_job_id IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Finished partition drop maintenance');
        PERFORM update_step(v_step_id, 'OK', format('%s partitions dropped.', v_drop_count));
        PERFORM close_job(v_job_id);
    END IF;
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

RETURN v_drop_count;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN DROP ID PARTITION: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.drop_partition_id(p_parent_table text, p_retention bigint, p_keep_table boolean, p_keep_index boolean, p_retention_schema text) OWNER TO api;

--
-- Name: drop_partition_time(text, interval, boolean, boolean, text, timestamp with time zone); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.drop_partition_time(p_parent_table text, p_retention interval DEFAULT NULL::interval, p_keep_table boolean DEFAULT NULL::boolean, p_keep_index boolean DEFAULT NULL::boolean, p_retention_schema text DEFAULT NULL::text, p_reference_timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                          text;
ex_detail                           text;
ex_hint                             text;
ex_message                          text;
v_adv_lock                          boolean;
v_control                           text;
v_control_type                      text;
v_count                             int;
v_drop_count                        int := 0;
v_epoch                             text;
v_index                             record;
v_job_id                            bigint;
v_jobmon                            boolean;
v_jobmon_schema                     text;
v_new_search_path                   text;
v_old_search_path                   text;
v_parent_schema                     text;
v_parent_tablename                  text;
v_partition_interval                interval;
v_partition_timestamp               timestamptz;
v_pubname_row                       record;
v_retention                         interval;
v_retention_keep_index              boolean;
v_retention_keep_table              boolean;
v_retention_keep_publication        boolean;
v_retention_schema                  text;
v_row                               record;
v_sql                               text;
v_step_id                           bigint;
v_sub_parent                        text;

BEGIN
/*
 * Function to drop child tables from a time-based partition set.
 * Options to move table to different schema, drop only indexes or actually drop the table from the database.
 */

v_adv_lock := pg_try_advisory_xact_lock(hashtext('pg_partman drop_partition_time'));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'drop_partition_time already running.';
    RETURN 0;
END IF;

-- Allow override of configuration options
IF p_retention IS NULL THEN
    SELECT
        control
        , partition_interval::interval
        , epoch
        , retention::interval
        , retention_keep_table
        , retention_keep_index
        , retention_keep_publication
        , retention_schema
        , jobmon
    INTO
        v_control
        , v_partition_interval
        , v_epoch
        , v_retention
        , v_retention_keep_table
        , v_retention_keep_index
        , v_retention_keep_publication
        , v_retention_schema
        , v_jobmon
    FROM partman5.part_config
    WHERE parent_table = p_parent_table
    AND retention IS NOT NULL;

    IF v_partition_interval IS NULL THEN
        RAISE EXCEPTION 'Configuration for given parent table with a retention period not found: %', p_parent_table;
    END IF;
ELSE
    SELECT
        partition_interval::interval
        , epoch
        , retention_keep_table
        , retention_keep_index
        , retention_keep_publication
        , retention_schema
        , jobmon
    INTO
        v_partition_interval
        , v_epoch
        , v_retention_keep_table
        , v_retention_keep_index
        , v_retention_keep_publication
        , v_retention_schema
        , v_jobmon
    FROM partman5.part_config
    WHERE parent_table = p_parent_table;
    v_retention := p_retention;

    IF v_partition_interval IS NULL THEN
        RAISE EXCEPTION 'Configuration for given parent table not found: %', p_parent_table;
    END IF;
END IF;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);
IF v_control_type <> 'time' THEN
    IF (v_control_type = 'id' AND v_epoch = 'none') OR v_control_type <> 'id' THEN
        RAISE EXCEPTION 'Cannot run on partition set without time based control column or epoch flag set with an id column. Found control: %, epoch: %', v_control_type, v_epoch;
    END IF;
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

IF p_keep_table IS NOT NULL THEN
    v_retention_keep_table = p_keep_table;
END IF;
IF p_keep_index IS NOT NULL THEN
    v_retention_keep_index = p_keep_index;
END IF;
IF p_retention_schema IS NOT NULL THEN
    v_retention_schema = p_retention_schema;
END IF;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(p_parent_table, '.', 1)::name
AND tablename = split_part(p_parent_table, '.', 2)::name;

SELECT sub_parent INTO v_sub_parent FROM partman5.part_config_sub WHERE sub_parent = p_parent_table;

-- Loop through child tables of the given parent
-- Must go in ascending order to avoid dropping what may be the "last" partition in the set after dropping tables that match retention period
FOR v_row IN
    SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_table, 'ASC')
LOOP
    -- pull out datetime portion of partition's tablename to make the next one
     SELECT child_start_time INTO v_partition_timestamp FROM partman5.show_partition_info(v_row.partition_schemaname||'.'||v_row.partition_tablename
        , v_partition_interval::text
        , p_parent_table);
    -- Add one interval since partition names contain the start of the constraint period
    IF (v_partition_timestamp + v_partition_interval) < (p_reference_timestamp - v_retention) THEN

        -- Do not allow final partition to be dropped if it is not a sub-partition parent
        SELECT count(*) INTO v_count FROM partman5.show_partitions(p_parent_table);
        IF v_count = 1 AND v_sub_parent IS NULL THEN
            RAISE WARNING 'Attempt to drop final partition in partition set % as part of retention policy. If you see this message multiple times for the same table, advise reviewing retention policy and/or data entry into the partition set. Also consider setting "infinite_time_partitions = true" if there are large gaps in data insertion.).', p_parent_table;
            CONTINUE;
        END IF;

        -- Only create a jobmon entry if there's actual retention work done
        IF v_jobmon_schema IS NOT NULL AND v_job_id IS NULL THEN
            v_job_id := add_job(format('PARTMAN DROP TIME PARTITION: %s', p_parent_table));
        END IF;

        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, format('Detach/Uninherit table %s.%s from %s'
                                                , v_row.partition_schemaname
                                                , v_row.partition_tablename
                                                , p_parent_table));
        END IF;
        IF v_retention_keep_table = true OR v_retention_schema IS NOT NULL THEN
            -- No need to detach partition before dropping since it's going away anyway
            -- TODO Review this to see how to handle based on recent FK issues
            -- Avoids issue of FKs not allowing detachment (Github Issue #294).
            v_sql := format('ALTER TABLE %I.%I DETACH PARTITION %I.%I'
                , v_parent_schema
                , v_parent_tablename
                , v_row.partition_schemaname
                , v_row.partition_tablename);
            EXECUTE v_sql;

            IF v_retention_keep_index = false THEN
                    FOR v_index IN
                        WITH child_info AS (
                            SELECT c1.oid
                            FROM pg_catalog.pg_class c1
                            JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid
                            WHERE c1.relname = v_row.partition_tablename::name
                            AND n1.nspname = v_row.partition_schemaname::name
                        )
                        SELECT c.relname as name
                            , con.conname
                        FROM pg_catalog.pg_index i
                        JOIN pg_catalog.pg_class c ON i.indexrelid = c.oid
                        LEFT JOIN pg_catalog.pg_constraint con ON i.indexrelid = con.conindid
                        JOIN child_info ON i.indrelid = child_info.oid
                    LOOP
                        IF v_jobmon_schema IS NOT NULL THEN
                            v_step_id := add_step(v_job_id, format('Drop index %s from %s.%s'
                                                                , v_index.name
                                                                , v_row.partition_schemaname
                                                                , v_row.partition_tablename));
                        END IF;
                        IF v_index.conname IS NOT NULL THEN
                            EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I'
                                            , v_row.partition_schemaname
                                            , v_row.partition_tablename
                                            , v_index.conname);
                        ELSE
                            EXECUTE format('DROP INDEX %I.%I', v_parent_schema, v_index.name);
                        END IF;
                        IF v_jobmon_schema IS NOT NULL THEN
                            PERFORM update_step(v_step_id, 'OK', 'Done');
                        END IF;
                    END LOOP;
            END IF; -- end v_retention_keep_index IF


            -- Remove table from publication(s) if desired
            IF v_retention_keep_publication = false THEN

                FOR v_pubname_row IN
                    SELECT p.pubname
                    FROM pg_catalog.pg_publication_rel pr
                    JOIN pg_catalog.pg_publication p ON p.oid = pr.prpubid
                    JOIN pg_catalog.pg_class c ON c.oid = pr.prrelid
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = v_row.partition_schemaname
                    AND c.relname = v_row.partition_tablename
                LOOP
                    EXECUTE format('ALTER PUBLICATION %I DROP TABLE %I.%I', v_pubname_row.pubname, v_row.partition_schemaname, v_row.partition_tablename);
                END LOOP;

            END IF;

        END IF;

        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', 'Done');
        END IF;

        IF v_retention_schema IS NULL THEN
            IF v_retention_keep_table = false THEN
                IF v_jobmon_schema IS NOT NULL THEN
                    v_step_id := add_step(v_job_id, format('Drop table %s.%s', v_row.partition_schemaname, v_row.partition_tablename));
                END IF;
                v_sql := 'DROP TABLE %I.%I';
                EXECUTE format(v_sql, v_row.partition_schemaname, v_row.partition_tablename);
                IF v_jobmon_schema IS NOT NULL THEN
                    PERFORM update_step(v_step_id, 'OK', 'Done');
                END IF;
            END IF;
        ELSE -- Move to new schema
            IF v_jobmon_schema IS NOT NULL THEN
                v_step_id := add_step(v_job_id, format('Moving table %s.%s to schema %s'
                                                , v_row.partition_schemaname
                                                , v_row.partition_tablename
                                                , v_retention_schema));
            END IF;

            EXECUTE format('ALTER TABLE %I.%I SET SCHEMA %I', v_row.partition_schemaname, v_row.partition_tablename, v_retention_schema);


            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', 'Done');
            END IF;
        END IF; -- End retention schema if

        -- If child table is a subpartition, remove it from part_config & part_config_sub (should cascade due to FK)
        DELETE FROM partman5.part_config WHERE parent_table = v_row.partition_schemaname||'.'||v_row.partition_tablename;

        v_drop_count := v_drop_count + 1;
    END IF; -- End retention check IF

END LOOP; -- End child table loop

IF v_jobmon_schema IS NOT NULL THEN
    IF v_job_id IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Finished partition drop maintenance');
        PERFORM update_step(v_step_id, 'OK', format('%s partitions dropped.', v_drop_count));
        PERFORM close_job(v_job_id);
    END IF;
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

RETURN v_drop_count;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN DROP TIME PARTITION: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.drop_partition_time(p_parent_table text, p_retention interval, p_keep_table boolean, p_keep_index boolean, p_retention_schema text, p_reference_timestamp timestamp with time zone) OWNER TO api;

--
-- Name: dump_partitioned_table_definition(text, boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.dump_partitioned_table_definition(p_parent_table text, p_ignore_template_table boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_create_parent_definition text;
    v_update_part_config_definition text;
    -- Columns from part_config table.
    v_parent_table text; -- NOT NULL
    v_control text; -- NOT NULL
    v_partition_type text; -- NOT NULL
    v_partition_interval text; -- NOT NULL
    v_constraint_cols TEXT[];
    v_premake integer; -- NOT NULL
    v_optimize_constraint integer; -- NOT NULL
    v_epoch text; -- NOT NULL
    v_retention text;
    v_retention_schema text;
    v_retention_keep_index boolean;
    v_retention_keep_table boolean; -- NOT NULL
    v_infinite_time_partitions boolean; -- NOT NULL
    v_datetime_string text;
    v_automatic_maintenance text; -- NOT NULL
    v_jobmon boolean; -- NOT NULL
    v_sub_partition_set_full boolean; -- NOT NULL
    v_template_table text;
    v_inherit_privileges boolean; -- DEFAULT false
    v_constraint_valid boolean; -- DEFAULT true NOT NULL
    v_ignore_default_data boolean; -- DEFAULT false NOT NULL
    v_date_trunc_interval text;
    v_default_table boolean;
    v_maintenance_order int;
    v_retention_keep_publication boolean;
BEGIN
    SELECT
        pc.parent_table,
        pc.control,
        pc.partition_type,
        pc.partition_interval,
        pc.constraint_cols,
        pc.premake,
        pc.optimize_constraint,
        pc.epoch,
        pc.retention,
        pc.retention_schema,
        pc.retention_keep_index,
        pc.retention_keep_table,
        pc.infinite_time_partitions,
        pc.datetime_string,
        pc.automatic_maintenance,
        pc.jobmon,
        pc.sub_partition_set_full,
        pc.template_table,
        pc.inherit_privileges,
        pc.constraint_valid,
        pc.ignore_default_data,
        pc.date_trunc_interval,
        pc.default_table,
        pc.maintenance_order,
        pc.retention_keep_publication
    INTO
        v_parent_table,
        v_control,
        v_partition_type,
        v_partition_interval,
        v_constraint_cols,
        v_premake,
        v_optimize_constraint,
        v_epoch,
        v_retention,
        v_retention_schema,
        v_retention_keep_index,
        v_retention_keep_table,
        v_infinite_time_partitions,
        v_datetime_string,
        v_automatic_maintenance,
        v_jobmon,
        v_sub_partition_set_full,
        v_template_table,
        v_inherit_privileges,
        v_constraint_valid,
        v_ignore_default_data,
        v_date_trunc_interval,
        v_default_table,
        v_maintenance_order,
        v_retention_keep_publication
    FROM partman5.part_config pc
    WHERE pc.parent_table = p_parent_table;

    IF v_parent_table IS NULL THEN
        RAISE EXCEPTION 'Given parent table not found in pg_partman configuration table: %', p_parent_table;
    END IF;

    IF p_ignore_template_table THEN
        v_template_table := NULL;
    END IF;

    v_create_parent_definition := format(
E'SELECT partman5.create_parent(
\tp_parent_table := %L,
\tp_control := %L,
\tp_interval := %L,
\tp_type := %L,
\tp_epoch := %L,
\tp_premake := %s,
\tp_default_table := %L,
\tp_automatic_maintenance := %L,
\tp_constraint_cols := %L,
\tp_template_table := %L,
\tp_jobmon := %L,
\tp_date_trunc_interval := %L
);',
            v_parent_table,
            v_control,
            v_partition_interval,
            v_partition_type,
            v_epoch,
            v_premake,
            v_default_table,
            v_automatic_maintenance,
            v_constraint_cols,
            v_template_table,
            v_jobmon,
            v_date_trunc_interval
        );

    v_update_part_config_definition := format(
E'UPDATE partman5.part_config SET
\toptimize_constraint = %s,
\tretention = %L,
\tretention_schema = %L,
\tretention_keep_index = %L,
\tretention_keep_table = %L,
\tinfinite_time_partitions = %L,
\tdatetime_string = %L,
\tsub_partition_set_full = %L,
\tinherit_privileges = %L,
\tconstraint_valid = %L,
\tignore_default_data = %L,
\tmaintenance_order = %L,
\tretention_keep_publication = %L
WHERE parent_table = %L;',
        v_optimize_constraint,
        v_retention,
        v_retention_schema,
        v_retention_keep_index,
        v_retention_keep_table,
        v_infinite_time_partitions,
        v_datetime_string,
        v_sub_partition_set_full,
        v_inherit_privileges,
        v_constraint_valid,
        v_ignore_default_data,
        v_maintenance_order,
        v_retention_keep_publication,
        v_parent_table
    );

    RETURN concat_ws(E'\n',
        v_create_parent_definition,
        v_update_part_config_definition
    );
END
$$;


ALTER FUNCTION partman5.dump_partitioned_table_definition(p_parent_table text, p_ignore_template_table boolean) OWNER TO api;

--
-- Name: inherit_replica_identity(text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.inherit_replica_identity(p_parent_schemaname text, p_parent_tablename text, p_child_tablename text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

v_parent_oid                    oid;
v_parent_replident              char;
v_parent_replident_index        name;
v_replident_string              text;
v_sql                           text;

BEGIN

/*
* Set the given child table's replica idenitity to the same as the parent
 NOTE: Replication identity not automatically inherited as of PG16 (revisit in future versions)
*/

SELECT c.oid
    , c.relreplident
INTO v_parent_oid
    , v_parent_replident
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = p_parent_schemaname
AND c.relname = p_parent_tablename;

IF v_parent_replident = 'i' THEN
    SELECT c.relname
    INTO v_parent_replident_index
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
    WHERE i.indrelid = v_parent_oid
    AND indisreplident;
END IF;

RAISE DEBUG 'inherit_replica_ident: v_parent_oid: %, v_parent_replident: %,  v_parent_replident_index: %', v_parent_oid, v_parent_replident,  v_parent_replident_index;

IF v_parent_replident != 'd' THEN
    CASE v_parent_replident
        WHEN 'f' THEN v_replident_string := 'FULL';
        WHEN 'i' THEN v_replident_string := format('USING INDEX %I', v_parent_replident_index);
        WHEN 'n' THEN v_replident_string := 'NOTHING';
    ELSE
        RAISE EXCEPTION 'inherit_replica_identity: Unknown replication identity encountered (%). Please report as a bug on pg_partman''s github', v_parent_replident;
    END CASE;
    v_sql := format('ALTER TABLE %I.%I REPLICA IDENTITY %s'
                    , p_parent_schemaname
                    , p_child_tablename
                    , v_replident_string);
    RAISE DEBUG 'inherit_replica_identity: replident v_sql: %', v_sql;
    EXECUTE v_sql;
END IF;

END
$$;


ALTER FUNCTION partman5.inherit_replica_identity(p_parent_schemaname text, p_parent_tablename text, p_child_tablename text) OWNER TO api;

--
-- Name: inherit_template_properties(text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.inherit_template_properties(p_parent_table text, p_child_schema text, p_child_tablename text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

v_child_relkind         char;
v_child_schema          text;
v_child_tablename       text;
v_child_unlogged        char;
v_dupe_found            boolean := false;
v_index_list            record;
v_parent_index_list     record;
v_parent_oid            oid;
v_parent_table          text;
v_relopt                record;
v_sql                   text;
v_template_oid          oid;
v_template_schemaname   text;
v_template_table        text;
v_template_tablename    name;
v_template_unlogged     char;

BEGIN
/*
 * Function to inherit the properties of the template table to newly created child tables.
 * For PG14+, used to inherit non-partition-key unique indexes & primary keys and unlogged status
 */

SELECT parent_table, template_table
INTO v_parent_table, v_template_table
FROM partman5.part_config
WHERE parent_table = p_parent_table;
IF v_parent_table IS NULL THEN
    RAISE EXCEPTION 'Given parent table has no configuration in pg_partman: %', p_parent_table;
ELSIF v_template_table IS NULL THEN
    RAISE EXCEPTION 'No template table set in configuration for given parent table: %', p_parent_table;
END IF;

SELECT c.oid INTO v_parent_oid
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
    IF v_parent_oid IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs: %', p_parent_table;
    END IF;

SELECT n.nspname, c.relname, c.relkind INTO v_child_schema, v_child_tablename, v_child_relkind
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = p_child_schema::name
AND c.relname = p_child_tablename::name;
    IF v_child_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given child table in system catalogs: %.%', v_child_schema, v_child_tablename;
    END IF;

IF v_child_relkind = 'p' THEN
    -- Subpartitioned parent, do not apply properties
    RAISE DEBUG 'inherit_template_properties: found given child is subpartition parent, so properties not inherited';
    RETURN false;
END IF;

v_template_schemaname := split_part(v_template_table, '.', 1)::name;
v_template_tablename :=  split_part(v_template_table, '.', 2)::name;

SELECT c.oid INTO v_template_oid
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
LEFT OUTER JOIN pg_catalog.pg_tablespace ts ON c.reltablespace = ts.oid
WHERE n.nspname = v_template_schemaname
AND c.relname = v_template_tablename;
    IF v_template_oid IS NULL THEN
        RAISE EXCEPTION 'Unable to find configured template table in system catalogs: %', v_template_table;
    END IF;

-- Index creation (Only for unique, non-partition key indexes)
FOR v_index_list IN
    SELECT
    array_to_string(regexp_matches(pg_get_indexdef(indexrelid), ' USING .*'),',') AS statement
    , i.indisprimary
    , i.indisunique
    , ( SELECT array_agg( a.attname ORDER by x.r )
        FROM pg_catalog.pg_attribute a
        JOIN ( SELECT k, row_number() over () as r
                FROM unnest(i.indkey) k ) as x
        ON a.attnum = x.k AND a.attrelid = i.indrelid
    ) AS indkey_names
    , c.relname AS index_name
    , ts.spcname AS tablespace_name
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_class c ON i.indexrelid = c.oid
    LEFT OUTER JOIN pg_catalog.pg_tablespace ts ON c.reltablespace = ts.oid
    WHERE i.indrelid = v_template_oid
    AND i.indisvalid
    AND (i.indisprimary OR i.indisunique)
    ORDER BY 1
LOOP
    v_dupe_found := false;

    FOR v_parent_index_list IN
        SELECT
        array_to_string(regexp_matches(pg_get_indexdef(indexrelid), ' USING .*'),',') AS statement
        , i.indisprimary
        , ( SELECT array_agg( a.attname ORDER by x.r )
            FROM pg_catalog.pg_attribute a
            JOIN ( SELECT k, row_number() over () as r
                    FROM unnest(i.indkey) k ) as x
            ON a.attnum = x.k AND a.attrelid = i.indrelid
        ) AS indkey_names
        FROM pg_catalog.pg_index i
        WHERE i.indrelid = v_parent_oid
        AND i.indisvalid
        ORDER BY 1
    LOOP

        IF v_parent_index_list.indisprimary AND v_index_list.indisprimary THEN
            IF v_parent_index_list.indkey_names = v_index_list.indkey_names THEN
                RAISE DEBUG 'inherit_template_properties: Ignoring duplicate primary key on template table: % ', v_index_list.indkey_names;
                v_dupe_found := true;
                CONTINUE; -- only continue within this nested loop
            END IF;
        END IF;

        IF v_parent_index_list.statement = v_index_list.statement THEN
            RAISE DEBUG 'inherit_template_properties: Ignoring duplicate unique index on template table: %', v_index_list.statement;
            v_dupe_found := true;
            CONTINUE; -- only continue within this nested loop
        END IF;

    END LOOP; -- end parent index loop

    IF v_dupe_found = true THEN
        CONTINUE;
    END IF;

    IF v_index_list.indisprimary THEN
        v_sql := format('ALTER TABLE %I.%I ADD PRIMARY KEY (%s)'
                        , v_child_schema
                        , v_child_tablename
                        , '"' || array_to_string(v_index_list.indkey_names, '","') || '"');
        IF v_index_list.tablespace_name IS NOT NULL THEN
            v_sql := v_sql || format(' USING INDEX TABLESPACE %I', v_index_list.tablespace_name);
        END IF;
        RAISE DEBUG 'inherit_template_properties: Create pk: %', v_sql;
        EXECUTE v_sql;
    ELSIF v_index_list.indisunique THEN
        -- statement column should be just the portion of the index definition that defines what it actually is
        v_sql := format('CREATE UNIQUE INDEX ON %I.%I %s', v_child_schema, v_child_tablename, v_index_list.statement);
        IF v_index_list.tablespace_name IS NOT NULL THEN
            v_sql := v_sql || format(' TABLESPACE %I', v_index_list.tablespace_name);
        END IF;

        RAISE DEBUG 'inherit_template_properties: Create index: %', v_sql;
        EXECUTE v_sql;
    ELSE
        RAISE EXCEPTION 'inherit_template_properties: Unexpected code path in unique index creation. Please report the steps that lead to this error to extension maintainers.';
    END IF;

END LOOP;
-- End index creation

-- UNLOGGED status. Currently waiting on final stance of how upstream will handle this property being changed for its children.
-- See release notes for v4.2.0
SELECT relpersistence INTO v_template_unlogged
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = v_template_schemaname
AND c.relname = v_template_tablename;

SELECT relpersistence INTO v_child_unlogged
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = v_child_schema::name
AND c.relname = v_child_tablename::name;

IF v_template_unlogged = 'u' AND v_child_unlogged = 'p'  THEN
    v_sql := format ('ALTER TABLE %I.%I SET UNLOGGED', v_child_schema, v_child_tablename);
    RAISE DEBUG 'inherit_template_properties: Alter UNLOGGED: %', v_sql;
    EXECUTE v_sql;
ELSIF v_template_unlogged = 'p' AND v_child_unlogged = 'u'  THEN
    v_sql := format ('ALTER TABLE %I.%I SET LOGGED', v_child_schema, v_child_tablename);
    RAISE DEBUG 'inherit_template_properties: Alter UNLOGGED: %', v_sql;
    EXECUTE v_sql;
END IF;

-- Relation options are not either not being inherited or not supported (autovac tuning) on <= PG15
FOR v_relopt IN
    SELECT unnest(reloptions) as value
    FROM pg_catalog.pg_class
    WHERE oid = v_template_oid
LOOP
    v_sql := format('ALTER TABLE %I.%I SET (%s)'
                    , v_child_schema
                    , v_child_tablename
                    , v_relopt.value);
    RAISE DEBUG 'inherit_template_properties: Set relopts: %', v_sql;
    EXECUTE v_sql;
END LOOP;
RETURN true;

END
$$;


ALTER FUNCTION partman5.inherit_template_properties(p_parent_table text, p_child_schema text, p_child_tablename text) OWNER TO api;

--
-- Name: partition_data_id(text, integer, bigint, numeric, text, boolean, text, text[]); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.partition_data_id(p_parent_table text, p_batch_count integer DEFAULT 1, p_batch_interval bigint DEFAULT NULL::bigint, p_lock_wait numeric DEFAULT 0, p_order text DEFAULT 'ASC'::text, p_analyze boolean DEFAULT true, p_source_table text DEFAULT NULL::text, p_ignored_columns text[] DEFAULT NULL::text[]) RETURNS bigint
    LANGUAGE plpgsql
    AS $_$
DECLARE

v_analyze                   boolean := FALSE;
v_column_list               text;
v_control                   text;
v_control_type              text;
v_current_partition_name    text;
v_default_exists            boolean;
v_default_schemaname        text;
v_default_tablename         text;
v_epoch                     text;
v_lock_iter                 int := 1;
v_lock_obtained             boolean := FALSE;
v_max_partition_id          bigint;
v_min_partition_id          bigint;
v_parent_schema             text;
v_parent_tablename          text;
v_partition_interval        bigint;
v_partition_id              bigint[];
v_rowcount                  bigint;
v_source_schemaname         text;
v_source_tablename          text;
v_sql                       text;
v_start_control             bigint;
v_total_rows                bigint := 0;

BEGIN
    /*
     * Populate the child table(s) of an id-based partition set with data from the default or other given source
     */

    SELECT partition_interval::bigint
    , control
    , epoch
    INTO v_partition_interval
    , v_control
    , v_epoch
    FROM partman5.part_config
    WHERE parent_table = p_parent_table;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR: No entry in part_config found for given table:  %', p_parent_table;
    END IF;

SELECT schemaname, tablename INTO v_source_schemaname, v_source_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(p_parent_table, '.', 1)::name
AND tablename = split_part(p_parent_table, '.', 2)::name;

-- Preserve given parent tablename for use below
v_parent_schema    := v_source_schemaname;
v_parent_tablename := v_source_tablename;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_source_schemaname, v_source_tablename, v_control);

IF v_control_type <> 'id' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN
    RAISE EXCEPTION 'Control column for given partition set is not id/serial based or epoch flag is set for time-based partitioning.';
END IF;

IF p_source_table IS NOT NULL THEN
    -- Set source table to user given source table instead of parent table
    v_source_schemaname := NULL;
    v_source_tablename := NULL;

    SELECT schemaname, tablename INTO v_source_schemaname, v_source_tablename
    FROM pg_catalog.pg_tables
    WHERE schemaname = split_part(p_source_table, '.', 1)::name
    AND tablename = split_part(p_source_table, '.', 2)::name;

    IF v_source_tablename IS NULL THEN
        RAISE EXCEPTION 'Given source table does not exist in system catalogs: %', p_source_table;
    END IF;

ELSE

    IF p_batch_interval IS NOT NULL AND p_batch_interval != v_partition_interval THEN
        -- This is true because all data for a given child table must be moved out of the default partition before the child table can be created.
        -- So cannot create the child table when only some of the data has been moved out of the default partition.
        RAISE EXCEPTION 'Custom intervals are not allowed when moving data out of the DEFAULT partition. Please leave p_interval/p_batch_interval parameters unset or NULL to allow use of partition set''s default partitioning interval.';
    END IF;

    -- Set source table to default table if p_source_table is not set, and it exists
    -- Otherwise just return with a DEBUG that no data source exists
    SELECT n.nspname::text, c.relname::text
    INTO v_default_schemaname, v_default_tablename
    FROM pg_catalog.pg_inherits h
    JOIN pg_catalog.pg_class c ON c.oid = h.inhrelid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE h.inhparent = format('%I.%I', v_source_schemaname, v_source_tablename)::regclass
    AND pg_get_expr(relpartbound, c.oid) = 'DEFAULT';

    IF v_default_tablename IS NOT NULL THEN
        v_source_schemaname := v_default_schemaname;
        v_source_tablename := v_default_tablename;

        v_default_exists := true;
        EXECUTE format ('CREATE TEMP TABLE IF NOT EXISTS partman_temp_data_storage (LIKE %I.%I INCLUDING INDEXES) ON COMMIT DROP', v_source_schemaname, v_source_tablename);
    ELSE
        RAISE DEBUG 'No default table found when partition_data_id() was called';
        RETURN v_total_rows;
    END IF;

END IF;

IF p_batch_interval IS NULL OR p_batch_interval > v_partition_interval THEN
    p_batch_interval := v_partition_interval;
END IF;

-- Generate column list to use in SELECT/INSERT statements below. Allows for exclusion of GENERATED (or any other desired) columns.
SELECT string_agg(quote_ident(attname), ',')
INTO v_column_list
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = v_source_schemaname
AND c.relname = v_source_tablename
AND a.attnum > 0
AND a.attisdropped = false
AND attname <> ALL(COALESCE(p_ignored_columns, ARRAY[]::text[]));

FOR i IN 1..p_batch_count LOOP

    IF p_order = 'ASC' THEN
        EXECUTE format('SELECT min(%I) FROM ONLY %I.%I', v_control, v_source_schemaname, v_source_tablename) INTO v_start_control;
        IF v_start_control IS NULL THEN
            EXIT;
        END IF;
        v_min_partition_id = v_start_control - (v_start_control % v_partition_interval);
        v_partition_id := ARRAY[v_min_partition_id];
        -- Check if custom batch interval overflows current partition maximum
        IF (v_start_control + p_batch_interval) >= (v_min_partition_id + v_partition_interval) THEN
            v_max_partition_id := v_min_partition_id + v_partition_interval;
        ELSE
            v_max_partition_id := v_start_control + p_batch_interval;
        END IF;

    ELSIF p_order = 'DESC' THEN
        EXECUTE format('SELECT max(%I) FROM ONLY %I.%I', v_control, v_source_schemaname, v_source_tablename) INTO v_start_control;
        IF v_start_control IS NULL THEN
            EXIT;
        END IF;
        v_min_partition_id = v_start_control - (v_start_control % v_partition_interval);
        -- Must be greater than max value still in parent table since query below grabs < max
        v_max_partition_id := v_min_partition_id + v_partition_interval;
        v_partition_id := ARRAY[v_min_partition_id];
        -- Make sure minimum doesn't underflow current partition minimum
        IF (v_start_control - p_batch_interval) >= v_min_partition_id THEN
            v_min_partition_id = v_start_control - p_batch_interval;
        END IF;
    ELSE
        RAISE EXCEPTION 'Invalid value for p_order. Must be ASC or DESC';
    END IF;

    -- do some locking with timeout, if required
    IF p_lock_wait > 0  THEN
        v_lock_iter := 0;
        WHILE v_lock_iter <= 5 LOOP
            v_lock_iter := v_lock_iter + 1;
            BEGIN
                v_sql := format('SELECT %s FROM ONLY %I.%I WHERE %I >= %s AND %I < %s FOR UPDATE NOWAIT'
                    , v_column_list
                    , v_source_schemaname
                    , v_source_tablename
                    , v_control
                    , v_min_partition_id
                    , v_control
                    , v_max_partition_id);
                EXECUTE v_sql;
                v_lock_obtained := TRUE;
                EXCEPTION
                WHEN lock_not_available THEN
                    PERFORM pg_sleep( p_lock_wait / 5.0 );
                    CONTINUE;
            END;
            EXIT WHEN v_lock_obtained;
    END LOOP;
    IF NOT v_lock_obtained THEN
        RETURN -1;
    END IF;
END IF;

v_current_partition_name := partman5.check_name_length(COALESCE(v_parent_tablename), v_min_partition_id::text, TRUE);

IF v_default_exists THEN

    -- Child tables cannot be created if data that belongs to it exists in the default
    -- Have to move data out to temporary location, create child table, then move it back

    -- Temp table created above to avoid excessive temp creation in loop
    EXECUTE format('WITH partition_data AS (
            DELETE FROM %1$I.%2$I WHERE %3$I >= %4$s AND %3$I < %5$s RETURNING *)
        INSERT INTO partman_temp_data_storage (%6$s) SELECT %6$s FROM partition_data'
        , v_source_schemaname
        , v_source_tablename
        , v_control
        , v_min_partition_id
        , v_max_partition_id
        , v_column_list);

    -- Set analyze to true if a table is created
    v_analyze := partman5.create_partition_id(p_parent_table, v_partition_id);

    EXECUTE format('WITH partition_data AS (
            DELETE FROM partman_temp_data_storage RETURNING *)
        INSERT INTO %1$I.%2$I (%3$s) SELECT %3$s FROM partition_data'
        , v_parent_schema
        , v_current_partition_name
        , v_column_list);

ELSE

    -- Set analyze to true if a table is created
    v_analyze := partman5.create_partition_id(p_parent_table, v_partition_id);

    EXECUTE format('WITH partition_data AS (
            DELETE FROM ONLY %1$I.%2$I WHERE %3$I >= %4$s AND %3$I < %5$s RETURNING *)
        INSERT INTO %6$I.%7$I (%8$s) SELECT %8$s FROM partition_data'
        , v_source_schemaname
        , v_source_tablename
        , v_control
        , v_min_partition_id
        , v_max_partition_id
        , v_parent_schema
        , v_current_partition_name
        , v_column_list);

END IF;

GET DIAGNOSTICS v_rowcount = ROW_COUNT;
v_total_rows := v_total_rows + v_rowcount;
IF v_rowcount = 0 THEN
    EXIT;
END IF;

END LOOP;

-- v_analyze is a local check if a new table is made.
-- p_analyze is a parameter to say whether to run the analyze at all. Used by create_parent() to avoid long exclusive lock or run_maintenence() to avoid long creation runs.
IF v_analyze AND p_analyze THEN
    RAISE DEBUG 'partiton_data_time: Begin analyze of %.%', v_parent_schema, v_parent_tablename;
    EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);
    RAISE DEBUG 'partiton_data_time: End analyze of %.%', v_parent_schema, v_parent_tablename;
END IF;

RETURN v_total_rows;

END
$_$;


ALTER FUNCTION partman5.partition_data_id(p_parent_table text, p_batch_count integer, p_batch_interval bigint, p_lock_wait numeric, p_order text, p_analyze boolean, p_source_table text, p_ignored_columns text[]) OWNER TO api;

--
-- Name: partition_data_proc(text, integer, text, integer, integer, integer, text, text, text[], boolean); Type: PROCEDURE; Schema: partman5; Owner: api
--

CREATE PROCEDURE partman5.partition_data_proc(IN p_parent_table text, IN p_loop_count integer DEFAULT NULL::integer, IN p_interval text DEFAULT NULL::text, IN p_lock_wait integer DEFAULT 0, IN p_lock_wait_tries integer DEFAULT 10, IN p_wait integer DEFAULT 1, IN p_order text DEFAULT 'ASC'::text, IN p_source_table text DEFAULT NULL::text, IN p_ignored_columns text[] DEFAULT NULL::text[], IN p_quiet boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $$
DECLARE

v_adv_lock          boolean;
v_control           text;
v_control_type      text;
v_epoch             text;
v_is_autovac_off    boolean := false;
v_lockwait_count    int := 0;
v_loop_count        int := 0;
v_parent_schema     text;
v_parent_tablename  text;
v_rows_moved        bigint;
v_source_schema     text;
v_source_tablename  text;
v_sql               text;
v_total             bigint := 0;

BEGIN

v_adv_lock := pg_try_advisory_xact_lock(hashtext('pg_partman partition_data_proc'), hashtext(p_parent_table));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'Partman partition_data_proc already running for given parent table: %.', p_parent_table;
    RETURN;
END IF;

SELECT control, epoch
INTO v_control, v_epoch
FROM partman5.part_config
WHERE parent_table = p_parent_table;
IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: No entry in part_config found for given table: %', p_parent_table;
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs. Ensure it is schema qualified: %', p_parent_table;
    END IF;

IF p_source_table IS NOT NULL THEN
    SELECT n.nspname, c.relname INTO v_source_schema, v_source_tablename
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = split_part(p_source_table, '.', 1)::name
    AND c.relname = split_part(p_source_table, '.', 2)::name;
        IF v_source_tablename IS NULL THEN
            RAISE EXCEPTION 'Unable to find given source table in system catalogs. Ensure it is schema qualified: %', p_source_table;
        END IF;
END IF;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

IF v_control_type = 'id' AND v_epoch <> 'none' THEN
        v_control_type := 'time';
END IF;

/*
-- Currently no way to catch exception and reset autovac settings back to normal. Until I can do that, leaving this feature out for now
-- Leaving the functions to turn off/reset in to let people do that manually if desired
IF p_autovacuum_on = false THEN         -- Add this parameter back to definition when this is working
    -- Turn off autovac for parent, source table if set, and all child tables
    v_is_autovac_off := partman5.autovacuum_off(v_parent_schema, v_parent_tablename, v_source_schema, v_source_tablename);
    COMMIT;
END IF;
*/

v_sql := format('SELECT %s.partition_data_%s (p_parent_table := %L, p_lock_wait := %L, p_order := %L, p_analyze := false'
        , 'partman5', v_control_type, p_parent_table, p_lock_wait, p_order);
IF p_interval IS NOT NULL THEN
    v_sql := v_sql || format(', p_batch_interval := %L', p_interval);
END IF;
IF p_source_table IS NOT NULL THEN
    v_sql := v_sql || format(', p_source_table := %L', p_source_table);
END IF;
IF p_ignored_columns IS NOT NULL THEN
    v_sql := v_sql || format(', p_ignored_columns := %L', p_ignored_columns);
END IF;
v_sql := v_sql || ')';
RAISE DEBUG 'partition_data sql: %', v_sql;

LOOP
    EXECUTE v_sql INTO v_rows_moved;
    -- If lock wait timeout, do not increment the counter
    IF v_rows_moved != -1 THEN
        v_loop_count := v_loop_count + 1;
        v_total := v_total + v_rows_moved;
        v_lockwait_count := 0;
    ELSE
        v_lockwait_count := v_lockwait_count + 1;
        IF v_lockwait_count > p_lock_wait_tries THEN
            RAISE EXCEPTION 'Quitting due to inability to get lock on next batch of rows to be moved';
        END IF;
    END IF;
    IF p_quiet = false THEN
        IF v_rows_moved > 0 THEN
            RAISE NOTICE 'Loop: %, Rows moved: %', v_loop_count, v_rows_moved;
        ELSIF v_rows_moved = -1 THEN
            RAISE NOTICE 'Unable to obtain row locks for data to be moved. Trying again...';
        END IF;
    END IF;
    -- If no rows left or given loop argument limit is reached
    IF v_rows_moved = 0 OR (p_loop_count > 0 AND v_loop_count >= p_loop_count) THEN
        EXIT;
    END IF;
    COMMIT;
    PERFORM pg_sleep(p_wait);
    RAISE DEBUG 'v_rows_moved: %, v_loop_count: %, v_total: %, v_lockwait_count: %, p_wait: %', p_wait, v_rows_moved, v_loop_count, v_total, v_lockwait_count;
END LOOP;

/*
IF v_is_autovac_off = true THEN
    -- Reset autovac back to default if it was turned off by this procedure
    PERFORM partman5.autovacuum_reset(v_parent_schema, v_parent_tablename, v_source_schema, v_source_tablename);
    COMMIT;
END IF;
*/

IF p_quiet = false THEN
    RAISE NOTICE 'Total rows moved: %', v_total;
END IF;
RAISE NOTICE 'Ensure to VACUUM ANALYZE the parent (and source table if used) after partitioning data';

/* Leaving here until I can figure out what's wrong with procedures and exception handling
EXCEPTION
    WHEN QUERY_CANCELED THEN
        ROLLBACK;
        -- Reset autovac back to default if it was turned off by this procedure
        IF v_is_autovac_off = true THEN
            PERFORM partman5.autovacuum_reset(v_parent_schema, v_parent_tablename, v_source_schema, v_source_tablename);
        END IF;
        RAISE EXCEPTION '%', SQLERRM;
    WHEN OTHERS THEN
        ROLLBACK;
        -- Reset autovac back to default if it was turned off by this procedure
        IF v_is_autovac_off = true THEN
            PERFORM partman5.autovacuum_reset(v_parent_schema, v_parent_tablename, v_source_schema, v_source_tablename);
        END IF;
        RAISE EXCEPTION '%', SQLERRM;
*/
END;
$$;


ALTER PROCEDURE partman5.partition_data_proc(IN p_parent_table text, IN p_loop_count integer, IN p_interval text, IN p_lock_wait integer, IN p_lock_wait_tries integer, IN p_wait integer, IN p_order text, IN p_source_table text, IN p_ignored_columns text[], IN p_quiet boolean) OWNER TO api;

--
-- Name: partition_data_time(text, integer, interval, numeric, text, boolean, text, text[]); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.partition_data_time(p_parent_table text, p_batch_count integer DEFAULT 1, p_batch_interval interval DEFAULT NULL::interval, p_lock_wait numeric DEFAULT 0, p_order text DEFAULT 'ASC'::text, p_analyze boolean DEFAULT true, p_source_table text DEFAULT NULL::text, p_ignored_columns text[] DEFAULT NULL::text[]) RETURNS bigint
    LANGUAGE plpgsql
    AS $_$
DECLARE

v_analyze                   boolean := FALSE;
v_column_list               text;
v_control                   text;
v_control_type              text;
v_datetime_string           text;
v_current_partition_name    text;
v_default_exists            boolean;
v_default_schemaname        text;
v_default_tablename         text;
v_epoch                     text;
v_last_partition            text;
v_lock_iter                 int := 1;
v_lock_obtained             boolean := FALSE;
v_max_partition_timestamp   timestamptz;
v_min_partition_timestamp   timestamptz;
v_parent_schema             text;
v_parent_tablename          text;
v_partition_expression      text;
v_partition_interval        interval;
v_partition_suffix          text;
v_partition_timestamp       timestamptz[];
v_source_schemaname         text;
v_source_tablename          text;
v_rowcount                  bigint;
v_start_control             timestamptz;
v_total_rows                bigint := 0;

BEGIN
/*
 * Populate the child table(s) of a time-based partition set with old data from the original parent
 */

SELECT partition_interval::interval
    , control
    , datetime_string
    , epoch
INTO v_partition_interval
    , v_control
    , v_datetime_string
    , v_epoch
FROM partman5.part_config
WHERE parent_table = p_parent_table;
IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: No entry in part_config found for given table:  %', p_parent_table;
END IF;

SELECT schemaname, tablename INTO v_source_schemaname, v_source_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(p_parent_table, '.', 1)::name
AND tablename = split_part(p_parent_table, '.', 2)::name;

-- Preserve real parent tablename for use below
v_parent_schema    := v_source_schemaname;
v_parent_tablename := v_source_tablename;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_source_schemaname, v_source_tablename, v_control);

IF v_control_type <> 'time' THEN
    IF (v_control_type = 'id' AND v_epoch = 'none') OR v_control_type <> 'id' THEN
        RAISE EXCEPTION 'Cannot run on partition set without time based control column or epoch flag set with an id column. Found control: %, epoch: %', v_control_type, v_epoch;
    END IF;
END IF;

-- Replace the parent variables with the source variables if using source table for child table data
IF p_source_table IS NOT NULL THEN
    -- Set source table to user given source table instead of parent table
    v_source_schemaname := NULL;
    v_source_tablename := NULL;

    SELECT schemaname, tablename INTO v_source_schemaname, v_source_tablename
    FROM pg_catalog.pg_tables
    WHERE schemaname = split_part(p_source_table, '.', 1)::name
    AND tablename = split_part(p_source_table, '.', 2)::name;

    IF v_source_tablename IS NULL THEN
        RAISE EXCEPTION 'Given source table does not exist in system catalogs: %', p_source_table;
    END IF;


ELSE

    IF p_batch_interval IS NOT NULL AND p_batch_interval != v_partition_interval THEN
        -- This is true because all data for a given child table must be moved out of the default partition before the child table can be created.
        -- So cannot create the child table when only some of the data has been moved out of the default partition.
        RAISE EXCEPTION 'Custom intervals are not allowed when moving data out of the DEFAULT partition. Please leave p_interval/p_batch_interval parameters unset or NULL to allow use of partition set''s default partitioning interval.';
    END IF;

    -- Set source table to default table if p_source_table is not set, and it exists
    -- Otherwise just return with a DEBUG that no data source exists
    SELECT n.nspname::text, c.relname::text
    INTO v_default_schemaname, v_default_tablename
    FROM pg_catalog.pg_inherits h
    JOIN pg_catalog.pg_class c ON c.oid = h.inhrelid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE h.inhparent = format('%I.%I', v_source_schemaname, v_source_tablename)::regclass
    AND pg_get_expr(relpartbound, c.oid) = 'DEFAULT';

    IF v_default_tablename IS NOT NULL THEN
        v_source_schemaname := v_default_schemaname;
        v_source_tablename := v_default_tablename;

        v_default_exists := true;
        EXECUTE format ('CREATE TEMP TABLE IF NOT EXISTS partman_temp_data_storage (LIKE %I.%I INCLUDING INDEXES) ON COMMIT DROP', v_source_schemaname, v_source_tablename);
    ELSE
        RAISE DEBUG 'No default table found when partition_data_time() was called';
        RETURN v_total_rows;
    END IF;
END IF;

IF p_batch_interval IS NULL OR p_batch_interval > v_partition_interval THEN
    p_batch_interval := v_partition_interval;
END IF;

SELECT partition_tablename INTO v_last_partition FROM partman5.show_partitions(p_parent_table, 'DESC') LIMIT 1;

v_partition_expression := CASE
    WHEN v_epoch = 'seconds' THEN format('to_timestamp(%I)', v_control)
    WHEN v_epoch = 'milliseconds' THEN format('to_timestamp((%I/1000)::float)', v_control)
    WHEN v_epoch = 'nanoseconds' THEN format('to_timestamp((%I/1000000000)::float)', v_control)
    ELSE format('%I', v_control)
END;

-- Generate column list to use in SELECT/INSERT statements below. Allows for exclusion of GENERATED (or any other desired) columns.
SELECT string_agg(quote_ident(attname), ',')
INTO v_column_list
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = v_source_schemaname
AND c.relname = v_source_tablename
AND a.attnum > 0
AND a.attisdropped = false
AND attname <> ALL(COALESCE(p_ignored_columns, ARRAY[]::text[]));

FOR i IN 1..p_batch_count LOOP

    IF p_order = 'ASC' THEN
        EXECUTE format('SELECT min(%s) FROM ONLY %I.%I', v_partition_expression, v_source_schemaname, v_source_tablename) INTO v_start_control;
    ELSIF p_order = 'DESC' THEN
        EXECUTE format('SELECT max(%s) FROM ONLY %I.%I', v_partition_expression, v_source_schemaname, v_source_tablename) INTO v_start_control;
    ELSE
        RAISE EXCEPTION 'Invalid value for p_order. Must be ASC or DESC';
    END IF;

    IF v_start_control IS NULL THEN
        EXIT;
    END IF;

    SELECT child_start_time INTO v_min_partition_timestamp FROM partman5.show_partition_info(v_source_schemaname||'.'||v_last_partition
        , v_partition_interval::text
        , p_parent_table);
    v_max_partition_timestamp := v_min_partition_timestamp + v_partition_interval;
    LOOP
        IF v_start_control >= v_min_partition_timestamp AND v_start_control < v_max_partition_timestamp THEN
            EXIT;
        ELSE
            BEGIN
                IF v_start_control >= v_max_partition_timestamp THEN
                    -- Keep going forward in time, checking if child partition time interval encompasses the current v_start_control value
                    v_min_partition_timestamp := v_max_partition_timestamp;
                    v_max_partition_timestamp := v_max_partition_timestamp + v_partition_interval;

                ELSE
                    -- Keep going backwards in time, checking if child partition time interval encompasses the current v_start_control value
                    v_max_partition_timestamp := v_min_partition_timestamp;
                    v_min_partition_timestamp := v_min_partition_timestamp - v_partition_interval;
                END IF;
            EXCEPTION WHEN datetime_field_overflow THEN
                RAISE EXCEPTION 'Attempted partition time interval is outside PostgreSQL''s supported time range.
                    Unable to create partition with interval before timestamp % ', v_min_partition_timestamp;
            END;
        END IF;
    END LOOP;

    v_partition_timestamp := ARRAY[v_min_partition_timestamp];
    IF p_order = 'ASC' THEN
        -- Ensure batch interval given as parameter doesn't cause maximum to overflow the current partition maximum
        IF (v_start_control + p_batch_interval) >= (v_min_partition_timestamp + v_partition_interval) THEN
            v_max_partition_timestamp := v_min_partition_timestamp + v_partition_interval;
        ELSE
            v_max_partition_timestamp := v_start_control + p_batch_interval;
        END IF;
    ELSIF p_order = 'DESC' THEN
        -- Must be greater than max value still in parent table since query below grabs < max
        v_max_partition_timestamp := v_min_partition_timestamp + v_partition_interval;
        -- Ensure batch interval given as parameter doesn't cause minimum to underflow current partition minimum
        IF (v_start_control - p_batch_interval) >= v_min_partition_timestamp THEN
            v_min_partition_timestamp = v_start_control - p_batch_interval;
        END IF;
    ELSE
        RAISE EXCEPTION 'Invalid value for p_order. Must be ASC or DESC';
    END IF;

-- do some locking with timeout, if required
    IF p_lock_wait > 0  THEN
        v_lock_iter := 0;
        WHILE v_lock_iter <= 5 LOOP
            v_lock_iter := v_lock_iter + 1;
            BEGIN
                EXECUTE format('SELECT %s FROM ONLY %I.%I WHERE %s >= %L AND %4$s < %6$L FOR UPDATE NOWAIT'
                    , v_column_list
                    , v_source_schemaname
                    , v_source_tablename
                    , v_partition_expression
                    , v_min_partition_timestamp
                    , v_max_partition_timestamp);
                v_lock_obtained := TRUE;
            EXCEPTION
                WHEN lock_not_available THEN
                    PERFORM pg_sleep( p_lock_wait / 5.0 );
                    CONTINUE;
            END;
            EXIT WHEN v_lock_obtained;
        END LOOP;
        IF NOT v_lock_obtained THEN
           RETURN -1;
        END IF;
    END IF;

    -- This suffix generation code is in create_partition_time() as well
    v_partition_suffix := to_char(v_min_partition_timestamp, v_datetime_string);
    v_current_partition_name := partman5.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);

    IF v_default_exists THEN
        -- Child tables cannot be created if data that belongs to it exists in the default
        -- Have to move data out to temporary location, create child table, then move it back

        -- Temp table created above to avoid excessive temp creation in loop
        EXECUTE format('WITH partition_data AS (
                DELETE FROM %1$I.%2$I WHERE %3$s >= %4$L AND %3$s < %5$L RETURNING *)
            INSERT INTO partman_temp_data_storage (%6$s) SELECT %6$s FROM partition_data'
            , v_source_schemaname
            , v_source_tablename
            , v_partition_expression
            , v_min_partition_timestamp
            , v_max_partition_timestamp
            , v_column_list);

        -- Set analyze to true if a table is created
        v_analyze := partman5.create_partition_time(p_parent_table, v_partition_timestamp);

        EXECUTE format('WITH partition_data AS (
                DELETE FROM partman_temp_data_storage RETURNING *)
            INSERT INTO %I.%I (%3$s) SELECT %3$s FROM partition_data'
            , v_parent_schema
            , v_current_partition_name
            , v_column_list);

    ELSE

        -- Set analyze to true if a table is created
        v_analyze := partman5.create_partition_time(p_parent_table, v_partition_timestamp);

        EXECUTE format('WITH partition_data AS (
                            DELETE FROM ONLY %I.%I WHERE %s >= %L AND %3$s < %5$L RETURNING *)
                         INSERT INTO %6$I.%7$I (%8$s) SELECT %8$s FROM partition_data'
                            , v_source_schemaname
                            , v_source_tablename
                            , v_partition_expression
                            , v_min_partition_timestamp
                            , v_max_partition_timestamp
                            , v_parent_schema
                            , v_current_partition_name
                            , v_column_list);
    END IF;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    v_total_rows := v_total_rows + v_rowcount;
    IF v_rowcount = 0 THEN
        EXIT;
    END IF;

END LOOP;

-- v_analyze is a local check if a new table is made.
-- p_analyze is a parameter to say whether to run the analyze at all. Used by create_parent() to avoid long exclusive lock or run_maintenence() to avoid long creation runs.
IF v_analyze AND p_analyze THEN
    RAISE DEBUG 'partiton_data_time: Begin analyze of %.%', v_parent_schema, v_parent_tablename;
    EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);
    RAISE DEBUG 'partiton_data_time: End analyze of %.%', v_parent_schema, v_parent_tablename;
END IF;

RETURN v_total_rows;

END
$_$;


ALTER FUNCTION partman5.partition_data_time(p_parent_table text, p_batch_count integer, p_batch_interval interval, p_lock_wait numeric, p_order text, p_analyze boolean, p_source_table text, p_ignored_columns text[]) OWNER TO api;

--
-- Name: partition_gap_fill(text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.partition_gap_fill(p_parent_table text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE

v_child_created                     boolean;
v_children_created_count            int := 0;
v_control                           text;
v_control_type                      text;
v_current_child_start_id            bigint;
v_current_child_start_timestamp     timestamptz;
v_epoch                             text;
v_expected_next_child_id            bigint;
v_expected_next_child_timestamp     timestamptz;
v_final_child_schemaname            text;
v_final_child_start_id              bigint;
v_final_child_start_timestamp       timestamptz;
v_final_child_tablename             text;
v_interval_id                       bigint;
v_interval_time                     interval;
v_previous_child_schemaname         text;
v_previous_child_tablename          text;
v_previous_child_start_id           bigint;
v_previous_child_start_timestamp    timestamptz;
v_parent_schema                     text;
v_parent_table                      text;
v_parent_tablename                  text;
v_partition_interval                text;
v_row                               record;

BEGIN

SELECT parent_table, partition_interval, control, epoch
INTO v_parent_table, v_partition_interval, v_control, v_epoch
FROM partman5.part_config
WHERE parent_table = p_parent_table;
IF v_parent_table IS NULL THEN
    RAISE EXCEPTION 'Given parent table has no configuration in pg_partman: %', p_parent_table;
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs. Ensure it is schema qualified: %', p_parent_table;
    END IF;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

SELECT partition_schemaname, partition_tablename
INTO v_final_child_schemaname, v_final_child_tablename
FROM partman5.show_partitions(v_parent_table, 'DESC')
LIMIT 1;

IF v_control_type = 'time'  OR (v_control_type = 'id' AND v_epoch <> 'none') THEN

    v_interval_time := v_partition_interval::interval;

    SELECT child_start_time INTO v_final_child_start_timestamp
        FROM partman5.show_partition_info(format('%s', v_final_child_schemaname||'.'||v_final_child_tablename), p_parent_table := v_parent_table);

    FOR v_row IN
        SELECT partition_schemaname, partition_tablename
        FROM partman5.show_partitions(v_parent_table, 'ASC')
    LOOP

        RAISE DEBUG 'v_row.partition_tablename: %, v_final_child_start_timestamp: %', v_row.partition_tablename, v_final_child_start_timestamp;

        IF v_previous_child_tablename IS NULL THEN
            v_previous_child_schemaname := v_row.partition_schemaname;
            v_previous_child_tablename := v_row.partition_tablename;
            SELECT child_start_time INTO v_previous_child_start_timestamp
                FROM partman5.show_partition_info(format('%s', v_previous_child_schemaname||'.'||v_previous_child_tablename), p_parent_table := v_parent_table);
            CONTINUE;
        END IF;

        v_expected_next_child_timestamp := v_previous_child_start_timestamp + v_interval_time;

        RAISE DEBUG 'v_expected_next_child_timestamp: %', v_expected_next_child_timestamp;

        IF v_expected_next_child_timestamp = v_final_child_start_timestamp THEN
            EXIT;
        END IF;

        SELECT child_start_time INTO v_current_child_start_timestamp
            FROM partman5.show_partition_info(format('%s', v_row.partition_schemaname||'.'||v_row.partition_tablename), p_parent_table := v_parent_table);

        RAISE DEBUG 'v_current_child_start_timestamp: %', v_current_child_start_timestamp;

        IF v_expected_next_child_timestamp != v_current_child_start_timestamp THEN
            v_child_created :=  partman5.create_partition_time(v_parent_table, ARRAY[v_expected_next_child_timestamp]);
            IF v_child_created THEN
                v_children_created_count := v_children_created_count + 1;
                v_child_created := false;
            END IF;
            SELECT partition_schema, partition_table INTO v_previous_child_schemaname, v_previous_child_tablename
                FROM partman5.show_partition_name(v_parent_table, v_expected_next_child_timestamp::text);
            -- Need to stay in another inner loop until the next expected child timestamp matches the current one
            -- Once it does, exit. This means gap is filled.
            LOOP
                v_previous_child_start_timestamp := v_expected_next_child_timestamp;
                v_expected_next_child_timestamp := v_expected_next_child_timestamp + v_interval_time;
                IF v_expected_next_child_timestamp = v_current_child_start_timestamp THEN
                    EXIT;
                ELSE

        RAISE DEBUG 'inner loop: v_previous_child_start_timestamp: %, v_expected_next_child_timestamp: %, v_children_created_count: %'
                , v_previous_child_start_timestamp, v_expected_next_child_timestamp, v_children_created_count;

                    v_child_created := partman5.create_partition_time(v_parent_table, ARRAY[v_expected_next_child_timestamp]);
                    IF v_child_created THEN
                        v_children_created_count := v_children_created_count + 1;
                        v_child_created := false;
                    END IF;
                END IF;
            END LOOP; -- end expected child loop
        END IF;

        v_previous_child_schemaname := v_row.partition_schemaname;
        v_previous_child_tablename := v_row.partition_tablename;
        SELECT child_start_time INTO v_previous_child_start_timestamp
            FROM partman5.show_partition_info(format('%s', v_previous_child_schemaname||'.'||v_previous_child_tablename), p_parent_table := v_parent_table);

    END LOOP; -- end time loop

ELSIF v_control_type = 'id' THEN

    v_interval_id := v_partition_interval::bigint;

    SELECT child_start_id INTO v_final_child_start_id
        FROM partman5.show_partition_info(format('%s', v_final_child_schemaname||'.'||v_final_child_tablename), p_parent_table := v_parent_table);

    FOR v_row IN
        SELECT partition_schemaname, partition_tablename
        FROM partman5.show_partitions(v_parent_table, 'ASC')
    LOOP

        RAISE DEBUG 'v_row.partition_tablename: %, v_final_child_start_id: %', v_row.partition_tablename, v_final_child_start_id;

        IF v_previous_child_tablename IS NULL THEN
            v_previous_child_schemaname := v_row.partition_schemaname;
            v_previous_child_tablename := v_row.partition_tablename;
            SELECT child_start_id INTO v_previous_child_start_id
                FROM partman5.show_partition_info(format('%s', v_previous_child_schemaname||'.'||v_previous_child_tablename), p_parent_table := v_parent_table);
            CONTINUE;
        END IF;

        v_expected_next_child_id := v_previous_child_start_id + v_interval_id;

        RAISE DEBUG 'v_expected_next_child_id: %', v_expected_next_child_id;

        IF v_expected_next_child_id = v_final_child_start_id THEN
            EXIT;
        END IF;

        SELECT child_start_id INTO v_current_child_start_id
            FROM partman5.show_partition_info(format('%s', v_row.partition_schemaname||'.'||v_row.partition_tablename), p_parent_table := v_parent_table);

        RAISE DEBUG 'v_current_child_start_id: %', v_current_child_start_id;

        IF v_expected_next_child_id != v_current_child_start_id THEN
            v_child_created :=  partman5.create_partition_id(v_parent_table, ARRAY[v_expected_next_child_id]);
            IF v_child_created THEN
                v_children_created_count := v_children_created_count + 1;
                v_child_created := false;
            END IF;
            SELECT partition_schema, partition_table INTO v_previous_child_schemaname, v_previous_child_tablename
                FROM partman5.show_partition_name(v_parent_table, v_expected_next_child_id::text);
            -- Need to stay in another inner loop until the next expected child id matches the current one
            -- Once it does, exit. This means gap is filled.
            LOOP
                v_previous_child_start_id := v_expected_next_child_id;
                v_expected_next_child_id := v_expected_next_child_id + v_interval_id;
                IF v_expected_next_child_id = v_current_child_start_id THEN
                    EXIT;
                ELSE

        RAISE DEBUG 'inner loop: v_previous_child_start_id: %, v_expected_next_child_id: %, v_children_created_count: %'
                , v_previous_child_start_id, v_expected_next_child_id, v_children_created_count;

                    v_child_created := partman5.create_partition_id(v_parent_table, ARRAY[v_expected_next_child_id]);
                    IF v_child_created THEN
                        v_children_created_count := v_children_created_count + 1;
                        v_child_created := false;
                    END IF;
                END IF;
            END LOOP; -- end expected child loop
        END IF;

        v_previous_child_schemaname := v_row.partition_schemaname;
        v_previous_child_tablename := v_row.partition_tablename;
        SELECT child_start_id INTO v_previous_child_start_id
            FROM partman5.show_partition_info(format('%s', v_previous_child_schemaname||'.'||v_previous_child_tablename), p_parent_table := v_parent_table);

    END LOOP; -- end id loop

END IF; -- end time/id if

RETURN v_children_created_count;

END
$$;


ALTER FUNCTION partman5.partition_gap_fill(p_parent_table text) OWNER TO api;

--
-- Name: reapply_constraints_proc(text, boolean, boolean, integer, boolean); Type: PROCEDURE; Schema: partman5; Owner: api
--

CREATE PROCEDURE partman5.reapply_constraints_proc(IN p_parent_table text, IN p_drop_constraints boolean DEFAULT false, IN p_apply_constraints boolean DEFAULT false, IN p_wait integer DEFAULT 0, IN p_dryrun boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $$
DECLARE

v_adv_lock                      boolean;
v_child_stop                    text;
v_control                       text;
v_control_type                  text;
v_datetime_string               text;
v_epoch                         text;
v_last_partition                text;
v_last_partition_id             bigint;
v_last_partition_timestamp      timestamptz;
v_optimize_constraint           int;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_interval            text;
v_partition_suffix              text;
v_premake                       int;
v_row                           record;
v_sql                           text;

BEGIN
/*
 * Procedure for reapplying additional constraints managed by pg_partman on child tables. See docs for additional info on this special constraint management.
 * Procedure can run in two distinct modes: 1) Drop all constraints  2) Apply all constraints.
 * If both modes are run in a single call, drop is run before apply.
 * Typical usage would be to run the drop mode, edit the data, then run apply mode to re-create all constraints on a partition set."
 */

v_adv_lock := pg_try_advisory_lock(hashtext('pg_partman reapply_constraints'));
IF v_adv_lock = false THEN
    RAISE NOTICE 'Partman reapply_constraints_proc already running or another session has not released its advisory lock.';
    RETURN;
END IF;


SELECT control, premake, optimize_constraint, datetime_string, epoch, partition_interval
INTO v_control, v_premake, v_optimize_constraint, v_datetime_string, v_epoch, v_partition_interval
FROM partman5.part_config
WHERE parent_table = p_parent_table;
IF v_premake IS NULL THEN
    RAISE EXCEPTION 'Unable to find given parent in pg_partman config: %. This procedure is only meant to be called on pg_partman managed partition sets.', p_parent_table;
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs. Ensure it is schema qualified: %', p_parent_table;
    END IF;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

-- Determine child table to stop creating constraints on based on optimize_constraint value
-- Same code in apply_constraints.sql
SELECT partition_tablename INTO v_last_partition FROM partman5.show_partitions(p_parent_table, 'DESC') LIMIT 1;

IF v_control_type = 'time' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN
    SELECT child_start_time INTO v_last_partition_timestamp FROM partman5.show_partition_info(v_parent_schema||'.'||v_last_partition, v_partition_interval, p_parent_table);
    v_partition_suffix := to_char(v_last_partition_timestamp - (v_partition_interval::interval * (v_optimize_constraint + v_premake + 1) ), v_datetime_string);
ELSIF v_control_type = 'id' THEN
    SELECT child_start_id INTO v_last_partition_id FROM partman5.show_partition_info(v_parent_schema||'.'||v_last_partition, v_partition_interval, p_parent_table);
    v_partition_suffix := (v_last_partition_id - (v_partition_interval::bigint * (v_optimize_constraint + v_premake + 1) ))::text;
END IF;

v_child_stop := partman5.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);

v_sql := format('SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(%L, %L)', p_parent_table, 'ASC');

RAISE DEBUG 'reapply_constraint: v_parent_tablename: % , v_partition_suffix: %, v_child_stop: %,  v_sql: %', v_parent_tablename, v_partition_suffix, v_child_stop, v_sql;

v_row := NULL;
FOR v_row IN EXECUTE v_sql LOOP
    IF p_drop_constraints THEN
        IF p_dryrun THEN
            RAISE NOTICE 'DRYRUN NOTICE: Dropping constraints on child table: %.%', v_row.partition_schemaname, v_row.partition_tablename;
        ELSE
            RAISE DEBUG 'reapply_constraint drop: %.%', v_row.partition_schemaname, v_row.partition_tablename;
            PERFORM partman5.drop_constraints(p_parent_table, format('%s.%s', v_row.partition_schemaname, v_row.partition_tablename)::text);
        END IF;
    END IF; -- end drop
    COMMIT;

    IF p_apply_constraints THEN
        IF p_dryrun THEN
            RAISE NOTICE 'DRYRUN NOTICE: Applying constraints on child table: %.%', v_row.partition_schemaname, v_row.partition_tablename;
        ELSE
            RAISE DEBUG 'reapply_constraint apply: %.%', v_row.partition_schemaname, v_row.partition_tablename;
            PERFORM partman5.apply_constraints(p_parent_table, format('%s.%s', v_row.partition_schemaname, v_row.partition_tablename)::text);
        END IF;
    END IF; -- end apply

    IF v_row.partition_tablename = v_child_stop THEN
        RAISE DEBUG 'reapply_constraint: Reached stop at %.%', v_row.partition_schemaname, v_row.partition_tablename;
        EXIT; -- stop creating constraints after optimize target is reached
    END IF;
    COMMIT;
    PERFORM pg_sleep(p_wait);
END LOOP;

EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);

PERFORM pg_advisory_unlock(hashtext('pg_partman reapply_constraints'));
END
$$;


ALTER PROCEDURE partman5.reapply_constraints_proc(IN p_parent_table text, IN p_drop_constraints boolean, IN p_apply_constraints boolean, IN p_wait integer, IN p_dryrun boolean) OWNER TO api;

--
-- Name: reapply_privileges(text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.reapply_privileges(p_parent_table text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context          text;
ex_detail           text;
ex_hint             text;
ex_message          text;
v_job_id            bigint;
v_jobmon            boolean;
v_jobmon_schema     text;
v_new_search_path   text;
v_old_search_path   text;
v_parent_schema     text;
v_parent_tablename  text;
v_row               record;
v_step_id           bigint;

BEGIN

/*
 * Function to re-apply ownership & privileges on all child tables in a partition set using parent table as reference
 */

SELECT jobmon INTO v_jobmon FROM partman5.part_config WHERE parent_table = p_parent_table;
IF v_jobmon IS NULL THEN
    RAISE EXCEPTION 'Given table is not managed by this extention: %', p_parent_table;
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_tables
WHERE schemaname = split_part(p_parent_table, '.', 1)::name
AND tablename = split_part(p_parent_table, '.', 2)::name;
IF v_parent_tablename IS NULL THEN
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
    RAISE EXCEPTION 'Given parent table does not exist: %', p_parent_table;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN RE-APPLYING PRIVILEGES TO ALL CHILD TABLES OF: %s', p_parent_table));
END IF;

FOR v_row IN
    SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_table, 'ASC', p_include_default := true)
LOOP
    PERFORM partman5.apply_privileges(v_parent_schema, v_parent_tablename, v_row.partition_schemaname, v_row.partition_tablename, v_job_id);
END LOOP;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN RE-APPLYING PRIVILEGES TO ALL CHILD TABLES OF: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.reapply_privileges(p_parent_table text) OWNER TO api;

--
-- Name: run_analyze(boolean, boolean, text); Type: PROCEDURE; Schema: partman5; Owner: api
--

CREATE PROCEDURE partman5.run_analyze(IN p_skip_locked boolean DEFAULT false, IN p_quiet boolean DEFAULT false, IN p_parent_table text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE

v_adv_lock              boolean;
v_parent_schema         text;
v_parent_tablename      text;
v_row                   record;
v_sql                   text;

BEGIN

v_adv_lock := pg_try_advisory_lock(hashtext('pg_partman run_analyze'));
IF v_adv_lock = false THEN
    RAISE NOTICE 'Partman analyze already running or another session has not released its advisory lock.';
    RETURN;
END IF;

FOR v_row IN SELECT parent_table FROM partman5.part_config
LOOP

    IF p_parent_table IS NOT NULL THEN
        IF p_parent_table != v_row.parent_table THEN
            CONTINUE;
        END IF;
    END IF;

    SELECT n.nspname, c.relname
    INTO v_parent_schema, v_parent_tablename
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = split_part(v_row.parent_table, '.', 1)::name
    AND c.relname = split_part(v_row.parent_table, '.', 2)::name;

    v_sql := 'ANALYZE ';
    IF p_skip_locked THEN
        v_sql := v_sql || 'SKIP LOCKED ';
    END IF;
    v_sql := format('%s %I.%I', v_sql, v_parent_schema, v_parent_tablename);

    IF p_quiet = 'false' THEN
        RAISE NOTICE 'Analyzed partitioned table: %.%', v_parent_schema, v_parent_tablename;
    END IF;
    EXECUTE v_sql;
    COMMIT;

END LOOP;

PERFORM pg_advisory_unlock(hashtext('pg_partman run_analyze'));
END
$$;


ALTER PROCEDURE partman5.run_analyze(IN p_skip_locked boolean, IN p_quiet boolean, IN p_parent_table text) OWNER TO api;

--
-- Name: run_maintenance(text, boolean, boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.run_maintenance(p_parent_table text DEFAULT NULL::text, p_analyze boolean DEFAULT false, p_jobmon boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_adv_lock                      boolean;
v_analyze                       boolean := FALSE;
v_check_subpart                 int;
v_control_type                  text;
v_create_count                  int := 0;
v_current_partition_id          bigint;
v_current_partition_timestamp   timestamptz;
v_default_tablename             text;
v_drop_count                    int := 0;
v_exact_control_type            text;
v_is_default                    text;
v_job_id                        bigint;
v_jobmon_schema                 text;
v_last_partition                text;
v_last_partition_created        boolean;
v_last_partition_id             bigint;
v_last_partition_timestamp      timestamptz;
v_max_id                        bigint;
v_max_id_default                bigint;
v_max_time_default              timestamptz;
v_max_timestamp                 timestamptz;
v_new_search_path               text;
v_next_partition_id             bigint;
v_next_partition_timestamp      timestamptz;
v_old_search_path               text;
v_parent_exists                 text;
v_parent_oid                    oid;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_expression          text;
v_premade_count                 int;
v_row                           record;
v_row_max_id                    record;
v_row_max_time                  record;
v_sql                           text;
v_step_id                       bigint;
v_step_overflow_id              bigint;
v_sub_id_max                    bigint;
v_sub_id_max_suffix             bigint;
v_sub_id_min                    bigint;
v_sub_parent                    text;
v_sub_timestamp_max             timestamptz;
v_sub_timestamp_max_suffix      timestamptz;
v_sub_timestamp_min             timestamptz;
v_tables_list_sql               text;

BEGIN
/*
 * Function to manage pre-creation of the next partitions in a set.
 * Also manages dropping old partitions if the retention option is set.
 * If p_parent_table is passed, will only run run_maintenance() on that one table (no matter what the configuration table may have set for it)
 * Otherwise, will run on all tables in the config table with p_automatic_maintenance() set to true.
 * For large partition sets, running analyze can cause maintenance to take longer than expected so is not done by default. Can set p_analyze to true to force analyze. Be aware that constraint exclusion may not work properly until an analyze on the partition set is run.
 */

v_adv_lock := pg_try_advisory_xact_lock(hashtext('pg_partman run_maintenance'));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'Partman maintenance already running.';
    RETURN;
END IF;

IF pg_is_in_recovery() THEN
    RAISE DEBUG 'pg_partmain maintenance called on replica. Doing nothing.';
    RETURN;
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF p_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job('PARTMAN RUN MAINTENANCE');
    v_step_id := add_step(v_job_id, 'Running maintenance loop');
END IF;

v_tables_list_sql := 'SELECT parent_table
                , partition_type
                , partition_interval
                , control
                , premake
                , undo_in_progress
                , sub_partition_set_full
                , epoch
                , infinite_time_partitions
                , retention
                , ignore_default_data
                , datetime_string
                , maintenance_order
            FROM partman5.part_config
            WHERE undo_in_progress = false';

IF p_parent_table IS NULL THEN
    v_tables_list_sql := v_tables_list_sql || format(' AND automatic_maintenance = %L ', 'on');
ELSE
    v_tables_list_sql := v_tables_list_sql || format(' AND parent_table = %L ', p_parent_table);
END IF;

v_tables_list_sql := v_tables_list_sql || format(' ORDER BY maintenance_order ASC NULLS LAST, parent_table ASC NULLS LAST ');

RAISE DEBUG 'run_maint: v_tables_list_sql: %', v_tables_list_sql;

FOR v_row IN EXECUTE v_tables_list_sql
LOOP

    CONTINUE WHEN v_row.undo_in_progress;

    -- When sub-partitioning, retention may drop tables that were already put into the query loop values.
    -- Check if they still exist in part_config before continuing
    v_parent_exists := NULL;
    SELECT parent_table INTO v_parent_exists FROM partman5.part_config WHERE parent_table = v_row.parent_table;
    IF v_parent_exists IS NULL THEN
        RAISE DEBUG 'run_maint: Parent table possibly removed from part_config by retenion';
    END IF;
    CONTINUE WHEN v_parent_exists IS NULL;

    -- Check for old quarterly and ISO weekly partitioning from prior to version 5.x. Error out to avoid breaking these partition sets
    -- with new datetime_string formats
    IF v_row.datetime_string IN ('YYYY"q"Q', 'IYYY"w"IW') THEN
        RAISE EXCEPTION 'Quarterly and ISO weekly partitioning is no longer supported in pg_partman 5.0.0 and greater. Please see documentation for migrating away from these partitioning patterns. Partition set: %', v_row.parent_table;
    END IF;

    -- Check for consistent data in part_config_sub table. Was unable to get this working properly as either a constraint or trigger.
    -- Would either delay raising an error until the next write (which I cannot predict) or disallow future edits to update a sub-partition set's configuration.
    -- This way at least provides a consistent way to check that I know will run. If anyone can get a working constraint/trigger, please help!
    SELECT sub_parent INTO v_sub_parent FROM partman5.part_config_sub WHERE sub_parent = v_row.parent_table;
    IF v_sub_parent IS NOT NULL THEN
        SELECT count(*) INTO v_check_subpart FROM partman5.check_subpart_sameconfig(v_row.parent_table);
        IF v_check_subpart > 1 THEN
            RAISE EXCEPTION 'Inconsistent data in part_config_sub table. Sub-partition tables that are themselves sub-partitions cannot have differing configuration values among their siblings.
            Run this query: "SELECT * FROM partman5.check_subpart_sameconfig(''%'');" This should only return a single row or nothing.
            If multiple rows are returned, the results are differing configurations in the part_config_sub table for children of the given parent.
            Determine the child tables of the given parent and look up their entries based on the "part_config_sub.sub_parent" column.
            Update the differing values to be consistent for your desired values.', v_row.parent_table;
        END IF;
    END IF;

    SELECT n.nspname, c.relname, c.oid
    INTO v_parent_schema, v_parent_tablename, v_parent_oid
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = split_part(v_row.parent_table, '.', 1)::name
    AND c.relname = split_part(v_row.parent_table, '.', 2)::name;

    -- Always returns the default partition first if it exists
    SELECT partition_tablename INTO v_default_tablename
    FROM partman5.show_partitions(v_row.parent_table, p_include_default := true) LIMIT 1;

    SELECT pg_get_expr(relpartbound, v_parent_oid) INTO v_is_default
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n on c.relnamespace = n.oid
    WHERE n.nspname = v_parent_schema
    AND c.relname = v_default_tablename;

    IF v_is_default != 'DEFAULT' THEN
        -- Parent table will never have data, but allows code below to "just work"
        v_default_tablename := v_parent_tablename;
    END IF;

    SELECT general_type, exact_type
    INTO v_control_type, v_exact_control_type
    FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_row.control);

    v_partition_expression := CASE
        WHEN v_row.epoch = 'seconds' THEN format('to_timestamp(%I)', v_row.control)
        WHEN v_row.epoch = 'milliseconds' THEN format('to_timestamp((%I/1000)::float)', v_row.control)
        WHEN v_row.epoch = 'nanoseconds' THEN format('to_timestamp((%I/1000000000)::float)', v_row.control)
        ELSE format('%I', v_row.control)
    END;
    RAISE DEBUG 'run_maint: v_partition_expression: %', v_partition_expression;

    SELECT partition_tablename INTO v_last_partition FROM partman5.show_partitions(v_row.parent_table, 'DESC') LIMIT 1;
    RAISE DEBUG 'run_maint: parent_table: %, v_last_partition: %', v_row.parent_table, v_last_partition;

    IF v_control_type = 'time' OR (v_control_type = 'id' AND v_row.epoch <> 'none') THEN

        -- Run retention if needed
        IF v_row.retention IS NOT NULL THEN
            v_drop_count := v_drop_count + partman5.drop_partition_time(v_row.parent_table);
        END IF;

        IF v_row.sub_partition_set_full THEN
            UPDATE partman5.part_config SET maintenance_last_run = clock_timestamp() WHERE parent_table = v_row.parent_table;
            CONTINUE;
        END IF;

        SELECT child_start_time INTO v_last_partition_timestamp
            FROM partman5.show_partition_info(v_parent_schema||'.'||v_last_partition, v_row.partition_interval, v_row.parent_table);

        -- Must be reset to null otherwise if the next partition set in the loop is empty, the previous partition set's value could be used
        v_current_partition_timestamp := NULL;

        -- Loop through child tables starting from highest to get current max value in partition set
        -- Avoids doing a scan on entire partition set and/or getting any values accidentally in default.
        FOR v_row_max_time IN
            SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(v_row.parent_table, 'DESC', false)
        LOOP
            EXECUTE format('SELECT max(%s)::text FROM %I.%I'
                                , v_partition_expression
                                , v_row_max_time.partition_schemaname
                                , v_row_max_time.partition_tablename
                            ) INTO v_max_timestamp;

            IF v_row.infinite_time_partitions AND v_max_timestamp < CURRENT_TIMESTAMP THEN
                -- No new data has been inserted relative to "now", but keep making child tables anyway
                v_current_partition_timestamp = CURRENT_TIMESTAMP;
                -- Nothing else to do in this case so just end early
                EXIT;
            END IF;
            IF v_max_timestamp IS NOT NULL THEN
                SELECT suffix_timestamp INTO v_current_partition_timestamp FROM partman5.show_partition_name(v_row.parent_table, v_max_timestamp::text);
                EXIT;
            END IF;
        END LOOP;
        IF v_row.infinite_time_partitions AND v_max_timestamp IS NULL THEN
            -- If partition set is completely empty, still keep making child tables anyway
            -- Has to be separate check outside above loop since "future" tables are likely going to be empty and make max value in that loop NULL
            v_current_partition_timestamp = CURRENT_TIMESTAMP;
        END IF;


        -- If not ignoring the default table, check for max values there. If they are there and greater than all child values, use that instead
        -- Note the default is NOT to care about data in the default, so maintenance will fail if new child table boundaries overlap with
        --  data that exists in the default. This is intentional so user removes data from default to avoid larger problems.
        IF v_row.ignore_default_data THEN
            v_max_time_default := NULL;
        ELSE
            EXECUTE format('SELECT max(%s) FROM ONLY %I.%I', v_partition_expression, v_parent_schema, v_default_tablename) INTO v_max_time_default;
        END IF;
        RAISE DEBUG 'run_maint: v_current_partition_timestamp: %, v_max_time_default: %', v_current_partition_timestamp, v_max_time_default;
        IF v_current_partition_timestamp IS NULL AND v_max_time_default IS NULL THEN
            -- Partition set is completely empty and infinite time partitions not set
            -- Nothing to do
            UPDATE partman5.part_config SET maintenance_last_run = clock_timestamp() WHERE parent_table = v_row.parent_table;
            CONTINUE;
        END IF;
        RAISE DEBUG 'run_maint: v_max_timestamp: %, v_current_partition_timestamp: %, v_max_time_default: %', v_max_timestamp, v_current_partition_timestamp, v_max_time_default;
        IF v_current_partition_timestamp IS NULL OR (v_max_time_default > v_current_partition_timestamp) THEN
            SELECT suffix_timestamp INTO v_current_partition_timestamp FROM partman5.show_partition_name(v_row.parent_table, v_max_time_default::text);
        END IF;

        -- If this is a subpartition, determine if the last child table has been made. If so, mark it as full so future maintenance runs can skip it
        SELECT sub_min::timestamptz, sub_max::timestamptz INTO v_sub_timestamp_min, v_sub_timestamp_max FROM partman5.check_subpartition_limits(v_row.parent_table, 'time');
        IF v_sub_timestamp_max IS NOT NULL THEN
            SELECT suffix_timestamp INTO v_sub_timestamp_max_suffix FROM partman5.show_partition_name(v_row.parent_table, v_sub_timestamp_max::text);
            IF v_sub_timestamp_max_suffix = v_last_partition_timestamp THEN
                -- Final partition for this set is created. Set full and skip it
                UPDATE partman5.part_config
                SET sub_partition_set_full = true, maintenance_last_run = clock_timestamp()
                WHERE parent_table = v_row.parent_table;
                CONTINUE;
            END IF;
        END IF;

        -- Check and see how many premade partitions there are.
        v_premade_count = round(EXTRACT('epoch' FROM age(v_last_partition_timestamp, v_current_partition_timestamp)) / EXTRACT('epoch' FROM v_row.partition_interval::interval));
        v_next_partition_timestamp := v_last_partition_timestamp;
        RAISE DEBUG 'run_maint before loop: last_partition_timestamp: %, current_partition_timestamp: %, v_premade_count: %, v_sub_timestamp_min: %, v_sub_timestamp_max: %'
            , v_last_partition_timestamp
            , v_current_partition_timestamp
            , v_premade_count
            , v_sub_timestamp_min
            , v_sub_timestamp_max;
        -- Loop premaking until config setting is met. Allows it to catch up if it fell behind or if premake changed
        WHILE (v_premade_count < v_row.premake) LOOP
            RAISE DEBUG 'run_maint: parent_table: %, v_premade_count: %, v_next_partition_timestamp: %', v_row.parent_table, v_premade_count, v_next_partition_timestamp;
            IF v_next_partition_timestamp < v_sub_timestamp_min OR v_next_partition_timestamp > v_sub_timestamp_max THEN
                -- With subpartitioning, no need to run if the timestamp is not in the parent table's range
                EXIT;
            END IF;
            BEGIN
                v_next_partition_timestamp := v_next_partition_timestamp + v_row.partition_interval::interval;
            EXCEPTION WHEN datetime_field_overflow THEN
                v_premade_count := v_row.premake; -- do this so it can exit the premake check loop and continue in the outer for loop
                IF v_jobmon_schema IS NOT NULL THEN
                    v_step_overflow_id := add_step(v_job_id, 'Attempted partition time interval is outside PostgreSQL''s supported time range.');
                    PERFORM update_step(v_step_overflow_id, 'CRITICAL', format('Child partition creation skipped for parent table: %s', v_partition_time));
                END IF;
                RAISE WARNING 'Attempted partition time interval is outside PostgreSQL''s supported time range. Child partition creation skipped for parent table %', v_row.parent_table;
                CONTINUE;
            END;

            v_last_partition_created := partman5.create_partition_time(v_row.parent_table
                                                        , ARRAY[v_next_partition_timestamp]);
            IF v_last_partition_created THEN
                v_analyze := true;
                v_create_count := v_create_count + 1;
            END IF;

            v_premade_count = round(EXTRACT('epoch' FROM age(v_next_partition_timestamp, v_current_partition_timestamp)) / EXTRACT('epoch' FROM v_row.partition_interval::interval));
        END LOOP;

    ELSIF v_control_type = 'id' THEN

        -- Run retention if needed
        IF v_row.retention IS NOT NULL THEN
            v_drop_count := v_drop_count + partman5.drop_partition_id(v_row.parent_table);
        END IF;

        IF v_row.sub_partition_set_full THEN
            UPDATE partman5.part_config SET maintenance_last_run = clock_timestamp() WHERE parent_table = v_row.parent_table;
            CONTINUE;
        END IF;

        -- Must be reset to null otherwise if the next partition set in the loop is empty, the previous partition set's value could be used
        v_current_partition_id := NULL;

        FOR v_row_max_id IN
            SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(v_row.parent_table, 'DESC', false)
        LOOP
            -- Loop through child tables starting from highest to get current max value in partition set
            -- Avoids doing a scan on entire partition set and/or getting any values accidentally in default.
            EXECUTE format('SELECT trunc(max(%I))::bigint FROM %I.%I'
                            , v_row.control
                            , v_row_max_id.partition_schemaname
                            , v_row_max_id.partition_tablename) INTO v_max_id;
            IF v_max_id IS NOT NULL THEN
                SELECT suffix_id INTO v_current_partition_id FROM partman5.show_partition_name(v_row.parent_table, v_max_id::text);
                EXIT;
            END IF;
        END LOOP;
        -- If not ignoring the default table, check for max values there. If they are there and greater than all child values, use that instead
        -- Note the default is NOT to care about data in the default, so maintenance will fail if new child table boundaries overlap with
        --  data that exists in the default. This is intentional so user removes data from default to avoid larger problems.
        IF v_row.ignore_default_data THEN
            v_max_id_default := NULL;
        ELSE
            EXECUTE format('SELECT trunc(max(%I))::bigint FROM ONLY %I.%I', v_row.control, v_parent_schema, v_default_tablename) INTO v_max_id_default;
        END IF;
        RAISE DEBUG 'run_maint: v_max_id: %, v_current_partition_id: %, v_max_id_default: %', v_max_id, v_current_partition_id, v_max_id_default;
        IF v_current_partition_id IS NULL AND v_max_id_default IS NULL THEN
            -- Partition set is completely empty. Nothing to do
            UPDATE partman5.part_config SET maintenance_last_run = clock_timestamp() WHERE parent_table = v_row.parent_table;
            CONTINUE;
        END IF;
        IF v_current_partition_id IS NULL OR (v_max_id_default > v_current_partition_id) THEN
            SELECT suffix_id INTO v_current_partition_id FROM partman5.show_partition_name(v_row.parent_table, v_max_id_default::text);
        END IF;

        SELECT child_start_id INTO v_last_partition_id
            FROM partman5.show_partition_info(v_parent_schema||'.'||v_last_partition, v_row.partition_interval, v_row.parent_table);
        -- Determine if this table is a child of a subpartition parent. If so, get limits to see if run_maintenance even needs to run for it.
        SELECT sub_min::bigint, sub_max::bigint INTO v_sub_id_min, v_sub_id_max FROM partman5.check_subpartition_limits(v_row.parent_table, 'id');

        IF v_sub_id_max IS NOT NULL THEN
            SELECT suffix_id INTO v_sub_id_max_suffix FROM partman5.show_partition_name(v_row.parent_table, v_sub_id_max::text);
            IF v_sub_id_max_suffix = v_last_partition_id THEN
                -- Final partition for this set is created. Set full and skip it
                UPDATE partman5.part_config
                SET sub_partition_set_full = true, maintenance_last_run = clock_timestamp()
                WHERE parent_table = v_row.parent_table;
                CONTINUE;
            END IF;
        END IF;

        v_next_partition_id := v_last_partition_id;
        v_premade_count := ((v_last_partition_id - v_current_partition_id) / v_row.partition_interval::bigint);
        -- Loop premaking until config setting is met. Allows it to catch up if it fell behind or if premake changed.
        RAISE DEBUG 'run_maint: before child creation loop: parent_table: %, v_last_partition_id: %, v_premade_count: %, v_next_partition_id: %', v_row.parent_table, v_last_partition_id, v_premade_count, v_next_partition_id;
        WHILE (v_premade_count < v_row.premake) LOOP
            RAISE DEBUG 'run_maint: parent_table: %, v_premade_count: %, v_next_partition_id: %', v_row.parent_table, v_premade_count, v_next_partition_id;
            IF v_next_partition_id < v_sub_id_min OR v_next_partition_id > v_sub_id_max THEN
                -- With subpartitioning, no need to run if the id is not in the parent table's range
                EXIT;
            END IF;
            v_next_partition_id := v_next_partition_id + v_row.partition_interval::bigint;
            v_last_partition_created := partman5.create_partition_id(v_row.parent_table, ARRAY[v_next_partition_id]);
            IF v_last_partition_created THEN
                v_analyze := true;
                v_create_count := v_create_count + 1;
            END IF;
            v_premade_count := ((v_next_partition_id - v_current_partition_id) / v_row.partition_interval::bigint);
        END LOOP;

    END IF; -- end main IF check for time or id

    IF v_analyze AND p_analyze THEN
        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, format('Analyzing partition set: %s', v_row.parent_table));
        END IF;

        EXECUTE format('ANALYZE %I.%I',v_parent_schema, v_parent_tablename);

        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', 'Done');
        END IF;
    END IF;

    UPDATE partman5.part_config SET maintenance_last_run = clock_timestamp() WHERE parent_table = v_row.parent_table;

END LOOP; -- end of main loop through part_config

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, format('Finished maintenance'));
    PERFORM update_step(v_step_id, 'OK', format('Partition maintenance finished. %s partitions made. %s partitions dropped.', v_create_count, v_drop_count));
    IF v_step_overflow_id IS NOT NULL THEN
        PERFORM fail_job(v_job_id);
    ELSE
        PERFORM close_job(v_job_id);
    END IF;
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN RUN MAINTENANCE'')', v_jobmon_schema) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


ALTER FUNCTION partman5.run_maintenance(p_parent_table text, p_analyze boolean, p_jobmon boolean) OWNER TO api;

--
-- Name: run_maintenance_proc(integer, boolean, boolean); Type: PROCEDURE; Schema: partman5; Owner: api
--

CREATE PROCEDURE partman5.run_maintenance_proc(IN p_wait integer DEFAULT 0, IN p_analyze boolean DEFAULT false, IN p_jobmon boolean DEFAULT true)
    LANGUAGE plpgsql
    AS $$
DECLARE

v_adv_lock              boolean;
v_parent_table          text;
v_sql                   text;

BEGIN

v_adv_lock := pg_try_advisory_lock(hashtext('pg_partman run_maintenance procedure'));
IF v_adv_lock = false THEN
    RAISE NOTICE 'Partman maintenance procedure already running or another session has not released its advisory lock.';
    RETURN;
END IF;

IF pg_is_in_recovery() THEN
    RAISE DEBUG 'pg_partmain maintenance procedure called on replica. Doing nothing.';
    RETURN;
END IF;

FOR v_parent_table IN
    SELECT parent_table
    FROM partman5.part_config
    WHERE undo_in_progress = false
    AND automatic_maintenance = 'on'
    ORDER BY maintenance_order ASC NULLS LAST
LOOP
/*
 * Run maintenance with a commit between each partition set
 */
    v_sql := format('SELECT %s.run_maintenance(%L, p_jobmon := %L',
        'partman5', v_parent_table, p_jobmon);

    IF p_analyze IS NOT NULL THEN
        v_sql := v_sql || format(', p_analyze := %L', p_analyze);
    END IF;

    v_sql := v_sql || ')';

    RAISE DEBUG 'v_sql run_maintenance_proc: %', v_sql;

    EXECUTE v_sql;
    COMMIT;

    PERFORM pg_sleep(p_wait);

END LOOP;

PERFORM pg_advisory_unlock(hashtext('pg_partman run_maintenance procedure'));
END
$$;


ALTER PROCEDURE partman5.run_maintenance_proc(IN p_wait integer, IN p_analyze boolean, IN p_jobmon boolean) OWNER TO api;

--
-- Name: show_partition_info(text, text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.show_partition_info(p_child_table text, p_partition_interval text DEFAULT NULL::text, p_parent_table text DEFAULT NULL::text, OUT child_start_time timestamp with time zone, OUT child_end_time timestamp with time zone, OUT child_start_id bigint, OUT child_end_id bigint, OUT suffix text) RETURNS record
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE

v_child_schema          text;
v_child_tablename       text;
v_control               text;
v_control_type          text;
v_epoch                 text;
v_exact_control_type    text;
v_parent_table          text;
v_partstrat             char;
v_partition_interval    text;
v_start_string          text;

BEGIN
/*
 * Show the data boundaries for a given child table as well as the suffix that will be used.
 * Passing the parent table argument slightly improves performance by avoiding a catalog lookup.
 * Passing an interval lets you set one different than the default configured one if desired.
 */

SELECT n.nspname, c.relname INTO v_child_schema, v_child_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_child_table, '.', 1)::name
AND c.relname = split_part(p_child_table, '.', 2)::name;

IF v_child_tablename IS NULL THEN
    IF p_parent_table IS NOT NULL THEN
        RAISE EXCEPTION 'Child table given does not exist (%) for given parent table (%)', p_child_table, p_parent_table;
    ELSE
        RAISE EXCEPTION 'Child table given does not exist (%)', p_child_table;
    END IF;
END IF;

IF p_parent_table IS NULL THEN
    SELECT n.nspname||'.'|| c.relname INTO v_parent_table
    FROM pg_catalog.pg_inherits h
    JOIN pg_catalog.pg_class c ON c.oid = h.inhparent
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE h.inhrelid::regclass = p_child_table::regclass;
ELSE
    v_parent_table := p_parent_table;
END IF;

SELECT p.partstrat INTO v_partstrat
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
JOIN pg_catalog.pg_partitioned_table p ON c.oid = p.partrelid
WHERE n.nspname = split_part(v_parent_table, '.', 1)::name
AND c.relname = split_part(v_parent_table, '.', 2)::name;

IF p_partition_interval IS NULL THEN
    SELECT control, partition_interval, epoch
    INTO v_control, v_partition_interval, v_epoch
    FROM partman5.part_config WHERE parent_table = v_parent_table;
ELSE
    v_partition_interval := p_partition_interval;
    SELECT control, epoch
    INTO v_control, v_epoch
    FROM partman5.part_config WHERE parent_table = v_parent_table;
END IF;

IF v_control IS NULL THEN
    RAISE EXCEPTION 'Parent table of given child not managed by pg_partman: %', v_parent_table;
END IF;

SELECT general_type, exact_type INTO v_control_type, v_exact_control_type FROM partman5.check_control_type(v_child_schema, v_child_tablename, v_control);

RAISE DEBUG 'show_partition_info: v_child_schema: %, v_child_tablename: %, v_control_type: %, v_exact_control_type: %',
            v_child_schema, v_child_tablename, v_control_type, v_exact_control_type;

-- Look at actual partition bounds in catalog and pull values from there.
IF v_partstrat = 'r' THEN
    SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid, true)
        , $REGEX$\(([^)]+)\) TO \(([^)]+)\)$REGEX$))[1]::text
    INTO v_start_string
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_child_tablename
    AND n.nspname = v_child_schema;
ELSIF v_partstrat = 'l' THEN
    SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid, true)
        , $REGEX$FOR VALUES IN \(([^)])\)$REGEX$))[1]::text
    INTO v_start_string
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_child_tablename
    AND n.nspname = v_child_schema;
ELSE
    RAISE EXCEPTION 'partman functions only work with list partitioning with integers and ranged partitioning with time or integers. Found partition strategy "%" for given partition set', v_partstrat;
END IF;

IF v_control_type = 'time' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN

    IF v_control_type = 'time' THEN
        child_start_time := v_start_string::timestamptz;
    ELSIF (v_control_type = 'id' AND v_epoch <> 'none') THEN
        -- bigint data type is stored as a single-quoted string in the partition expression. Must strip quotes for valid type-cast.
        v_start_string := trim(BOTH '''' FROM v_start_string);
        IF v_epoch = 'seconds' THEN
            child_start_time := to_timestamp(v_start_string::double precision);
        ELSIF v_epoch = 'milliseconds' THEN
            child_start_time := to_timestamp((v_start_string::double precision) / 1000);
        ELSIF v_epoch = 'nanoseconds' THEN
            child_start_time := to_timestamp((v_start_string::double precision) / 1000000000);
        END IF;
    ELSE
        RAISE EXCEPTION 'Unexpected code path in show_partition_info(). Please report this bug with the configuration that lead to it.';
    END IF;

    child_end_time := (child_start_time + v_partition_interval::interval);

    SELECT to_char(base_timestamp, datetime_string)
    INTO suffix
    FROM partman5.calculate_time_partition_info(v_partition_interval::interval, child_start_time);

ELSIF v_control_type = 'id' THEN

    IF v_exact_control_type IN ('int8', 'int4', 'int2') THEN
        child_start_id := trim(BOTH '''' FROM v_start_string)::bigint;
    ELSIF v_exact_control_type = 'numeric' THEN
        -- cast to numeric then trunc to get rid of decimal without rounding
        child_start_id := trunc(trim(BOTH '''' FROM v_start_string)::numeric)::bigint;
    END IF;

    child_end_id := (child_start_id + v_partition_interval::bigint) - 1;

ELSE
    RAISE EXCEPTION 'Invalid partition type encountered in show_partition_info()';
END IF;

RETURN;

END
$_$;


ALTER FUNCTION partman5.show_partition_info(p_child_table text, p_partition_interval text, p_parent_table text, OUT child_start_time timestamp with time zone, OUT child_end_time timestamp with time zone, OUT child_start_id bigint, OUT child_end_id bigint, OUT suffix text) OWNER TO api;

--
-- Name: show_partition_name(text, text); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.show_partition_name(p_parent_table text, p_value text, OUT partition_schema text, OUT partition_table text, OUT suffix_timestamp timestamp with time zone, OUT suffix_id bigint, OUT table_exists boolean) RETURNS record
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE

v_child_end_time                timestamptz;
v_child_exists                  text;
v_child_larger                  boolean := false;
v_child_smaller                 boolean := false;
v_child_start_time              timestamptz;
v_control                       text;
v_control_type                  text;
v_datetime_string               text;
v_epoch                         text;
v_given_timestamp               timestamptz;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_interval            text;
v_row                           record;
v_type                          text;

BEGIN
/*
 * Given a parent table and partition value, return the name of the child partition it would go in.
 * If using epoch time partitioning, give the text representation of the timestamp NOT the epoch integer value (use to_timestamp() to convert epoch values).
 * Also returns just the suffix value and true if the child table exists or false if it does not
 */

SELECT partition_type
    , control
    , partition_interval
    , datetime_string
    , epoch
INTO v_type
    , v_control
    , v_partition_interval
    , v_datetime_string
    , v_epoch
FROM partman5.part_config
WHERE parent_table = p_parent_table;

IF v_type IS NULL THEN
    RAISE EXCEPTION 'Parent table given is not managed by pg_partman (%)', p_parent_table;
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
IF v_parent_tablename IS NULL THEN
    RAISE EXCEPTION 'Parent table given does not exist (%)', p_parent_table;
END IF;

partition_schema := v_parent_schema;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

IF ( (v_control_type = 'time') OR (v_control_type = 'id' AND v_epoch <> 'none') ) THEN

    v_given_timestamp := p_value::timestamptz;
    FOR v_row IN
        SELECT partition_schemaname ||'.'|| partition_tablename AS child_table FROM partman5.show_partitions(p_parent_table, 'DESC')
    LOOP
        SELECT child_start_time INTO v_child_start_time
            FROM partman5.show_partition_info(v_row.child_table, v_partition_interval, p_parent_table);
        -- Don't use child_end_time from above function to avoid edge cases around user supplied timestamps
        v_child_end_time := v_child_start_time + v_partition_interval::interval;
        IF v_given_timestamp >= v_child_end_time THEN
            -- given value is higher than any existing child table. handled below.
            v_child_larger := true;
            EXIT;
        END IF;
        IF v_given_timestamp >= v_child_start_time THEN
            -- found target child table
            v_child_smaller := false;
            suffix_timestamp := v_child_start_time;
            EXIT;
        END IF;
        -- Should only get here if no matching child table was found. handled below.
        v_child_smaller := true;
    END LOOP;

    IF v_child_start_time IS NULL OR v_child_end_time IS NULL THEN
        -- This should never happen since there should never be a partition set without children.
        -- Handling just in case so issues can be reported with context
        RAISE EXCEPTION 'Unexpected code path encountered in show_partition_name(). Please report this issue to author with relevant partition config info.';
    END IF;

    IF v_child_larger THEN
        LOOP
            -- keep adding interval until found
            v_child_start_time := v_child_start_time + v_partition_interval::interval;
            v_child_end_time := v_child_end_time + v_partition_interval::interval;
            IF v_given_timestamp >= v_child_start_time AND v_given_timestamp < v_child_end_time THEN
                suffix_timestamp := v_child_start_time;
                EXIT;
            END IF;
        END LOOP;
    ELSIF v_child_smaller THEN
        LOOP
            -- keep subtracting interval until found
            v_child_start_time := v_child_start_time - v_partition_interval::interval;
            v_child_end_time := v_child_end_time - v_partition_interval::interval;
            IF v_given_timestamp >= v_child_start_time AND v_given_timestamp < v_child_end_time THEN
                suffix_timestamp := v_child_start_time;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    partition_table := partman5.check_name_length(v_parent_tablename, to_char(suffix_timestamp, v_datetime_string), TRUE);

ELSIF v_control_type = 'id' THEN
    suffix_id := (p_value::bigint - (p_value::bigint % v_partition_interval::bigint));
    partition_table := partman5.check_name_length(v_parent_tablename, suffix_id::text, TRUE);

ELSE
    RAISE EXCEPTION 'Unexpected code path encountered in show_partition_name(). No valid control type found. Please report this issue to author with relevant partition config info.';
END IF;

SELECT tablename INTO v_child_exists
FROM pg_catalog.pg_tables
WHERE schemaname = partition_schema::name
AND tablename = partition_table::name;

IF v_child_exists IS NOT NULL THEN
    table_exists := true;
ELSE
    table_exists := false;
END IF;

RETURN;

END
$$;


ALTER FUNCTION partman5.show_partition_name(p_parent_table text, p_value text, OUT partition_schema text, OUT partition_table text, OUT suffix_timestamp timestamp with time zone, OUT suffix_id bigint, OUT table_exists boolean) OWNER TO api;

--
-- Name: show_partitions(text, text, boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.show_partitions(p_parent_table text, p_order text DEFAULT 'ASC'::text, p_include_default boolean DEFAULT false) RETURNS TABLE(partition_schemaname text, partition_tablename text)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'partman5', 'pg_temp'
    AS $_$
DECLARE

v_control               text;
v_control_type          text;
v_exact_control_type    text;
v_datetime_string       text;
v_default_sql           text;
v_epoch                 text;
v_epoch_divisor         bigint;
v_parent_schema         text;
v_parent_tablename      text;
v_partition_type        text;
v_sql                   text;

BEGIN
/*
 * Function to list all child partitions in a set in logical order.
 * Default partition is not listed by default since that's the common usage internally
 * If p_include_default is set true, default is always listed first.
 */

IF upper(p_order) NOT IN ('ASC', 'DESC') THEN
    RAISE EXCEPTION 'p_order parameter must be one of the following values: ASC, DESC';
END IF;

SELECT partition_type
    , datetime_string
    , control
    , epoch
INTO v_partition_type
    , v_datetime_string
    , v_control
    , v_epoch
FROM partman5.part_config
WHERE parent_table = p_parent_table;

IF v_partition_type IS NULL THEN
    RAISE EXCEPTION 'Given parent table not managed by pg_partman: %', p_parent_table;
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;

IF v_parent_tablename IS NULL THEN
    RAISE EXCEPTION 'Given parent table not found in system catalogs: %', p_parent_table;
END IF;

SELECT general_type, exact_type INTO v_control_type, v_exact_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);

RAISE DEBUG 'show_partitions: v_parent_schema: %, v_parent_tablename: %, v_datetime_string: %, v_control_type: %, v_exact_control_type: %'
    , v_parent_schema
    , v_parent_tablename
    , v_datetime_string
    , v_control_type
    , v_exact_control_type;

v_sql := format('SELECT n.nspname::text AS partition_schemaname
        , c.relname::text AS partition_name
        FROM pg_catalog.pg_inherits h
        JOIN pg_catalog.pg_class c ON c.oid = h.inhrelid
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE h.inhparent = ''%I.%I''::regclass'
    , v_parent_schema
    , v_parent_tablename);

IF p_include_default THEN
    -- Return the default partition immediately as first item in list
    v_default_sql := v_sql || format('
        AND pg_get_expr(relpartbound, c.oid) = ''DEFAULT''');
    RAISE DEBUG 'show_partitions: v_default_sql: %', v_default_sql;
    RETURN QUERY EXECUTE v_default_sql;
END IF;

v_sql := v_sql || format('
    AND pg_get_expr(relpartbound, c.oid) != ''DEFAULT'' ');


IF v_control_type = 'time' THEN

    v_sql := v_sql || format('
        ORDER BY (regexp_match(pg_get_expr(c.relpartbound, c.oid, true), $REGEX$\(([^)]+)\) TO \(([^)]+)\)$REGEX$))[1]::text::timestamptz %s '
        , p_order);

ELSIF v_control_type = 'id' AND v_epoch <> 'none' THEN

    IF v_epoch = 'seconds' THEN
        v_epoch_divisor := 1;
    ELSIF v_epoch = 'milliseconds' THEN
        v_epoch_divisor := 1000;
    ELSIF v_epoch = 'nanoseconds' THEN
        v_epoch_divisor := 1000000000;
    END IF;

    -- Have to do a trim here because of inconsistency in quoting different integer types. Ex: bigint boundary values are quoted but int values are not
    v_sql := v_sql || format('
        ORDER BY to_timestamp(trim( BOTH $QUOTE$''$QUOTE$ from (regexp_match(pg_get_expr(c.relpartbound, c.oid, true), $REGEX$\(([^)]+)\) TO \(([^)]+)\)$REGEX$))[1]::text )::bigint /%s ) %s '
        , v_epoch_divisor
        , p_order);

ELSIF v_control_type = 'id' THEN

    IF v_partition_type = 'range' THEN
        -- Have to do a trim here because of inconsistency in quoting different integer types. Ex: bigint boundary values are quoted but int values are not
        v_sql := v_sql || format('
            ORDER BY trim( BOTH $QUOTE$''$QUOTE$ from (regexp_match(pg_get_expr(c.relpartbound, c.oid, true), $REGEX$\(([^)]+)\) TO \(([^)]+)\)$REGEX$))[1]::text )::%s %s '
            , v_exact_control_type, p_order);
    ELSIF v_partition_type = 'list' THEN
        v_sql := v_sql || format('
            ORDER BY trim((regexp_match(pg_get_expr(c.relpartbound, c.oid, true), $REGEX$FOR VALUES IN \(([^)])\)$REGEX$))[1])::%s %s '
            , v_exact_control_type , p_order);
    ELSE
        RAISE EXCEPTION 'show_partitions: Unsupported partition type found: %', v_partition_type;
    END IF;

ELSE
    RAISE EXCEPTION 'show_partitions: Unexpected code path in sort order determination. Please report the steps that lead to this error to extension maintainers.';
END IF;

RAISE DEBUG 'show_partitions: v_sql: %', v_sql;

RETURN QUERY EXECUTE v_sql;

END
$_$;


ALTER FUNCTION partman5.show_partitions(p_parent_table text, p_order text, p_include_default boolean) OWNER TO api;

--
-- Name: stop_sub_partition(text, boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.stop_sub_partition(p_parent_table text, p_jobmon boolean DEFAULT true) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE

v_job_id            bigint;
v_jobmon_schema     text;
v_step_id           bigint;

BEGIN
/*
 * Stop a given parent table from causing its children to be subpartitioned
 */

IF p_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    EXECUTE format('SELECT %I.add_job(''PARTMAN STOP SUBPARTITIONING'')', v_jobmon_schema) INTO v_job_id;
    EXECUTE format('SELECT %I.add_step(%s, ''Stopped subpartitioning for %s'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
END IF;

DELETE FROM partman5.part_config_sub WHERE sub_parent = p_parent_table;

IF v_jobmon_schema IS NOT NULL THEN
    EXECUTE format('SELECT %I.update_step(%s, %L, %L)', v_jobmon_schema, v_step_id, 'OK', 'Done');
    EXECUTE format('SELECT %I.close_job(%s)', v_jobmon_schema, v_job_id);
END IF;

RETURN true;

END
$$;


ALTER FUNCTION partman5.stop_sub_partition(p_parent_table text, p_jobmon boolean) OWNER TO api;

--
-- Name: undo_partition(text, text, integer, text, boolean, numeric, text[], boolean); Type: FUNCTION; Schema: partman5; Owner: api
--

CREATE FUNCTION partman5.undo_partition(p_parent_table text, p_target_table text, p_loop_count integer DEFAULT 1, p_batch_interval text DEFAULT NULL::text, p_keep_table boolean DEFAULT true, p_lock_wait numeric DEFAULT 0, p_ignored_columns text[] DEFAULT NULL::text[], p_drop_cascade boolean DEFAULT false, OUT partitions_undone integer, OUT rows_undone bigint) RETURNS record
    LANGUAGE plpgsql
    AS $_$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_adv_lock                      boolean;
v_batch_interval_id             bigint;
v_batch_interval_time           interval;
v_batch_loop_count              int := 0;
v_child_loop_total              bigint := 0;
v_child_table                   text;
v_column_list                   text;
v_control                       text;
v_control_type                  text;
v_child_min_id                  bigint;
v_child_min_time                timestamptz;
v_epoch                         text;
v_function_name                 text;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_job_id                        bigint;
v_inner_loop_count              int;
v_lock_iter                     int := 1;
v_lock_obtained                 boolean := FALSE;
v_new_search_path               text;
v_old_search_path               text;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_expression          text;
v_partition_interval            text;
v_row                           record;
v_rowcount                      bigint;
v_sql                           text;
v_step_id                       bigint;
v_sub_count                     int;
v_target_schema                 text;
v_target_tablename              text;
v_template_schema               text;
v_template_siblings             int;
v_template_table                text;
v_template_tablename            text;
v_total                         bigint := 0;
v_trig_name                     text;
v_undo_count                    int := 0;

BEGIN
/*
 * Moves data to new, target table since data cannot be moved elsewhere in the same partition set.
 * Leaves old parent table as is and does not change name of new table.
 */

v_adv_lock := pg_try_advisory_xact_lock(hashtext('pg_partman undo_partition'));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'undo_partition already running.';
    partitions_undone = -1;
    RETURN;
END IF;

IF p_parent_table = p_target_table THEN
    RAISE EXCEPTION 'Target table cannot be the same as the parent table';
END IF;

SELECT partition_interval::text
    , control
    , jobmon
    , epoch
    , template_table
INTO v_partition_interval
    , v_control
    , v_jobmon
    , v_epoch
    , v_template_table
FROM partman5.part_config
WHERE parent_table = p_parent_table;

IF v_control IS NULL THEN
    RAISE EXCEPTION 'No configuration found for pg_partman for given parent table: %', p_parent_table;
END IF;

IF p_target_table IS NULL THEN
    RAISE EXCEPTION 'The p_target_table option must be set when undoing a partitioned table';
END IF;

SELECT n.nspname, c.relname
INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;

IF v_parent_tablename IS NULL THEN
    RAISE EXCEPTION 'Given parent table not found in system catalogs: %', p_parent_table;
END IF;

SELECT general_type INTO v_control_type FROM partman5.check_control_type(v_parent_schema, v_parent_tablename, v_control);
IF v_control_type = 'time' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN
    IF p_batch_interval IS NULL THEN
        v_batch_interval_time := v_partition_interval::interval;
    ELSE
        v_batch_interval_time := p_batch_interval::interval;
    END IF;
ELSIF v_control_type = 'id' THEN
    IF p_batch_interval IS NULL THEN
        v_batch_interval_id := v_partition_interval::bigint;
    ELSE
        v_batch_interval_id := p_batch_interval::bigint;
    END IF;
ELSE
    RAISE EXCEPTION 'Data type of control column in given partition set must be either date/time or integer.';
END IF;

SELECT current_setting('search_path') INTO v_old_search_path;
IF length(v_old_search_path) > 0 THEN
   v_new_search_path := 'partman5,pg_temp,'||v_old_search_path;
ELSE
    v_new_search_path := 'partman5,pg_temp';
END IF;
IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM pg_catalog.pg_namespace n, pg_catalog.pg_extension e WHERE e.extname = 'pg_jobmon'::name AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        v_new_search_path := format('%s,%s',v_jobmon_schema, v_new_search_path);
    END IF;
END IF;
EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_new_search_path, 'false');

-- Check if any child tables are themselves partitioned or part of an inheritance tree. Prevent undo at this level if so.
-- Need to lock child tables at all levels before multi-level undo can be performed safely.
FOR v_row IN
    SELECT partition_schemaname, partition_tablename FROM partman5.show_partitions(p_parent_table)
LOOP
    SELECT count(*) INTO v_sub_count
    FROM pg_catalog.pg_inherits i
    JOIN pg_catalog.pg_class c ON i.inhparent = c.oid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_row.partition_tablename::name
    AND n.nspname = v_row.partition_schemaname::name;
    IF v_sub_count > 0 THEN
        RAISE EXCEPTION 'Child table for this parent has child table(s) itself (%). Run undo partitioning on this table to ensure all data is properly moved to target table', v_row.partition_schemaname||'.'||v_row.partition_tablename;
    END IF;
END LOOP;

SELECT n.nspname, c.relname
INTO v_target_schema, v_target_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_target_table, '.', 1)::name
AND c.relname = split_part(p_target_table, '.', 2)::name;

IF v_target_tablename IS NULL THEN
    RAISE EXCEPTION 'Given target table not found in system catalogs: %', p_target_table;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN UNDO PARTITIONING: %s', p_parent_table));
    v_step_id := add_step(v_job_id, format('Undoing partitioning for table %s', p_parent_table));
END IF;

v_partition_expression := CASE
    WHEN v_epoch = 'seconds' THEN format('to_timestamp(%I)', v_control)
    WHEN v_epoch = 'milliseconds' THEN format('to_timestamp((%I/1000)::float)', v_control)
    WHEN v_epoch = 'nanoseconds' THEN format('to_timestamp((%I/1000000000)::float)', v_control)
    ELSE format('%I', v_control)
END;

-- Stops new time partitions from being made as well as stopping child tables from being dropped if they were configured with a retention period.
UPDATE partman5.part_config SET undo_in_progress = true WHERE parent_table = p_parent_table;


IF v_jobmon_schema IS NOT NULL THEN
    IF (v_trig_name IS NOT NULL OR v_function_name IS NOT NULL) THEN
        PERFORM update_step(v_step_id, 'OK', 'Stopped partition creation process. Removed trigger & trigger function');
    ELSE
        PERFORM update_step(v_step_id, 'OK', 'Stopped partition creation process.');
    END IF;
END IF;

-- Generate column list to use in SELECT/INSERT statements below. Allows for exclusion of GENERATED (or any other desired) columns.
SELECT string_agg(quote_ident(attname), ',')
INTO v_column_list
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = v_target_schema
AND c.relname = v_target_tablename
AND a.attnum > 0
AND a.attisdropped = false
AND attname <> ALL(COALESCE(p_ignored_columns, ARRAY[]::text[]));

<<outer_child_loop>>
LOOP
    -- Get ordered list of child table in set. Store in variable one at a time per loop until none are left or batch count is reached.
    -- This easily allows it to loop over same child table until empty or move onto next child table after it's dropped
    -- Include the default table to ensure all data there is removed as well
    SELECT partition_tablename INTO v_child_table FROM partman5.show_partitions(p_parent_table, 'ASC', p_include_default := TRUE) LIMIT 1;

    EXIT outer_child_loop WHEN v_child_table IS NULL;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Removing child partition: %s.%s', v_parent_schema, v_child_table));
    END IF;

    IF v_control_type = 'time' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN
        EXECUTE format('SELECT min(%s) FROM %I.%I', v_partition_expression, v_parent_schema, v_child_table) INTO v_child_min_time;
    ELSIF v_control_type = 'id' THEN
        EXECUTE format('SELECT min(%s) FROM %I.%I', v_partition_expression, v_parent_schema, v_child_table) INTO v_child_min_id;
    END IF;

    IF v_child_min_time IS NULL AND v_child_min_id IS NULL THEN
        -- No rows left in this child table. Remove from partition set.

        -- lockwait timeout for table drop
        IF p_lock_wait > 0  THEN
            v_lock_iter := 0;
            WHILE v_lock_iter <= 5 LOOP
                v_lock_iter := v_lock_iter + 1;
                BEGIN
                    EXECUTE format('LOCK TABLE ONLY %I.%I IN ACCESS EXCLUSIVE MODE NOWAIT', v_parent_schema, v_child_table);
                    v_lock_obtained := TRUE;
                EXCEPTION
                    WHEN lock_not_available THEN
                        PERFORM pg_sleep( p_lock_wait / 5.0 );
                        CONTINUE;
                END;
                EXIT WHEN v_lock_obtained;
            END LOOP;
            IF NOT v_lock_obtained THEN
                RAISE NOTICE 'Unable to obtain lock on child table for removal from partition set';
                partitions_undone = -1;
                RETURN;
            END IF;
        END IF; -- END p_lock_wait IF
        v_lock_obtained := FALSE; -- reset for reuse later

        v_sql := format('ALTER TABLE %I.%I DETACH PARTITION %I.%I'
                        , v_parent_schema
                        , v_parent_tablename
                        , v_parent_schema
                        , v_child_table);
        EXECUTE v_sql;

        IF p_keep_table = false THEN
            v_sql := 'DROP TABLE %I.%I';
            IF p_drop_cascade THEN
                v_sql := v_sql || ' CASCADE';
            END IF;
            EXECUTE format(v_sql, v_parent_schema, v_child_table);
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', format('Child table DROPPED. Moved %s rows to target table', v_child_loop_total));
            END IF;
        ELSE
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', format('Child table DETACHED/UNINHERITED from parent, not DROPPED. Moved %s rows to target table', v_child_loop_total));
            END IF;
        END IF;

        v_undo_count := v_undo_count + 1;
        EXIT outer_child_loop WHEN v_batch_loop_count >= p_loop_count; -- Exit outer FOR loop if p_loop_count is reached
        CONTINUE outer_child_loop; -- skip data moving steps below
    END IF;
    v_inner_loop_count := 1;
    v_child_loop_total := 0;
    <<inner_child_loop>>
    LOOP
        IF v_control_type = 'time' OR (v_control_type = 'id' AND v_epoch <> 'none') THEN
            -- do some locking with timeout, if required
            IF p_lock_wait > 0  THEN
                v_lock_iter := 0;
                WHILE v_lock_iter <= 5 LOOP
                    v_lock_iter := v_lock_iter + 1;
                    BEGIN
                        EXECUTE format('SELECT * FROM %I.%I WHERE %I <= %L FOR UPDATE NOWAIT'
                            , v_parent_schema
                            , v_child_table
                            , v_control
                            , v_child_min_time + (v_batch_interval_time * v_inner_loop_count));
                       v_lock_obtained := TRUE;
                    EXCEPTION
                        WHEN lock_not_available THEN
                            PERFORM pg_sleep( p_lock_wait / 5.0 );
                            CONTINUE;
                    END;
                    EXIT WHEN v_lock_obtained;
                END LOOP;
                IF NOT v_lock_obtained THEN
                    RAISE NOTICE 'Unable to obtain lock on batch of rows to move';
                    partitions_undone = -1;
                    RETURN;
                END IF;
            END IF;

            -- Get everything from the current child minimum up to the multiples of the given interval
            EXECUTE format('WITH move_data AS (
                                    DELETE FROM %I.%I WHERE %s <= %L RETURNING %s )
                                  INSERT INTO %I.%I (%5$s) SELECT %5$s FROM move_data'
                , v_parent_schema
                , v_child_table
                , v_partition_expression
                , v_child_min_time + (v_batch_interval_time * v_inner_loop_count)
                , v_column_list
                , v_target_schema
                , v_target_tablename);
            GET DIAGNOSTICS v_rowcount = ROW_COUNT;
            v_total := v_total + v_rowcount;
            v_child_loop_total := v_child_loop_total + v_rowcount;
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', format('Moved %s rows to target table.', v_child_loop_total));
            END IF;
            EXIT inner_child_loop WHEN v_rowcount = 0; -- exit before loop incr if table is empty
            v_inner_loop_count := v_inner_loop_count + 1;
            v_batch_loop_count := v_batch_loop_count + 1;

            -- Check again if table is empty and go to outer loop again to drop it if so
            EXECUTE format('SELECT min(%s) FROM %I.%I', v_partition_expression, v_parent_schema, v_child_table) INTO v_child_min_time;
            CONTINUE outer_child_loop WHEN v_child_min_time IS NULL;

        ELSIF v_control_type = 'id' THEN

            IF p_lock_wait > 0  THEN
                v_lock_iter := 0;
                WHILE v_lock_iter <= 5 LOOP
                    v_lock_iter := v_lock_iter + 1;
                    BEGIN
                        EXECUTE format('SELECT * FROM %I.%I WHERE %I <= %L FOR UPDATE NOWAIT'
                            , v_parent_schema
                            , v_child_table
                            , v_control
                            , v_child_min_id + (v_batch_interval_id * v_inner_loop_count));
                       v_lock_obtained := TRUE;
                    EXCEPTION
                        WHEN lock_not_available THEN
                            PERFORM pg_sleep( p_lock_wait / 5.0 );
                            CONTINUE;
                    END;
                    EXIT WHEN v_lock_obtained;
                END LOOP;
                IF NOT v_lock_obtained THEN
                   RAISE NOTICE 'Unable to obtain lock on batch of rows to move';
                   partitions_undone = -1;
                   RETURN;
                END IF;
            END IF;

            -- Get everything from the current child minimum up to the multiples of the given interval
            EXECUTE format('WITH move_data AS (
                                    DELETE FROM %I.%I WHERE %s <= %L RETURNING %s)
                                  INSERT INTO %I.%I (%5$s) SELECT %5$s FROM move_data'
                , v_parent_schema
                , v_child_table
                , v_partition_expression
                , v_child_min_id + (v_batch_interval_id * v_inner_loop_count)
                , v_column_list
                , v_target_schema
                , v_target_tablename);
            GET DIAGNOSTICS v_rowcount = ROW_COUNT;
            v_total := v_total + v_rowcount;
            v_child_loop_total := v_child_loop_total + v_rowcount;
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', format('Moved %s rows to target table.', v_child_loop_total));
            END IF;
            EXIT inner_child_loop WHEN v_rowcount = 0; -- exit before loop incr if table is empty
            v_inner_loop_count := v_inner_loop_count + 1;
            v_batch_loop_count := v_batch_loop_count + 1;

            -- Check again if table is empty and go to outer loop again to drop it if so
            EXECUTE format('SELECT min(%s) FROM %I.%I', v_partition_expression, v_parent_schema, v_child_table) INTO v_child_min_id;
            CONTINUE outer_child_loop WHEN v_child_min_id IS NULL;

        END IF; -- end v_control_type check

        EXIT outer_child_loop WHEN v_batch_loop_count >= p_loop_count; -- Exit outer FOR loop if p_loop_count is reached

    END LOOP inner_child_loop;
END LOOP outer_child_loop;

SELECT partition_tablename INTO v_child_table FROM partman5.show_partitions(p_parent_table, 'ASC', TRUE) LIMIT 1;

IF v_child_table IS NULL THEN
    DELETE FROM partman5.part_config WHERE parent_table = p_parent_table;

    -- Check if any other config entries still have this template table and don't remove if so
    -- Allows other sibling/parent tables to still keep using in case entire partition set isn't being undone
    SELECT count(*) INTO v_template_siblings FROM partman5.part_config WHERE template_table = v_template_table;

    SELECT n.nspname, c.relname
    INTO v_template_schema, v_template_tablename
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = split_part(v_template_table, '.', 1)::name
    AND c.relname = split_part(v_template_table, '.', 2)::name;

    IF v_template_siblings = 0 AND v_template_tablename IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I.%I', v_template_schema, v_template_tablename);
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Removing config from pg_partman');
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

RAISE NOTICE 'Moved % row(s) to the target table. Removed % partitions.', v_total, v_undo_count;
IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Final stats');
    PERFORM update_step(v_step_id, 'OK', format('Moved %s row(s) to the target table. Removed %s partitions.', v_total, v_undo_count));
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
END IF;

EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');

partitions_undone := v_undo_count;
rows_undone := v_total;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = PG_EXCEPTION_CONTEXT,
                                ex_detail = PG_EXCEPTION_DETAIL,
                                ex_hint = PG_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN UNDO PARTITIONING: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$_$;


ALTER FUNCTION partman5.undo_partition(p_parent_table text, p_target_table text, p_loop_count integer, p_batch_interval text, p_keep_table boolean, p_lock_wait numeric, p_ignored_columns text[], p_drop_cascade boolean, OUT partitions_undone integer, OUT rows_undone bigint) OWNER TO api;

--
-- Name: undo_partition_proc(text, text, integer, text, boolean, integer, integer, integer, text[], boolean, boolean); Type: PROCEDURE; Schema: partman5; Owner: api
--

CREATE PROCEDURE partman5.undo_partition_proc(IN p_parent_table text, IN p_target_table text DEFAULT NULL::text, IN p_loop_count integer DEFAULT NULL::integer, IN p_interval text DEFAULT NULL::text, IN p_keep_table boolean DEFAULT true, IN p_lock_wait integer DEFAULT 0, IN p_lock_wait_tries integer DEFAULT 10, IN p_wait integer DEFAULT 1, IN p_ignored_columns text[] DEFAULT NULL::text[], IN p_drop_cascade boolean DEFAULT false, IN p_quiet boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $$
DECLARE

v_adv_lock                  boolean;
v_is_autovac_off            boolean := false;
v_lockwait_count            int := 0;
v_loop_count               int := 0;
v_parent_schema             text;
v_parent_tablename          text;
v_partition_type            text;
v_partitions_undone         int;
v_partitions_undone_total   int := 0;
v_rows_undone               bigint;
v_target_tablename          text;
v_sql                       text;
v_total                     bigint := 0;

BEGIN

v_adv_lock := pg_try_advisory_xact_lock(hashtext('pg_partman undo_partition_proc'), hashtext(p_parent_table));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'Partman undo_partition_proc already running for given parent table: %.', p_parent_table;
    RETURN;
END IF;

SELECT partition_type
INTO v_partition_type
FROM partman5.part_config
WHERE parent_table = p_parent_table;
IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: No entry in part_config found for given table: %', p_parent_table;
END IF;

IF p_target_table IS NULL THEN
    RAISE EXCEPTION 'The p_target_table option must be set when undoing a partitioned table';
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Unable to find given parent table in system catalogs. Ensure it is schema qualified: %', p_parent_table;
    END IF;

IF p_target_table IS NOT NULL THEN
    SELECT c.relname INTO v_target_tablename
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = split_part(p_target_table, '.', 1)::name
    AND c.relname = split_part(p_target_table, '.', 2)::name;
        IF v_target_tablename IS NULL THEN
            RAISE EXCEPTION 'Unable to find given target table in system catalogs. Ensure it is schema qualified: %', p_target_table;
        END IF;
END IF;

/*
-- Currently no way to catch exception and reset autovac settings back to normal. Until I can do that, leaving this feature out for now
-- Leaving the functions to turn off/reset in to let people do that manually if desired
IF p_autovacuum_on = false THEN         -- Add this parameter back to definition when this is working
    -- Turn off autovac for parent, source table if set, and all child tables
    v_is_autovac_off := partman5.autovacuum_off(v_parent_schema, v_parent_tablename, v_source_schema, v_source_tablename);
    COMMIT;
END IF;
*/

v_sql := format('SELECT partitions_undone, rows_undone FROM %s.undo_partition (%L, p_keep_table := %L, p_lock_wait := %L'
        , 'partman5'
        , p_parent_table
        , p_keep_table
        , p_lock_wait);
IF p_interval IS NOT NULL THEN
    v_sql := v_sql || format(', p_batch_interval := %L', p_interval);
END IF;
IF p_target_table IS NOT NULL THEN
    v_sql := v_sql || format(', p_target_table := %L', p_target_table);
END IF;
IF p_ignored_columns IS NOT NULL THEN
    v_sql := v_sql || format(', p_ignored_columns := %L', p_ignored_columns);
END IF;
IF p_drop_cascade IS NOT NULL THEN
    v_sql := v_sql || format(', p_drop_cascade := %L', p_drop_cascade);
END IF;
v_sql := v_sql || ')';
RAISE DEBUG 'partition_data sql: %', v_sql;

LOOP
    EXECUTE v_sql INTO v_partitions_undone, v_rows_undone;
    -- If lock wait timeout, do not increment the counter
    IF v_rows_undone != -1 THEN
        v_loop_count := v_loop_count + 1;
        v_partitions_undone_total := v_partitions_undone_total + v_partitions_undone;
        v_total := v_total + v_rows_undone;
        v_lockwait_count := 0;
    ELSE
        v_lockwait_count := v_lockwait_count + 1;
        IF v_lockwait_count > p_lock_wait_tries THEN
            RAISE EXCEPTION 'Quitting due to inability to get lock on next batch of rows to be moved';
        END IF;
    END IF;
    IF p_quiet = false THEN
        IF v_rows_undone > 0 THEN
            RAISE NOTICE 'Batch: %, Partitions undone this batch: %, Rows undone this batch: %', v_loop_count, v_partitions_undone, v_rows_undone;
        ELSIF v_rows_undone = -1 THEN
            RAISE NOTICE 'Unable to obtain row locks for data to be moved. Trying again...';
        END IF;
    END IF;
    COMMIT;

    -- If no rows left or given loop argument limit is reached
    IF v_rows_undone = 0 OR (p_loop_count > 0 AND v_loop_count >= p_loop_count) THEN
        EXIT;
    END IF;

    -- undo_partition functions will remove config entry once last child is dropped
    -- Added here to handle edge-case
    SELECT partition_type
    INTO v_partition_type
    FROM partman5.part_config
    WHERE parent_table = p_parent_table;
    IF NOT FOUND THEN
        EXIT;
    END IF;

    PERFORM pg_sleep(p_wait);

    RAISE DEBUG 'v_partitions_undone: %, v_rows_undone: %, v_loop_count: %, v_total: %, v_lockwait_count: %, p_wait: %', v_partitions_undone, p_wait, v_rows_undone, v_loop_count, v_total, v_lockwait_count;
END LOOP;

/*
IF v_is_autovac_off = true THEN
    -- Reset autovac back to default if it was turned off by this procedure
    PERFORM partman5.autovacuum_reset(v_parent_schema, v_parent_tablename, v_source_schema, v_source_tablename);
    COMMIT;
END IF;
*/

IF p_quiet = false THEN
    RAISE NOTICE 'Total partitions undone: %, Total rows moved: %', v_partitions_undone_total, v_total;
END IF;
RAISE NOTICE 'Ensure to VACUUM ANALYZE the old parent & target table after undo has finished';

END
$$;


ALTER PROCEDURE partman5.undo_partition_proc(IN p_parent_table text, IN p_target_table text, IN p_loop_count integer, IN p_interval text, IN p_keep_table boolean, IN p_lock_wait integer, IN p_lock_wait_tries integer, IN p_wait integer, IN p_ignored_columns text[], IN p_drop_cascade boolean, IN p_quiet boolean) OWNER TO api;

--
-- Name: create_queue(text, text, text, text); Type: FUNCTION; Schema: queue; Owner: api
--

CREATE FUNCTION queue.create_queue(p_schema_name text, p_table_name text, p_queue_schema_name text DEFAULT 'queue'::text, p_queue_table_name text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql
    AS $$
declare
  v_queue_table_name text;
  v_source_name text;
  v_procedure_name text;
  v_trigger_name text;
  v_sql text;
begin
  v_queue_table_name = p_queue_schema_name || '.' || coalesce(p_queue_table_name, p_table_name);
  v_source_name = p_schema_name || '.' || p_table_name;

  v_sql = 'create table ' || v_queue_table_name || '(journal_id bigint primary key, created_at timestamptz default now() not null, processed_at timestamptz, error text)';
  execute v_sql;

  v_sql = 'create index on ' || v_queue_table_name || '(journal_id) where processed_at is null';
  execute v_sql;


  perform partman.create_parent(v_queue_table_name, 'created_at', 'time', 'daily');
  update partman.part_config
     set retention = '1 week',
         retention_keep_table = false,
         retention_keep_index = false
   where parent_table in (v_queue_table_name);

  v_procedure_name = p_queue_schema_name || '.' || p_table_name || '_queue_insert';
  v_trigger_name = p_table_name || '_queue_insert_trigger';

  v_sql = 'create or replace function ' || v_procedure_name || '() returns trigger language plpgsql as ''';
  v_sql := v_sql || ' begin ';
  v_sql := v_sql || '  insert into ' || v_queue_table_name || ' (journal_id) values (new.journal_id);';
  v_sql := v_sql || ' return new; end; ''';
  execute v_sql;

  -- create the trigger
  v_sql = 'drop trigger if exists ' || v_trigger_name || ' on ' || v_source_name || '; ' ||
          'create trigger ' || v_trigger_name || ' after insert on ' || v_source_name ||
          ' for each row execute procedure ' || v_procedure_name || '()';

  execute v_sql;


  v_procedure_name = p_queue_schema_name || '.' || p_table_name || '_queue_update';
  v_trigger_name = p_table_name || '_queue_update_trigger';

  v_sql = 'create or replace function ' || v_procedure_name || '() returns trigger language plpgsql as ''';
  v_sql := v_sql || ' begin ';
  v_sql := v_sql || '  if new.journal_id != old.journal_id then ';
  v_sql := v_sql || '    raise ''''The table ' || v_source_name || ' has a queue table - updated to journal_id are not supported'''';';
  v_sql := v_sql || '  end if;';
  v_sql := v_sql || '  insert into ' || v_queue_table_name || ' (journal_id) values (new.journal_id);';
  v_sql := v_sql || ' return new; end; ''';
  execute v_sql;

  -- create the trigger
  v_sql = 'drop trigger if exists ' || v_trigger_name || ' on ' || v_source_name || '; ' ||
          'create trigger ' || v_trigger_name || ' after update on ' || v_source_name ||
          ' for each row execute procedure ' || v_procedure_name || '()';

  execute v_sql;


  v_procedure_name = p_queue_schema_name || '.' || p_table_name || '_queue_delete';
  v_trigger_name = p_table_name || '_queue_delete_trigger';

  v_sql = 'create or replace function ' || v_procedure_name || '() returns trigger language plpgsql as ''';
  v_sql := v_sql || ' begin ';
  v_sql := v_sql || '  insert into ' || v_queue_table_name || ' (journal_id) values (old.journal_id);';
  v_sql := v_sql || ' return old; end; ''';
  execute v_sql;

  -- create the trigger
  v_sql = 'drop trigger if exists ' || v_trigger_name || ' on ' || v_source_name || '; ' ||
          'create trigger ' || v_trigger_name || ' after delete on ' || v_source_name ||
          ' for each row execute procedure ' || v_procedure_name || '()';

  execute v_sql;

  return v_queue_table_name;
end;
$$;


ALTER FUNCTION queue.create_queue(p_schema_name text, p_table_name text, p_queue_schema_name text, p_queue_table_name text) OWNER TO api;

--
-- Name: create_basic_audit_data(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_basic_audit_data(p_schema_name character varying, p_table_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform schema_evolution_manager.create_basic_created_audit_data(p_schema_name, p_table_name);
  perform schema_evolution_manager.create_basic_updated_audit_data(p_schema_name, p_table_name);
  perform schema_evolution_manager.create_basic_deleted_audit_data(p_schema_name, p_table_name);
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_basic_audit_data(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_basic_created_audit_data(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_basic_created_audit_data(p_schema_name character varying, p_table_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add created_by_guid uuid not null';
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add created_at timestamp with time zone default now() not null';
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_basic_created_audit_data(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_basic_deleted_audit_data(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_basic_deleted_audit_data(p_schema_name character varying, p_table_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add deleted_by_guid uuid';
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add deleted_at timestamp with time zone';
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add constraint ' || p_table_name || '_deleted_ck ' ||
          'check ( (deleted_at is null and deleted_by_guid is null) OR (deleted_at is not null and deleted_by_guid is not null) )';
  perform schema_evolution_manager.create_prevent_immediate_delete_trigger(p_schema_name, p_table_name);
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_basic_deleted_audit_data(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_basic_updated_audit_data(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_basic_updated_audit_data(p_schema_name character varying, p_table_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add updated_by_guid uuid not null';
  execute 'alter table ' || p_schema_name || '.' || p_table_name || ' add updated_at timestamp with time zone default now() not null';
  perform schema_evolution_manager.create_updated_at_trigger(p_schema_name, p_table_name);
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_basic_updated_audit_data(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_prevent_delete_trigger(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_prevent_delete_trigger(p_schema_name character varying, p_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_name varchar;
begin
  v_name = p_table_name || '_prevent_delete_trigger';
  execute 'create trigger ' || v_name || ' after delete on ' || p_schema_name || '.' || p_table_name || ' for each row execute procedure schema_evolution_manager.prevent_delete()';
  return v_name;
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_prevent_delete_trigger(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_prevent_immediate_delete_trigger(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_prevent_immediate_delete_trigger(p_schema_name character varying, p_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_name varchar;
begin
  v_name = p_table_name || '_prevent_immediate_delete_trigger';
  execute 'create trigger ' || v_name || ' before delete on ' || p_schema_name || '.' || p_table_name || ' for each row execute procedure schema_evolution_manager.prevent_immediate_delete()';
  return v_name;
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_prevent_immediate_delete_trigger(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_prevent_update_trigger(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_prevent_update_trigger(p_schema_name character varying, p_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_name varchar;
begin
  v_name = p_table_name || '_prevent_update_trigger';
  execute 'create trigger ' || v_name || ' after update on ' || p_schema_name || '.' || p_table_name || ' for each row execute procedure schema_evolution_manager.prevent_update()';
  return v_name;
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_prevent_update_trigger(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: create_updated_at_trigger(character varying, character varying); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.create_updated_at_trigger(p_schema_name character varying, p_table_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
declare
  v_name varchar;
begin
  v_name = p_table_name || '_updated_at_trigger';
  execute 'drop trigger if exists ' || v_name || ' on ' || p_schema_name || '.' || p_table_name;
  execute 'create trigger ' || v_name || ' before update on ' || p_schema_name || '.' || p_table_name || ' for each row execute procedure schema_evolution_manager.set_updated_at_trigger_function()';
  return v_name;
end;
$$;


ALTER FUNCTION schema_evolution_manager.create_updated_at_trigger(p_schema_name character varying, p_table_name character varying) OWNER TO api;

--
-- Name: prevent_delete(); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.prevent_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  raise exception 'Physical deletes are not allowed on this table';
end;
$$;


ALTER FUNCTION schema_evolution_manager.prevent_delete() OWNER TO api;

--
-- Name: prevent_immediate_delete(); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.prevent_immediate_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if old.deleted_at is null then
    raise exception 'You must set the deleted_at column for this table';
  end if;

  if old.deleted_at > now() - interval '1 months' then
    raise exception 'Physical deletes on this table can occur only after 1 month of deleting the records';
  end if;

  return old;
end;
$$;


ALTER FUNCTION schema_evolution_manager.prevent_immediate_delete() OWNER TO api;

--
-- Name: prevent_update(); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.prevent_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  raise exception 'Physical updates are not allowed on this table';
end;
$$;


ALTER FUNCTION schema_evolution_manager.prevent_update() OWNER TO api;

--
-- Name: set_updated_at_trigger_function(); Type: FUNCTION; Schema: schema_evolution_manager; Owner: api
--

CREATE FUNCTION schema_evolution_manager.set_updated_at_trigger_function() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if (new.updated_at = old.updated_at) then
    new.updated_at = timezone('utc', now())::timestamptz;
  end if;
  return new;
end;
$$;


ALTER FUNCTION schema_evolution_manager.set_updated_at_trigger_function() OWNER TO api;

--
-- Name: delete_by_id(text, text, text); Type: FUNCTION; Schema: util; Owner: api
--

CREATE FUNCTION util.delete_by_id(p_user_id text, p_table_name text, p_id text) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  execute 'set journal.deleted_by_user_id = ''' || p_user_id || '''';
  execute 'delete from ' || p_table_name || ' where id = ''' || p_id || '''';
end;
$$;


ALTER FUNCTION util.delete_by_id(p_user_id text, p_table_name text, p_id text) OWNER TO api;

--
-- Name: lower_non_empty_trimmed_string(text); Type: FUNCTION; Schema: util; Owner: api
--

CREATE FUNCTION util.lower_non_empty_trimmed_string(p_value text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
  begin
    if (util.non_empty_trimmed_string(p_value) and lower(p_value) = p_value) then
      return true;
    else
      return false;
    end if;
  end
$$;


ALTER FUNCTION util.lower_non_empty_trimmed_string(p_value text) OWNER TO api;

--
-- Name: non_empty_trimmed_string(text); Type: FUNCTION; Schema: util; Owner: api
--

CREATE FUNCTION util.non_empty_trimmed_string(p_value text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
  begin
    if p_value is null or trim(p_value) = '' or trim(p_value) != p_value then
      return false;
    else
      return true;
    end if;
  end
$$;


ALTER FUNCTION util.non_empty_trimmed_string(p_value text) OWNER TO api;

--
-- Name: null_or_lower_non_empty_trimmed_string(text); Type: FUNCTION; Schema: util; Owner: api
--

CREATE FUNCTION util.null_or_lower_non_empty_trimmed_string(p_value text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
  begin
    if p_value is null then
      return true;
    else
      if lower(trim(p_value)) = p_value and p_value != '' then
        return true;
      else
        return false;
      end if;
    end if;
  end
$$;


ALTER FUNCTION util.null_or_lower_non_empty_trimmed_string(p_value text) OWNER TO api;

--
-- Name: null_or_non_empty_trimmed_string(text); Type: FUNCTION; Schema: util; Owner: api
--

CREATE FUNCTION util.null_or_non_empty_trimmed_string(p_value text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
  begin
    if p_value is null then
      return true;
    else
      if trim(p_value) = p_value and p_value != '' then
        return true;
      else
        return false;
      end if;
    end if;
  end
$$;


ALTER FUNCTION util.null_or_non_empty_trimmed_string(p_value text) OWNER TO api;

--
-- Name: get_blockers(integer[]); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_blockers(integer[]) RETURNS TABLE(c1 integer, c2 bigint)
    LANGUAGE sql SECURITY DEFINER
    AS $_$
  SELECT l2.pid, COUNT(DISTINCT l.pid)
    FROM pg_locks AS l
    JOIN pg_stat_activity AS a ON a.pid<>l.pid AND NOT a.wait_event_type IS NOT NULL AND a.xact_start IS NOT NULL
    JOIN pg_locks AS l2 ON l2.pid=a.pid AND l2.locktype=l.locktype AND l2.granted AND
      l2.relation IS NOT DISTINCT FROM l.relation AND
      l2.database IS NOT DISTINCT FROM l.database AND
      l2.transactionid IS NOT DISTINCT FROM l.transactionid AND
      l2.virtualxid IS NOT DISTINCT FROM l.virtualxid AND
      l2.page IS NOT DISTINCT FROM l.page AND
      l2.classid IS NOT DISTINCT FROM l.classid AND
      l2.objid IS NOT DISTINCT FROM l.objid AND
      l2.objsubid IS NOT DISTINCT FROM l.objsubid
    WHERE NOT l.granted AND l.locktype IN ('advisory','object','relation','transactionid') AND l.pid=ANY($1)
    GROUP BY l2.pid;
$_$;



--
-- Name: get_dbsizes(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_dbsizes() RETURNS TABLE(c1 name, c2 bigint)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT datname, pg_database_size(datname) FROM pg_database WHERE datname <> 'rdsadmin';
$$;



--
-- Name: get_func_version(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_func_version() RETURNS text
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT 'PG96-20170918'::text;
$$;



--
-- Name: get_indexsizes(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_indexsizes() RETURNS TABLE(c1 name, c2 bigint)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT indexrelname, pg_relation_size(indexrelid) AS index_size
  FROM pg_stat_user_indexes;
$$;



--
-- Name: get_lockmetrics(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_lockmetrics() RETURNS TABLE(c1 text, c2 boolean, c3 bigint, c4 double precision)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT locktype, granted, COUNT(*) AS cnt,
    SUM(COALESCE(GREATEST(EXTRACT(epoch FROM (now()-a.query_start))*1000000,0),0)) AS tw
  FROM pg_locks AS l
  JOIN pg_stat_activity AS a ON l.pid = a.pid
  GROUP BY locktype, granted;
$$;



--
-- Name: get_processlist(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_processlist() RETURNS TABLE(c1 text, c2 inet, c3 integer, c4 timestamp with time zone, c5 text, c6 timestamp with time zone, c7 text, c8 timestamp with time zone, c9 name, c10 text, c11 timestamp with time zone, c12 integer)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT application_name, client_addr, client_port, now() AS now, query,
    query_start, state, state_change, usename, CONCAT(wait_event_type,'_',wait_event) AS waiting, xact_start, pid
  FROM pg_stat_activity;
$$;



--
-- Name: get_schemasizes(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_schemasizes() RETURNS TABLE(c1 name, c2 numeric, c3 numeric, c4 numeric)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT pg_namespace.nspname, SUM(pg_table_size(relid)),
    SUM(pg_indexes_size(relid)), SUM(pg_total_relation_size(relid))
  FROM pg_statio_user_tables
  JOIN pg_namespace ON pg_statio_user_tables.schemaname = pg_namespace.nspname
  GROUP BY pg_namespace.nspname;
$$;



--
-- Name: get_stat_activity(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_stat_activity() RETURNS TABLE(c1 name, c2 name, c3 double precision, c4 double precision, c5 text, c6 text, c7 text, c8 integer, c9 inet, c10 integer)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT datname, usename, extract(epoch from query_start at time zone 'UTC') AS query_start,
      1000000000*extract(epoch from (state_change - query_start)), query, state, application_name,
      pid, client_addr, client_port
      FROM pg_stat_activity
      WHERE state_change >= now()-'1 second'::interval AND query_start IS NOT NULL;
$$;



--
-- Name: get_stat_query(text); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_stat_query(text, OUT c1 text) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    AS $_$
  SELECT query FROM pg_stat_statements WHERE MD5(query) = $1 LIMIT 1;
$_$;



--
-- Name: get_stat_statements(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_stat_statements() RETURNS TABLE(c1 text, c2 bigint, c3 double precision, c4 bigint, c5 bigint, c6 bigint, c7 bigint, c8 bigint, c9 bigint, c10 bigint, c11 bigint, c12 bigint, c13 bigint, c14 bigint, c15 double precision, c16 double precision, c17 oid, c18 oid)
    LANGUAGE sql SECURITY DEFINER
    AS $$
SELECT MD5(query), calls, 1000 * total_time, rows,
    shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
    local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written,
    temp_blks_read, temp_blks_written,
    1000 * blk_read_time, 1000 * blk_write_time, dbid, userid
    FROM pg_stat_statements
    WHERE query IS NOT NULL AND queryid IS NOT NULL;
$$;



--
-- Name: get_stat_statements_grouped(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_stat_statements_grouped() RETURNS TABLE(c1 text, c2 numeric, c3 double precision, c4 numeric, c5 numeric, c6 numeric, c7 numeric, c8 numeric, c9 numeric, c10 numeric, c11 numeric, c12 numeric, c13 numeric, c14 numeric, c15 double precision, c16 double precision, c17 oid, c18 oid)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT MD5(query), SUM(calls), 1000 * SUM(total_time), SUM(rows),
      SUM(shared_blks_hit), SUM(shared_blks_read), SUM(shared_blks_dirtied), SUM(shared_blks_written),
      SUM(local_blks_hit), SUM(local_blks_read), SUM(local_blks_dirtied), SUM(local_blks_written),
      SUM(temp_blks_read), SUM(temp_blks_written),
      1000 * SUM(blk_read_time), 1000 * SUM(blk_write_time), dbid, userid
      FROM pg_stat_statements
      WHERE query IS NOT NULL AND queryid IS NOT NULL
      GROUP BY MD5(query), dbid, userid;
$$;



--
-- Name: get_tablesizes(); Type: FUNCTION; Schema: vividcortex; Owner: root
--

CREATE FUNCTION vividcortex.get_tablesizes() RETURNS TABLE(c1 name, c2 bigint, c3 bigint, c4 bigint)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT relname, pg_table_size(relid), pg_indexes_size(relid),
    pg_total_relation_size(relid)
  FROM pg_statio_user_tables;
$$;



SET default_tablespace = '';

--
-- Name: binaries; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.binaries OWNER TO api;

SET default_table_access_method = heap;

--
-- Name: binaries_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_default (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.binaries_default OWNER TO api;

--
-- Name: TABLE binaries_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.binaries_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.binaries';


--
-- Name: binaries_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.binaries_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.binaries_journal_id_seq OWNER TO api;

--
-- Name: binaries_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.binaries_journal_id_seq OWNED BY journal.binaries_default.journal_id;


--
-- Name: binaries_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240101 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.binaries_p20240101 OWNER TO api;

--
-- Name: binaries_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240201 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.binaries_p20240201 OWNER TO api;

--
-- Name: binaries_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240301 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binaries_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binaries_p20240301 OWNER TO api;

--
-- Name: binaries_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240401 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binaries_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binaries_p20240401 OWNER TO api;

--
-- Name: binaries_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240501 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binaries_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binaries_p20240501 OWNER TO api;

--
-- Name: binaries_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240601 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binaries_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binaries_p20240601 OWNER TO api;

--
-- Name: binaries_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240701 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binaries_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binaries_p20240701 OWNER TO api;

--
-- Name: binaries_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240801 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.binaries_p20240801 OWNER TO api;

--
-- Name: binaries_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binaries_p20240901 (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binaries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.binaries_p20240901 OWNER TO api;

--
-- Name: binary_versions; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.binary_versions OWNER TO api;

--
-- Name: binary_versions_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_default (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.binary_versions_default OWNER TO api;

--
-- Name: TABLE binary_versions_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.binary_versions_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.binary_versions';


--
-- Name: binary_versions_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.binary_versions_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.binary_versions_journal_id_seq OWNER TO api;

--
-- Name: binary_versions_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.binary_versions_journal_id_seq OWNED BY journal.binary_versions_default.journal_id;


--
-- Name: binary_versions_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240101 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240101 OWNER TO api;

--
-- Name: binary_versions_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240201 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240201 OWNER TO api;

--
-- Name: binary_versions_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240301 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240301 OWNER TO api;

--
-- Name: binary_versions_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240401 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240401 OWNER TO api;

--
-- Name: binary_versions_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240501 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240501 OWNER TO api;

--
-- Name: binary_versions_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240601 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240601 OWNER TO api;

--
-- Name: binary_versions_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240701 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240701 OWNER TO api;

--
-- Name: binary_versions_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240801 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT binary_versions_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.binary_versions_p20240801 OWNER TO api;

--
-- Name: binary_versions_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.binary_versions_p20240901 (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.binary_versions_p20240901 OWNER TO api;

--
-- Name: github_users; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.github_users OWNER TO api;

--
-- Name: github_users_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_default (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.github_users_default OWNER TO api;

--
-- Name: TABLE github_users_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.github_users_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.github_users';


--
-- Name: github_users_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.github_users_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.github_users_journal_id_seq OWNER TO api;

--
-- Name: github_users_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.github_users_journal_id_seq OWNED BY journal.github_users_default.journal_id;


--
-- Name: github_users_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240101 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.github_users_p20240101 OWNER TO api;

--
-- Name: github_users_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240201 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.github_users_p20240201 OWNER TO api;

--
-- Name: github_users_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240301 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT github_users_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.github_users_p20240301 OWNER TO api;

--
-- Name: github_users_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240401 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT github_users_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.github_users_p20240401 OWNER TO api;

--
-- Name: github_users_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240501 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT github_users_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.github_users_p20240501 OWNER TO api;

--
-- Name: github_users_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240601 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT github_users_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.github_users_p20240601 OWNER TO api;

--
-- Name: github_users_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240701 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT github_users_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.github_users_p20240701 OWNER TO api;

--
-- Name: github_users_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240801 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.github_users_p20240801 OWNER TO api;

--
-- Name: github_users_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.github_users_p20240901 (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.github_users_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.github_users_p20240901 OWNER TO api;

--
-- Name: last_emails; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.last_emails OWNER TO api;

--
-- Name: last_emails_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_default (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.last_emails_default OWNER TO api;

--
-- Name: TABLE last_emails_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.last_emails_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.last_emails';


--
-- Name: last_emails_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.last_emails_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.last_emails_journal_id_seq OWNER TO api;

--
-- Name: last_emails_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.last_emails_journal_id_seq OWNED BY journal.last_emails_default.journal_id;


--
-- Name: last_emails_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240101 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240101 OWNER TO api;

--
-- Name: last_emails_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240201 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240201 OWNER TO api;

--
-- Name: last_emails_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240301 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240301 OWNER TO api;

--
-- Name: last_emails_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240401 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240401 OWNER TO api;

--
-- Name: last_emails_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240501 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240501 OWNER TO api;

--
-- Name: last_emails_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240601 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240601 OWNER TO api;

--
-- Name: last_emails_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240701 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240701 OWNER TO api;

--
-- Name: last_emails_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240801 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT last_emails_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.last_emails_p20240801 OWNER TO api;

--
-- Name: last_emails_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.last_emails_p20240901 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.last_emails_p20240901 OWNER TO api;

--
-- Name: libraries; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.libraries OWNER TO api;

--
-- Name: libraries_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_default (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.libraries_default OWNER TO api;

--
-- Name: TABLE libraries_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.libraries_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.libraries';


--
-- Name: libraries_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.libraries_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.libraries_journal_id_seq OWNER TO api;

--
-- Name: libraries_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.libraries_journal_id_seq OWNED BY journal.libraries_default.journal_id;


--
-- Name: libraries_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240101 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240101 OWNER TO api;

--
-- Name: libraries_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240201 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240201 OWNER TO api;

--
-- Name: libraries_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240301 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240301 OWNER TO api;

--
-- Name: libraries_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240401 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240401 OWNER TO api;

--
-- Name: libraries_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240501 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240501 OWNER TO api;

--
-- Name: libraries_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240601 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240601 OWNER TO api;

--
-- Name: libraries_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240701 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240701 OWNER TO api;

--
-- Name: libraries_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240801 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT libraries_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.libraries_p20240801 OWNER TO api;

--
-- Name: libraries_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.libraries_p20240901 (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.libraries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.libraries_p20240901 OWNER TO api;

--
-- Name: library_versions; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.library_versions OWNER TO api;

--
-- Name: library_versions_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_default (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.library_versions_default OWNER TO api;

--
-- Name: TABLE library_versions_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.library_versions_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.library_versions';


--
-- Name: library_versions_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.library_versions_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.library_versions_journal_id_seq OWNER TO api;

--
-- Name: library_versions_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.library_versions_journal_id_seq OWNED BY journal.library_versions_default.journal_id;


--
-- Name: library_versions_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240101 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240101 OWNER TO api;

--
-- Name: library_versions_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240201 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240201 OWNER TO api;

--
-- Name: library_versions_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240301 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240301 OWNER TO api;

--
-- Name: library_versions_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240401 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240401 OWNER TO api;

--
-- Name: library_versions_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240501 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240501 OWNER TO api;

--
-- Name: library_versions_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240601 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240601 OWNER TO api;

--
-- Name: library_versions_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240701 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240701 OWNER TO api;

--
-- Name: library_versions_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240801 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT library_versions_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.library_versions_p20240801 OWNER TO api;

--
-- Name: library_versions_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.library_versions_p20240901 (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.library_versions_p20240901 OWNER TO api;

--
-- Name: memberships; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.memberships OWNER TO api;

--
-- Name: memberships_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_default (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.memberships_default OWNER TO api;

--
-- Name: TABLE memberships_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.memberships_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.memberships';


--
-- Name: memberships_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.memberships_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.memberships_journal_id_seq OWNER TO api;

--
-- Name: memberships_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.memberships_journal_id_seq OWNED BY journal.memberships_default.journal_id;


--
-- Name: memberships_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240101 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240101 OWNER TO api;

--
-- Name: memberships_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240201 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240201 OWNER TO api;

--
-- Name: memberships_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240301 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240301 OWNER TO api;

--
-- Name: memberships_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240401 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240401 OWNER TO api;

--
-- Name: memberships_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240501 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240501 OWNER TO api;

--
-- Name: memberships_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240601 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240601 OWNER TO api;

--
-- Name: memberships_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240701 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240701 OWNER TO api;

--
-- Name: memberships_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240801 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT memberships_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.memberships_p20240801 OWNER TO api;

--
-- Name: memberships_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.memberships_p20240901 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.memberships_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.memberships_p20240901 OWNER TO api;

--
-- Name: organizations; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.organizations OWNER TO api;

--
-- Name: organizations_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_default (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.organizations_default OWNER TO api;

--
-- Name: TABLE organizations_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.organizations_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.organizations';


--
-- Name: organizations_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.organizations_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.organizations_journal_id_seq OWNER TO api;

--
-- Name: organizations_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.organizations_journal_id_seq OWNED BY journal.organizations_default.journal_id;


--
-- Name: organizations_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240101 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240101 OWNER TO api;

--
-- Name: organizations_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240201 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240201 OWNER TO api;

--
-- Name: organizations_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240301 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240301 OWNER TO api;

--
-- Name: organizations_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240401 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240401 OWNER TO api;

--
-- Name: organizations_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240501 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240501 OWNER TO api;

--
-- Name: organizations_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240601 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240601 OWNER TO api;

--
-- Name: organizations_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240701 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT organizations_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.organizations_p20240701 OWNER TO api;

--
-- Name: organizations_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240801 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.organizations_p20240801 OWNER TO api;

--
-- Name: organizations_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.organizations_p20240901 (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.organizations_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.organizations_p20240901 OWNER TO api;

--
-- Name: project_binaries; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.project_binaries OWNER TO api;

--
-- Name: project_binaries_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_default (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.project_binaries_default OWNER TO api;

--
-- Name: TABLE project_binaries_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.project_binaries_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.project_binaries';


--
-- Name: project_binaries_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.project_binaries_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.project_binaries_journal_id_seq OWNER TO api;

--
-- Name: project_binaries_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.project_binaries_journal_id_seq OWNED BY journal.project_binaries_default.journal_id;


--
-- Name: project_binaries_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240101 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240101 OWNER TO api;

--
-- Name: project_binaries_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240201 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240201 OWNER TO api;

--
-- Name: project_binaries_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240301 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240301 OWNER TO api;

--
-- Name: project_binaries_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240401 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240401 OWNER TO api;

--
-- Name: project_binaries_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240501 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240501 OWNER TO api;

--
-- Name: project_binaries_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240601 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240601 OWNER TO api;

--
-- Name: project_binaries_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240701 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240701 OWNER TO api;

--
-- Name: project_binaries_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240801 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_binaries_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_binaries_p20240801 OWNER TO api;

--
-- Name: project_binaries_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_binaries_p20240901 (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.project_binaries_p20240901 OWNER TO api;

--
-- Name: project_libraries; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.project_libraries OWNER TO api;

--
-- Name: project_libraries_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_default (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.project_libraries_default OWNER TO api;

--
-- Name: TABLE project_libraries_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.project_libraries_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.project_libraries';


--
-- Name: project_libraries_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.project_libraries_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.project_libraries_journal_id_seq OWNER TO api;

--
-- Name: project_libraries_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.project_libraries_journal_id_seq OWNED BY journal.project_libraries_default.journal_id;


--
-- Name: project_libraries_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240101 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240101 OWNER TO api;

--
-- Name: project_libraries_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240201 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240201 OWNER TO api;

--
-- Name: project_libraries_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240301 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240301 OWNER TO api;

--
-- Name: project_libraries_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240401 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240401 OWNER TO api;

--
-- Name: project_libraries_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240501 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240501 OWNER TO api;

--
-- Name: project_libraries_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240601 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240601 OWNER TO api;

--
-- Name: project_libraries_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240701 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240701 OWNER TO api;

--
-- Name: project_libraries_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240801 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT project_libraries_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.project_libraries_p20240801 OWNER TO api;

--
-- Name: project_libraries_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.project_libraries_p20240901 (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.project_libraries_p20240901 OWNER TO api;

--
-- Name: projects; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.projects OWNER TO api;

--
-- Name: projects_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_default (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.projects_default OWNER TO api;

--
-- Name: TABLE projects_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.projects_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.projects';


--
-- Name: projects_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.projects_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.projects_journal_id_seq OWNER TO api;

--
-- Name: projects_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.projects_journal_id_seq OWNED BY journal.projects_default.journal_id;


--
-- Name: projects_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240101 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240101 OWNER TO api;

--
-- Name: projects_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240201 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240201 OWNER TO api;

--
-- Name: projects_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240301 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240301 OWNER TO api;

--
-- Name: projects_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240401 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240401 OWNER TO api;

--
-- Name: projects_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240501 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240501 OWNER TO api;

--
-- Name: projects_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240601 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240601 OWNER TO api;

--
-- Name: projects_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240701 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT projects_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.projects_p20240701 OWNER TO api;

--
-- Name: projects_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240801 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.projects_p20240801 OWNER TO api;

--
-- Name: projects_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.projects_p20240901 (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.projects_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.projects_p20240901 OWNER TO api;

--
-- Name: recommendations; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.recommendations OWNER TO api;

--
-- Name: recommendations_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_default (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.recommendations_default OWNER TO api;

--
-- Name: TABLE recommendations_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.recommendations_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.recommendations';


--
-- Name: recommendations_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.recommendations_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.recommendations_journal_id_seq OWNER TO api;

--
-- Name: recommendations_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.recommendations_journal_id_seq OWNED BY journal.recommendations_default.journal_id;


--
-- Name: recommendations_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240101 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240101 OWNER TO api;

--
-- Name: recommendations_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240201 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240201 OWNER TO api;

--
-- Name: recommendations_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240301 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240301 OWNER TO api;

--
-- Name: recommendations_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240401 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240401 OWNER TO api;

--
-- Name: recommendations_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240501 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240501 OWNER TO api;

--
-- Name: recommendations_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240601 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240601 OWNER TO api;

--
-- Name: recommendations_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240701 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240701 OWNER TO api;

--
-- Name: recommendations_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240801 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT recommendations_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.recommendations_p20240801 OWNER TO api;

--
-- Name: recommendations_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.recommendations_p20240901 (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.recommendations_p20240901 OWNER TO api;

--
-- Name: resolvers; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.resolvers OWNER TO api;

--
-- Name: resolvers_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_default (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.resolvers_default OWNER TO api;

--
-- Name: TABLE resolvers_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.resolvers_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.resolvers';


--
-- Name: resolvers_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.resolvers_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.resolvers_journal_id_seq OWNER TO api;

--
-- Name: resolvers_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.resolvers_journal_id_seq OWNED BY journal.resolvers_default.journal_id;


--
-- Name: resolvers_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240101 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.resolvers_p20240101 OWNER TO api;

--
-- Name: resolvers_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240201 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.resolvers_p20240201 OWNER TO api;

--
-- Name: resolvers_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240301 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT resolvers_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.resolvers_p20240301 OWNER TO api;

--
-- Name: resolvers_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240401 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT resolvers_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.resolvers_p20240401 OWNER TO api;

--
-- Name: resolvers_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240501 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT resolvers_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.resolvers_p20240501 OWNER TO api;

--
-- Name: resolvers_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240601 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT resolvers_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.resolvers_p20240601 OWNER TO api;

--
-- Name: resolvers_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240701 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT resolvers_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.resolvers_p20240701 OWNER TO api;

--
-- Name: resolvers_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240801 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.resolvers_p20240801 OWNER TO api;

--
-- Name: resolvers_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.resolvers_p20240901 (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.resolvers_p20240901 OWNER TO api;

--
-- Name: subscriptions; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.subscriptions OWNER TO api;

--
-- Name: subscriptions_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_default (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.subscriptions_default OWNER TO api;

--
-- Name: TABLE subscriptions_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.subscriptions_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.subscriptions';


--
-- Name: subscriptions_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.subscriptions_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.subscriptions_journal_id_seq OWNER TO api;

--
-- Name: subscriptions_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.subscriptions_journal_id_seq OWNED BY journal.subscriptions_default.journal_id;


--
-- Name: subscriptions_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240101 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240101 OWNER TO api;

--
-- Name: subscriptions_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240201 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240201 OWNER TO api;

--
-- Name: subscriptions_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240301 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240301 OWNER TO api;

--
-- Name: subscriptions_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240401 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240401 OWNER TO api;

--
-- Name: subscriptions_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240501 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240501 OWNER TO api;

--
-- Name: subscriptions_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240601 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240601 OWNER TO api;

--
-- Name: subscriptions_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240701 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240701 OWNER TO api;

--
-- Name: subscriptions_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240801 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT subscriptions_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.subscriptions_p20240801 OWNER TO api;

--
-- Name: subscriptions_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.subscriptions_p20240901 (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.subscriptions_p20240901 OWNER TO api;

--
-- Name: tokens; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.tokens OWNER TO api;

--
-- Name: tokens_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_default (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.tokens_default OWNER TO api;

--
-- Name: TABLE tokens_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.tokens_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.tokens';


--
-- Name: tokens_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.tokens_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.tokens_journal_id_seq OWNER TO api;

--
-- Name: tokens_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.tokens_journal_id_seq OWNED BY journal.tokens_default.journal_id;


--
-- Name: tokens_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240101 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240101 OWNER TO api;

--
-- Name: tokens_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240201 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240201 OWNER TO api;

--
-- Name: tokens_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240301 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240301 OWNER TO api;

--
-- Name: tokens_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240401 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240401 OWNER TO api;

--
-- Name: tokens_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240501 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240501 OWNER TO api;

--
-- Name: tokens_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240601 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240601 OWNER TO api;

--
-- Name: tokens_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240701 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240701 OWNER TO api;

--
-- Name: tokens_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240801 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT tokens_p2024_08_partition_check CHECK (((journal_timestamp >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-09-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.tokens_p20240801 OWNER TO api;

--
-- Name: tokens_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.tokens_p20240901 (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.tokens_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.tokens_p20240901 OWNER TO api;

--
-- Name: user_identifiers; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.user_identifiers OWNER TO api;

--
-- Name: user_identifiers_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_default (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.user_identifiers_default OWNER TO api;

--
-- Name: TABLE user_identifiers_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.user_identifiers_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.user_identifiers';


--
-- Name: user_identifiers_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.user_identifiers_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.user_identifiers_journal_id_seq OWNER TO api;

--
-- Name: user_identifiers_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.user_identifiers_journal_id_seq OWNED BY journal.user_identifiers_default.journal_id;


--
-- Name: user_identifiers_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240101 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240101 OWNER TO api;

--
-- Name: user_identifiers_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240201 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240201 OWNER TO api;

--
-- Name: user_identifiers_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240301 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240301 OWNER TO api;

--
-- Name: user_identifiers_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240401 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240401 OWNER TO api;

--
-- Name: user_identifiers_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240501 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240501 OWNER TO api;

--
-- Name: user_identifiers_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240601 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240601 OWNER TO api;

--
-- Name: user_identifiers_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240701 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_identifiers_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_identifiers_p20240701 OWNER TO api;

--
-- Name: user_identifiers_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240801 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.user_identifiers_p20240801 OWNER TO api;

--
-- Name: user_identifiers_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_identifiers_p20240901 (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.user_identifiers_p20240901 OWNER TO api;

--
-- Name: user_organizations; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.user_organizations OWNER TO api;

--
-- Name: user_organizations_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_default (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.user_organizations_default OWNER TO api;

--
-- Name: TABLE user_organizations_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.user_organizations_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.user_organizations';


--
-- Name: user_organizations_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.user_organizations_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.user_organizations_journal_id_seq OWNER TO api;

--
-- Name: user_organizations_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.user_organizations_journal_id_seq OWNED BY journal.user_organizations_default.journal_id;


--
-- Name: user_organizations_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240101 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240101 OWNER TO api;

--
-- Name: user_organizations_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240201 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240201 OWNER TO api;

--
-- Name: user_organizations_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240301 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240301 OWNER TO api;

--
-- Name: user_organizations_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240401 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240401 OWNER TO api;

--
-- Name: user_organizations_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240501 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240501 OWNER TO api;

--
-- Name: user_organizations_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240601 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240601 OWNER TO api;

--
-- Name: user_organizations_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240701 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT user_organizations_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.user_organizations_p20240701 OWNER TO api;

--
-- Name: user_organizations_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240801 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.user_organizations_p20240801 OWNER TO api;

--
-- Name: user_organizations_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.user_organizations_p20240901 (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.user_organizations_p20240901 OWNER TO api;

--
-- Name: users; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
PARTITION BY RANGE (journal_timestamp);


ALTER TABLE journal.users OWNER TO api;

--
-- Name: users_default; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_default (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
)
WITH (fillfactor='100');


ALTER TABLE journal.users_default OWNER TO api;

--
-- Name: TABLE users_default; Type: COMMENT; Schema: journal; Owner: api
--

COMMENT ON TABLE journal.users_default IS 'Created by plsql function refresh_journaling to shadow all inserts and updates on the table public.users';


--
-- Name: users_journal_id_seq; Type: SEQUENCE; Schema: journal; Owner: api
--

CREATE SEQUENCE journal.users_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE journal.users_journal_id_seq OWNER TO api;

--
-- Name: users_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: journal; Owner: api
--

ALTER SEQUENCE journal.users_journal_id_seq OWNED BY journal.users_default.journal_id;


--
-- Name: users_p20240101; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240101 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_01_partition_check CHECK (((journal_timestamp >= '2024-01-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-02-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240101 OWNER TO api;

--
-- Name: users_p20240201; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240201 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_02_partition_check CHECK (((journal_timestamp >= '2024-02-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-03-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240201 OWNER TO api;

--
-- Name: users_p20240301; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240301 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_03_partition_check CHECK (((journal_timestamp >= '2024-03-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-04-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240301 OWNER TO api;

--
-- Name: users_p20240401; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240401 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_04_partition_check CHECK (((journal_timestamp >= '2024-04-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-05-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240401 OWNER TO api;

--
-- Name: users_p20240501; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240501 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_05_partition_check CHECK (((journal_timestamp >= '2024-05-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-06-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240501 OWNER TO api;

--
-- Name: users_p20240601; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240601 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_06_partition_check CHECK (((journal_timestamp >= '2024-06-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-07-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240601 OWNER TO api;

--
-- Name: users_p20240701; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240701 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL,
    CONSTRAINT users_p2024_07_partition_check CHECK (((journal_timestamp >= '2024-07-01 00:00:00+00'::timestamp with time zone) AND (journal_timestamp < '2024-08-01 00:00:00+00'::timestamp with time zone)))
);


ALTER TABLE journal.users_p20240701 OWNER TO api;

--
-- Name: users_p20240801; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240801 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.users_p20240801 OWNER TO api;

--
-- Name: users_p20240901; Type: TABLE; Schema: journal; Owner: api
--

CREATE TABLE journal.users_p20240901 (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone DEFAULT now() NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint DEFAULT nextval('journal.users_journal_id_seq'::regclass) NOT NULL
);


ALTER TABLE journal.users_p20240901 OWNER TO api;

--
-- Name: part_config; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.part_config (
    parent_table text NOT NULL,
    control text NOT NULL,
    partition_interval text NOT NULL,
    partition_type text NOT NULL,
    premake integer DEFAULT 4 NOT NULL,
    automatic_maintenance text DEFAULT 'on'::text NOT NULL,
    template_table text,
    retention text,
    retention_schema text,
    retention_keep_index boolean DEFAULT true NOT NULL,
    retention_keep_table boolean DEFAULT true NOT NULL,
    epoch text DEFAULT 'none'::text NOT NULL,
    constraint_cols text[],
    optimize_constraint integer DEFAULT 30 NOT NULL,
    infinite_time_partitions boolean DEFAULT false NOT NULL,
    datetime_string text,
    jobmon boolean DEFAULT true NOT NULL,
    sub_partition_set_full boolean DEFAULT false NOT NULL,
    undo_in_progress boolean DEFAULT false NOT NULL,
    inherit_privileges boolean DEFAULT false,
    constraint_valid boolean DEFAULT true NOT NULL,
    ignore_default_data boolean DEFAULT true NOT NULL,
    default_table boolean DEFAULT true,
    date_trunc_interval text,
    maintenance_order integer,
    retention_keep_publication boolean DEFAULT false NOT NULL,
    maintenance_last_run timestamp with time zone,
    CONSTRAINT control_constraint_col_chk CHECK (((constraint_cols @> ARRAY[control]) <> true)),
    CONSTRAINT part_config_automatic_maintenance_check CHECK (partman5.check_automatic_maintenance_value(automatic_maintenance)),
    CONSTRAINT part_config_epoch_check CHECK (partman5.check_epoch_type(epoch)),
    CONSTRAINT part_config_type_check CHECK (partman5.check_partition_type(partition_type)),
    CONSTRAINT positive_premake_check CHECK ((premake > 0)),
    CONSTRAINT retention_schema_not_empty_chk CHECK ((retention_schema <> ''::text))
);


ALTER TABLE partman5.part_config OWNER TO api;

--
-- Name: part_config_sub; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.part_config_sub (
    sub_parent text NOT NULL,
    sub_control text NOT NULL,
    sub_partition_interval text NOT NULL,
    sub_partition_type text NOT NULL,
    sub_premake integer DEFAULT 4 NOT NULL,
    sub_automatic_maintenance text DEFAULT 'on'::text NOT NULL,
    sub_template_table text,
    sub_retention text,
    sub_retention_schema text,
    sub_retention_keep_index boolean DEFAULT true NOT NULL,
    sub_retention_keep_table boolean DEFAULT true NOT NULL,
    sub_epoch text DEFAULT 'none'::text NOT NULL,
    sub_constraint_cols text[],
    sub_optimize_constraint integer DEFAULT 30 NOT NULL,
    sub_infinite_time_partitions boolean DEFAULT false NOT NULL,
    sub_jobmon boolean DEFAULT true NOT NULL,
    sub_inherit_privileges boolean DEFAULT false,
    sub_constraint_valid boolean DEFAULT true NOT NULL,
    sub_ignore_default_data boolean DEFAULT true NOT NULL,
    sub_default_table boolean DEFAULT true,
    sub_date_trunc_interval text,
    sub_maintenance_order integer,
    sub_retention_keep_publication boolean DEFAULT false NOT NULL,
    CONSTRAINT control_constraint_col_chk CHECK (((sub_constraint_cols @> ARRAY[sub_control]) <> true)),
    CONSTRAINT part_config_sub_automatic_maintenance_check CHECK (partman5.check_automatic_maintenance_value(sub_automatic_maintenance)),
    CONSTRAINT part_config_sub_epoch_check CHECK (partman5.check_epoch_type(sub_epoch)),
    CONSTRAINT part_config_sub_type_check CHECK (partman5.check_partition_type(sub_partition_type)),
    CONSTRAINT positive_premake_check CHECK ((sub_premake > 0)),
    CONSTRAINT retention_schema_not_empty_chk CHECK ((sub_retention_schema <> ''::text))
);


ALTER TABLE partman5.part_config_sub OWNER TO api;

--
-- Name: table_privs; Type: VIEW; Schema: partman5; Owner: api
--

CREATE VIEW partman5.table_privs AS
 SELECT u_grantor.rolname AS grantor,
    grantee.rolname AS grantee,
    nc.nspname AS table_schema,
    c.relname AS table_name,
    c.prtype AS privilege_type
   FROM ( SELECT pg_class.oid,
            pg_class.relname,
            pg_class.relnamespace,
            pg_class.relkind,
            pg_class.relowner,
            (aclexplode(COALESCE(pg_class.relacl, acldefault('r'::"char", pg_class.relowner)))).grantor AS grantor,
            (aclexplode(COALESCE(pg_class.relacl, acldefault('r'::"char", pg_class.relowner)))).grantee AS grantee,
            (aclexplode(COALESCE(pg_class.relacl, acldefault('r'::"char", pg_class.relowner)))).privilege_type AS privilege_type,
            (aclexplode(COALESCE(pg_class.relacl, acldefault('r'::"char", pg_class.relowner)))).is_grantable AS is_grantable
           FROM pg_class) c(oid, relname, relnamespace, relkind, relowner, grantor, grantee, prtype, grantable),
    pg_namespace nc,
    pg_roles u_grantor,
    ( SELECT pg_roles.oid,
            pg_roles.rolname
           FROM pg_roles
        UNION ALL
         SELECT (0)::oid AS oid,
            'PUBLIC'::name) grantee(oid, rolname)
  WHERE ((c.relnamespace = nc.oid) AND (c.relkind = ANY (ARRAY['r'::"char", 'v'::"char", 'p'::"char"])) AND (c.grantee = grantee.oid) AND (c.grantor = u_grantor.oid) AND (c.prtype = ANY (ARRAY['INSERT'::text, 'SELECT'::text, 'UPDATE'::text, 'DELETE'::text, 'TRUNCATE'::text, 'REFERENCES'::text, 'TRIGGER'::text])) AND (pg_has_role(u_grantor.oid, 'USAGE'::text) OR pg_has_role(grantee.oid, 'USAGE'::text) OR (grantee.rolname = 'PUBLIC'::name)));


ALTER TABLE partman5.table_privs OWNER TO api;

--
-- Name: template_journal_binaries; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_binaries (
    id text NOT NULL,
    organization_id text,
    name text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_binaries OWNER TO api;

--
-- Name: template_journal_binary_versions; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_binary_versions (
    id text NOT NULL,
    binary_id text,
    version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_binary_versions OWNER TO api;

--
-- Name: template_journal_github_users; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_github_users (
    id text NOT NULL,
    user_id text,
    github_user_id bigint,
    login text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_github_users OWNER TO api;

--
-- Name: template_journal_last_emails; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_last_emails (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_last_emails OWNER TO api;

--
-- Name: template_journal_libraries; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_libraries (
    id text NOT NULL,
    organization_id text,
    group_id text,
    artifact_id text,
    resolver_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_libraries OWNER TO api;

--
-- Name: template_journal_library_versions; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_library_versions (
    id text NOT NULL,
    library_id text,
    version text,
    cross_build_version text,
    sort_key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_library_versions OWNER TO api;

--
-- Name: template_journal_memberships; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_memberships (
    id text NOT NULL,
    user_id text,
    organization_id text,
    role text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_memberships OWNER TO api;

--
-- Name: template_journal_organizations; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_organizations (
    id text NOT NULL,
    user_id text,
    key text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_organizations OWNER TO api;

--
-- Name: template_journal_project_binaries; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_project_binaries (
    id text NOT NULL,
    project_id text,
    name text,
    version text,
    path text,
    binary_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_project_binaries OWNER TO api;

--
-- Name: template_journal_project_libraries; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_project_libraries (
    id text NOT NULL,
    project_id text,
    group_id text,
    artifact_id text,
    version text,
    cross_build_version text,
    path text,
    library_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_project_libraries OWNER TO api;

--
-- Name: template_journal_projects; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_projects (
    id text NOT NULL,
    organization_id text,
    user_id text,
    visibility text,
    scms text,
    name text,
    uri text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_projects OWNER TO api;

--
-- Name: template_journal_recommendations; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_recommendations (
    id text NOT NULL,
    project_id text,
    type text,
    object_id text,
    name text,
    from_version text,
    to_version text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_recommendations OWNER TO api;

--
-- Name: template_journal_resolvers; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_resolvers (
    id text NOT NULL,
    visibility text,
    organization_id text,
    uri text,
    "position" integer,
    credentials json,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_resolvers OWNER TO api;

--
-- Name: template_journal_subscriptions; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_subscriptions (
    id text NOT NULL,
    user_id text,
    publication text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_subscriptions OWNER TO api;

--
-- Name: template_journal_tokens; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_tokens (
    id text NOT NULL,
    user_id text,
    tag text,
    token text,
    number_views bigint,
    description text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_tokens OWNER TO api;

--
-- Name: template_journal_user_identifiers; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_user_identifiers (
    id text NOT NULL,
    user_id text,
    value text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_user_identifiers OWNER TO api;

--
-- Name: template_journal_user_organizations; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_user_organizations (
    id text NOT NULL,
    user_id text,
    organization_id text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_user_organizations OWNER TO api;

--
-- Name: template_journal_users; Type: TABLE; Schema: partman5; Owner: api
--

CREATE TABLE partman5.template_journal_users (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    journal_timestamp timestamp with time zone NOT NULL,
    journal_operation text NOT NULL,
    journal_id bigint NOT NULL
);


ALTER TABLE partman5.template_journal_users OWNER TO api;

--
-- Name: binaries; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.binaries (
    id text NOT NULL,
    organization_id text NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT binaries_name_check CHECK (util.non_empty_trimmed_string(name))
);


ALTER TABLE public.binaries OWNER TO api;

--
-- Name: TABLE binaries; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.binaries IS '
  Stores all binaries that we are tracking in some way (e.g. scala)
';


--
-- Name: binary_versions; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.binary_versions (
    id text NOT NULL,
    binary_id text NOT NULL,
    version text NOT NULL,
    sort_key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT binary_versions_version_check CHECK (util.non_empty_trimmed_string(version))
);


ALTER TABLE public.binary_versions OWNER TO api;

--
-- Name: TABLE binary_versions; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.binary_versions IS '
  Stores all binary_versions of a given binary - e.g. 2.11.7
';


--
-- Name: github_users; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.github_users (
    id text NOT NULL,
    user_id text NOT NULL,
    github_user_id bigint NOT NULL,
    login text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT github_users_login_check CHECK (util.non_empty_trimmed_string(login))
);


ALTER TABLE public.github_users OWNER TO api;

--
-- Name: TABLE github_users; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.github_users IS '
  Maps our users to their IDs in third party systems (e.g. github)
';


--
-- Name: items; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.items (
    id text NOT NULL,
    organization_id text NOT NULL,
    visibility text NOT NULL,
    object_id text NOT NULL,
    label text NOT NULL,
    description text,
    summary json,
    contents text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    hash_code bigint NOT NULL,
    CONSTRAINT items_contents_check CHECK (util.non_empty_trimmed_string(contents)),
    CONSTRAINT items_contents_check1 CHECK ((lower(contents) = contents)),
    CONSTRAINT items_description_check CHECK ((btrim(description) = description)),
    CONSTRAINT items_label_check CHECK (util.non_empty_trimmed_string(label)),
    CONSTRAINT items_visibility_check CHECK (util.lower_non_empty_trimmed_string(visibility))
);


ALTER TABLE public.items OWNER TO api;

--
-- Name: TABLE items; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.items IS '
  A denormalization of things that we want to search for. Basic model
  is that as the types are updated, we store a denormalized copy here
  just for search - e.g. projects, libraries, and binaries are
  denormalized here.
';


--
-- Name: COLUMN items.summary; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.items.summary IS '
  Information specific to the type of object indexed. See the
  item_detail union type at http://apidoc.me/bryzek/dependency/latest
';


--
-- Name: COLUMN items.contents; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.items.contents IS '
  All of the actual textual contents we search.
';


--
-- Name: items_bak; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.items_bak (
    id text,
    organization_id text,
    visibility text,
    object_id text,
    label text,
    description text,
    summary json,
    contents text,
    created_at timestamp with time zone,
    updated_by_user_id text,
    updated_at timestamp with time zone,
    hash_code bigint
);


ALTER TABLE public.items_bak OWNER TO api;

--
-- Name: last_emails; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.last_emails (
    id text NOT NULL,
    user_id text NOT NULL,
    publication text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT last_emails_publication_check CHECK (util.lower_non_empty_trimmed_string(publication))
);


ALTER TABLE public.last_emails OWNER TO api;

--
-- Name: TABLE last_emails; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.last_emails IS '
  For publications like the daily email, records when we last
  generated an email to a user.
';


--
-- Name: libraries; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.libraries (
    id text NOT NULL,
    organization_id text NOT NULL,
    group_id text NOT NULL,
    artifact_id text NOT NULL,
    resolver_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT libraries_artifact_id_check CHECK (util.non_empty_trimmed_string(artifact_id)),
    CONSTRAINT libraries_group_id_check CHECK (util.non_empty_trimmed_string(group_id))
);


ALTER TABLE public.libraries OWNER TO api;

--
-- Name: TABLE libraries; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.libraries IS '
  Stores all libraries that we are tracking in some way.
';


--
-- Name: COLUMN libraries.resolver_id; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.libraries.resolver_id IS '
  The resolver we are using to identify versions of this library.
';


--
-- Name: library_versions; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.library_versions (
    id text NOT NULL,
    library_id text NOT NULL,
    version text NOT NULL,
    cross_build_version text,
    sort_key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT library_versions_cross_build_version_check CHECK ((btrim(cross_build_version) = cross_build_version)),
    CONSTRAINT library_versions_version_check CHECK (util.non_empty_trimmed_string(version))
);


ALTER TABLE public.library_versions OWNER TO api;

--
-- Name: TABLE library_versions; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.library_versions IS '
  Stores all library_versions of a given library - e.g. 9.4-1205-jdbc42
';


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.memberships (
    id text NOT NULL,
    user_id text NOT NULL,
    organization_id text NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT memberships_role_check CHECK (util.lower_non_empty_trimmed_string(role))
);


ALTER TABLE public.memberships OWNER TO api;

--
-- Name: TABLE memberships; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.memberships IS '
  Users can join other organizations. Note that the user_organizations table
  records the specific organization assigned to a user while this table lists
  all the members of an org and is used to represent group accounts (e.g. an
  organization representing a company). Note that we only allow one row
  per user/org - and we store only the higher role (e.g. admin).
';


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.organizations (
    id text NOT NULL,
    user_id text NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT organizations_key_check CHECK (util.lower_non_empty_trimmed_string(key))
);


ALTER TABLE public.organizations OWNER TO api;

--
-- Name: TABLE organizations; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.organizations IS '
  An organization is the top level entity to which projects,
  libraries, binaries, etc. exist. The primary purpose is to enable
  SAAS - segmenting data by organization.
';


--
-- Name: COLUMN organizations.user_id; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.organizations.user_id IS '
  The user that created this organization.
';


--
-- Name: COLUMN organizations.key; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.organizations.key IS '
  Used to uniquely identify this organization. URL friendly.
';


--
-- Name: project_binaries; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.project_binaries (
    id text NOT NULL,
    project_id text,
    name text NOT NULL,
    version text NOT NULL,
    path text NOT NULL,
    binary_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT project_binaries_name_check CHECK (util.non_empty_trimmed_string(name)),
    CONSTRAINT project_binaries_path_check CHECK (util.non_empty_trimmed_string(path)),
    CONSTRAINT project_binaries_version_check CHECK (util.non_empty_trimmed_string(version))
);


ALTER TABLE public.project_binaries OWNER TO api;

--
-- Name: TABLE project_binaries; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.project_binaries IS '
  Stores all of the binaries that this project depends on.
';


--
-- Name: COLUMN project_binaries.path; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.project_binaries.path IS '
  The path relative to the root of the SCMS folder to the
  file in which we found this dependency.
';


--
-- Name: project_libraries; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.project_libraries (
    id text NOT NULL,
    project_id text,
    group_id text NOT NULL,
    artifact_id text NOT NULL,
    version text NOT NULL,
    cross_build_version text,
    path text NOT NULL,
    library_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    organization_id text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    hash_code bigint NOT NULL,
    CONSTRAINT project_libraries_artifact_id_check CHECK (util.non_empty_trimmed_string(artifact_id)),
    CONSTRAINT project_libraries_cross_build_version_check CHECK ((btrim(cross_build_version) = cross_build_version)),
    CONSTRAINT project_libraries_group_id_check CHECK (util.non_empty_trimmed_string(group_id)),
    CONSTRAINT project_libraries_path_check CHECK (util.non_empty_trimmed_string(path)),
    CONSTRAINT project_libraries_version_check CHECK (util.non_empty_trimmed_string(version))
);


ALTER TABLE public.project_libraries OWNER TO api;

--
-- Name: TABLE project_libraries; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.project_libraries IS '
  Stores all of the libraries that this project depends on.
';


--
-- Name: COLUMN project_libraries.path; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.project_libraries.path IS '
  The path relative to the root of the SCMS folder to the
  file in which we found this dependency.
';


--
-- Name: COLUMN project_libraries.library_id; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.project_libraries.library_id IS '
  If we successfully resolve this project library, we associate
  the record with the global library object - serving as the basis
  by which we can make upgrade recommendations.
';


--
-- Name: projects; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.projects (
    id text NOT NULL,
    organization_id text NOT NULL,
    user_id text NOT NULL,
    visibility text NOT NULL,
    scms text NOT NULL,
    name text NOT NULL,
    uri text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    branch text NOT NULL,
    CONSTRAINT projects_branch_check CHECK (util.non_empty_trimmed_string(branch)),
    CONSTRAINT projects_name_check CHECK (util.non_empty_trimmed_string(name)),
    CONSTRAINT projects_scms_check CHECK (util.lower_non_empty_trimmed_string(scms)),
    CONSTRAINT projects_uri_check CHECK (util.non_empty_trimmed_string(uri)),
    CONSTRAINT projects_visibility_check CHECK (util.lower_non_empty_trimmed_string(visibility))
);


ALTER TABLE public.projects OWNER TO api;

--
-- Name: TABLE projects; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.projects IS '
  A project is essentially a source code repository for which we are
  tracking its dependent libraries.
';


--
-- Name: COLUMN projects.user_id; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.projects.user_id IS '
  The user that created this project
';


--
-- Name: COLUMN projects.scms; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.projects.scms IS '
  The source code management system where we find this project.
';


--
-- Name: COLUMN projects.name; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.projects.name IS '
  The full name for this project. In github, this will be
  <owner>/<name> (e.g. bryzek/apidoc).
';


--
-- Name: recommendations; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.recommendations (
    id text NOT NULL,
    project_id text NOT NULL,
    type text NOT NULL,
    object_id text NOT NULL,
    name text NOT NULL,
    from_version text NOT NULL,
    to_version text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT recommendations_from_version_check CHECK (util.non_empty_trimmed_string(from_version)),
    CONSTRAINT recommendations_name_check CHECK (util.non_empty_trimmed_string(name)),
    CONSTRAINT recommendations_to_version_check CHECK (util.non_empty_trimmed_string(to_version)),
    CONSTRAINT recommendations_type_check CHECK (util.lower_non_empty_trimmed_string(type))
);


ALTER TABLE public.recommendations OWNER TO api;

--
-- Name: TABLE recommendations; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.recommendations IS '
  For each project we automatically record what our recommendations
  are in terms of which libraries and binaries to upgrade. These
  recommendations are created in the background by monitoring updates
  to both the project and its dependencies (for example, if a new
  version of a dependent library is released, we created a
  recommendation).
';


--
-- Name: replication_test_table; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.replication_test_table (
    id integer
);


ALTER TABLE public.replication_test_table OWNER TO api;

--
-- Name: resolvers; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.resolvers (
    id text NOT NULL,
    visibility text NOT NULL,
    organization_id text,
    uri text NOT NULL,
    "position" integer NOT NULL,
    credentials json,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT resolvers_organization_credentials_ck CHECK ((((organization_id IS NULL) AND (credentials IS NULL)) OR (organization_id IS NOT NULL))),
    CONSTRAINT resolvers_position_check CHECK (("position" >= 0)),
    CONSTRAINT resolvers_uri_check CHECK (util.non_empty_trimmed_string(uri)),
    CONSTRAINT resolvers_visibility_check CHECK (util.lower_non_empty_trimmed_string(visibility))
);


ALTER TABLE public.resolvers OWNER TO api;

--
-- Name: TABLE resolvers; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.resolvers IS '
  Stores resolvers we use to find library versions. Resolvers can be
  public or private - and if private follows the organization that
  created the resolver.
';


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.subscriptions (
    id text NOT NULL,
    user_id text NOT NULL,
    publication text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT subscriptions_publication_check CHECK (util.lower_non_empty_trimmed_string(publication))
);


ALTER TABLE public.subscriptions OWNER TO api;

--
-- Name: TABLE subscriptions; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.subscriptions IS '
  Keeps track of things the user has subscribed to (like a daily email)
';


--
-- Name: syncs; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.syncs (
    id text NOT NULL,
    type text NOT NULL,
    object_id text NOT NULL,
    event text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT syncs_event_check CHECK (util.lower_non_empty_trimmed_string(event)),
    CONSTRAINT syncs_type_check CHECK (util.lower_non_empty_trimmed_string(type))
);


ALTER TABLE public.syncs OWNER TO api;

--
-- Name: TABLE syncs; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.syncs IS '
  Records when we start and complete each sync of a module (e.g. project)
';


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.tasks (
    id text NOT NULL,
    data text NOT NULL,
    priority bigint NOT NULL,
    num_attempts bigint NOT NULL,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    hash_code bigint NOT NULL,
    CONSTRAINT tasks_data_check CHECK (util.non_empty_trimmed_string(data)),
    CONSTRAINT tasks_id_check CHECK (util.non_empty_trimmed_string(id)),
    CONSTRAINT tasks_num_attempts_check CHECK ((num_attempts >= 0)),
    CONSTRAINT tasks_priority_check CHECK ((priority >= 0)),
    CONSTRAINT tasks_updated_by_user_id_check CHECK (util.non_empty_trimmed_string(updated_by_user_id))
);


ALTER TABLE public.tasks OWNER TO api;

--
-- Name: tokens; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.tokens (
    id text NOT NULL,
    user_id text NOT NULL,
    tag text NOT NULL,
    token text NOT NULL,
    number_views bigint DEFAULT 0 NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT tokens_number_views_check CHECK ((number_views >= 0)),
    CONSTRAINT tokens_tag_check CHECK (util.lower_non_empty_trimmed_string(tag)),
    CONSTRAINT tokens_token_check CHECK ((btrim(token) = token))
);


ALTER TABLE public.tokens OWNER TO api;

--
-- Name: TABLE tokens; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.tokens IS '
  Stores oauth tokens for a given user.
';


--
-- Name: COLUMN tokens.tag; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.tokens.tag IS '
  Identifies the token - e.g. github_oauth
';


--
-- Name: COLUMN tokens.number_views; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.tokens.number_views IS '
  Controls retrieval of cleartext token - e.g. only can see the token once
';


--
-- Name: user_identifiers; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.user_identifiers (
    id text NOT NULL,
    user_id text NOT NULL,
    value text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    CONSTRAINT user_identifiers_value_check CHECK (util.non_empty_trimmed_string(value)),
    CONSTRAINT user_identifiers_value_check1 CHECK ((length(value) >= 40))
);


ALTER TABLE public.user_identifiers OWNER TO api;

--
-- Name: TABLE user_identifiers; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.user_identifiers IS '
  Stores unique, randomly generated identifiers that identify this
  user. The basic use case is to enable things like unsubscribe w/out
  login. Identifiers can be rotated regularly with last n identifiers
  being valid (allowing eventual expiration).
';


--
-- Name: user_organizations; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.user_organizations (
    id text NOT NULL,
    user_id text NOT NULL,
    organization_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL
);


ALTER TABLE public.user_organizations OWNER TO api;

--
-- Name: TABLE user_organizations; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.user_organizations IS '
  Each user is assigned a single organization to represent their own
  projects. This table records the org assigned to a user.
';


--
-- Name: users; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.users (
    id text NOT NULL,
    email text,
    first_name text,
    last_name text,
    avatar_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by_user_id text NOT NULL,
    status character varying(20) NOT NULL,
    CONSTRAINT users_avatar_url_check CHECK (((avatar_url IS NULL) OR (btrim(avatar_url) = avatar_url))),
    CONSTRAINT users_email_check CHECK (util.null_or_non_empty_trimmed_string(email)),
    CONSTRAINT users_first_name_check CHECK ((btrim(first_name) = first_name)),
    CONSTRAINT users_last_name_check CHECK ((btrim(last_name) = last_name))
);


ALTER TABLE public.users OWNER TO api;

--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.users IS '
  Central user database
';


--
-- Name: bootstrap_scripts; Type: TABLE; Schema: schema_evolution_manager; Owner: api
--

CREATE TABLE schema_evolution_manager.bootstrap_scripts (
    id bigint NOT NULL,
    filename character varying(100) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE schema_evolution_manager.bootstrap_scripts OWNER TO api;

--
-- Name: TABLE bootstrap_scripts; Type: COMMENT; Schema: schema_evolution_manager; Owner: api
--

COMMENT ON TABLE schema_evolution_manager.bootstrap_scripts IS '
      Internal list of schema_evolution_manager sql scripts applied. Used only for upgrades
      to schema_evolution_manager itself.
    ';


--
-- Name: bootstrap_scripts_id_seq; Type: SEQUENCE; Schema: schema_evolution_manager; Owner: api
--

CREATE SEQUENCE schema_evolution_manager.bootstrap_scripts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE schema_evolution_manager.bootstrap_scripts_id_seq OWNER TO api;

--
-- Name: bootstrap_scripts_id_seq; Type: SEQUENCE OWNED BY; Schema: schema_evolution_manager; Owner: api
--

ALTER SEQUENCE schema_evolution_manager.bootstrap_scripts_id_seq OWNED BY schema_evolution_manager.bootstrap_scripts.id;


--
-- Name: scripts; Type: TABLE; Schema: schema_evolution_manager; Owner: api
--

CREATE TABLE schema_evolution_manager.scripts (
    id bigint NOT NULL,
    filename character varying(100) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE schema_evolution_manager.scripts OWNER TO api;

--
-- Name: TABLE scripts; Type: COMMENT; Schema: schema_evolution_manager; Owner: api
--

COMMENT ON TABLE schema_evolution_manager.scripts IS '
      When a script is applied to this database, the script is recorded
      here. This table is the used to ensure scripts are applied at most
      once to this database.
    ';


--
-- Name: scripts_id_seq; Type: SEQUENCE; Schema: schema_evolution_manager; Owner: api
--

CREATE SEQUENCE schema_evolution_manager.scripts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE schema_evolution_manager.scripts_id_seq OWNER TO api;

--
-- Name: scripts_id_seq; Type: SEQUENCE OWNED BY; Schema: schema_evolution_manager; Owner: api
--

ALTER SEQUENCE schema_evolution_manager.scripts_id_seq OWNED BY schema_evolution_manager.scripts.id;


--
-- Name: binaries_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_default DEFAULT;


--
-- Name: binaries_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: binaries_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: binaries_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: binaries_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: binaries_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: binaries_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: binaries_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: binaries_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: binaries_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ATTACH PARTITION journal.binaries_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: binary_versions_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_default DEFAULT;


--
-- Name: binary_versions_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: binary_versions_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: binary_versions_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: binary_versions_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: binary_versions_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: binary_versions_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: binary_versions_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: binary_versions_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: binary_versions_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ATTACH PARTITION journal.binary_versions_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: github_users_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_default DEFAULT;


--
-- Name: github_users_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: github_users_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: github_users_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: github_users_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: github_users_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: github_users_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: github_users_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: github_users_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: github_users_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ATTACH PARTITION journal.github_users_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: last_emails_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_default DEFAULT;


--
-- Name: last_emails_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: last_emails_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: last_emails_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: last_emails_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: last_emails_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: last_emails_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: last_emails_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: last_emails_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: last_emails_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ATTACH PARTITION journal.last_emails_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: libraries_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_default DEFAULT;


--
-- Name: libraries_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: libraries_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: libraries_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: libraries_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: libraries_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: libraries_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: libraries_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: libraries_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: libraries_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ATTACH PARTITION journal.libraries_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: library_versions_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_default DEFAULT;


--
-- Name: library_versions_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: library_versions_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: library_versions_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: library_versions_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: library_versions_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: library_versions_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: library_versions_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: library_versions_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: library_versions_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ATTACH PARTITION journal.library_versions_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: memberships_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_default DEFAULT;


--
-- Name: memberships_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: memberships_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: memberships_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: memberships_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: memberships_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: memberships_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: memberships_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: memberships_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: memberships_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ATTACH PARTITION journal.memberships_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: organizations_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_default DEFAULT;


--
-- Name: organizations_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: organizations_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: organizations_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: organizations_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: organizations_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: organizations_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: organizations_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: organizations_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: organizations_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ATTACH PARTITION journal.organizations_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: project_binaries_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_default DEFAULT;


--
-- Name: project_binaries_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: project_binaries_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: project_binaries_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: project_binaries_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: project_binaries_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: project_binaries_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: project_binaries_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: project_binaries_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: project_binaries_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ATTACH PARTITION journal.project_binaries_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: project_libraries_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_default DEFAULT;


--
-- Name: project_libraries_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: project_libraries_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: project_libraries_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: project_libraries_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: project_libraries_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: project_libraries_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: project_libraries_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: project_libraries_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: project_libraries_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ATTACH PARTITION journal.project_libraries_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: projects_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_default DEFAULT;


--
-- Name: projects_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: projects_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: projects_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: projects_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: projects_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: projects_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: projects_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: projects_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: projects_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ATTACH PARTITION journal.projects_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: recommendations_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_default DEFAULT;


--
-- Name: recommendations_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: recommendations_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: recommendations_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: recommendations_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: recommendations_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: recommendations_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: recommendations_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: recommendations_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: recommendations_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ATTACH PARTITION journal.recommendations_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: resolvers_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_default DEFAULT;


--
-- Name: resolvers_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: resolvers_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: resolvers_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: resolvers_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: resolvers_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: resolvers_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: resolvers_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: resolvers_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: resolvers_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ATTACH PARTITION journal.resolvers_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: subscriptions_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_default DEFAULT;


--
-- Name: subscriptions_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: subscriptions_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: subscriptions_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: subscriptions_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: subscriptions_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: subscriptions_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: subscriptions_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: subscriptions_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: subscriptions_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ATTACH PARTITION journal.subscriptions_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: tokens_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_default DEFAULT;


--
-- Name: tokens_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: tokens_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: tokens_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: tokens_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: tokens_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: tokens_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: tokens_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: tokens_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: tokens_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ATTACH PARTITION journal.tokens_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: user_identifiers_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_default DEFAULT;


--
-- Name: user_identifiers_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: user_identifiers_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: user_identifiers_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: user_identifiers_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: user_identifiers_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: user_identifiers_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: user_identifiers_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: user_identifiers_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: user_identifiers_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ATTACH PARTITION journal.user_identifiers_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: user_organizations_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_default DEFAULT;


--
-- Name: user_organizations_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: user_organizations_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: user_organizations_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: user_organizations_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: user_organizations_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: user_organizations_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: user_organizations_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: user_organizations_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: user_organizations_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ATTACH PARTITION journal.user_organizations_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: users_default; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_default DEFAULT;


--
-- Name: users_p20240101; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240101 FOR VALUES FROM ('2024-01-01 00:00:00+00') TO ('2024-02-01 00:00:00+00');


--
-- Name: users_p20240201; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240201 FOR VALUES FROM ('2024-02-01 00:00:00+00') TO ('2024-03-01 00:00:00+00');


--
-- Name: users_p20240301; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240301 FOR VALUES FROM ('2024-03-01 00:00:00+00') TO ('2024-04-01 00:00:00+00');


--
-- Name: users_p20240401; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240401 FOR VALUES FROM ('2024-04-01 00:00:00+00') TO ('2024-05-01 00:00:00+00');


--
-- Name: users_p20240501; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240501 FOR VALUES FROM ('2024-05-01 00:00:00+00') TO ('2024-06-01 00:00:00+00');


--
-- Name: users_p20240601; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240601 FOR VALUES FROM ('2024-06-01 00:00:00+00') TO ('2024-07-01 00:00:00+00');


--
-- Name: users_p20240701; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240701 FOR VALUES FROM ('2024-07-01 00:00:00+00') TO ('2024-08-01 00:00:00+00');


--
-- Name: users_p20240801; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240801 FOR VALUES FROM ('2024-08-01 00:00:00+00') TO ('2024-09-01 00:00:00+00');


--
-- Name: users_p20240901; Type: TABLE ATTACH; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ATTACH PARTITION journal.users_p20240901 FOR VALUES FROM ('2024-09-01 00:00:00+00') TO ('2024-10-01 00:00:00+00');


--
-- Name: binaries journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries ALTER COLUMN journal_id SET DEFAULT nextval('journal.binaries_journal_id_seq'::regclass);


--
-- Name: binaries_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.binaries_journal_id_seq'::regclass);


--
-- Name: binary_versions journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions ALTER COLUMN journal_id SET DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass);


--
-- Name: binary_versions_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.binary_versions_journal_id_seq'::regclass);


--
-- Name: github_users journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users ALTER COLUMN journal_id SET DEFAULT nextval('journal.github_users_journal_id_seq'::regclass);


--
-- Name: github_users_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.github_users_journal_id_seq'::regclass);


--
-- Name: last_emails journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails ALTER COLUMN journal_id SET DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass);


--
-- Name: last_emails_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.last_emails_journal_id_seq'::regclass);


--
-- Name: libraries journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries ALTER COLUMN journal_id SET DEFAULT nextval('journal.libraries_journal_id_seq'::regclass);


--
-- Name: libraries_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.libraries_journal_id_seq'::regclass);


--
-- Name: library_versions journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions ALTER COLUMN journal_id SET DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass);


--
-- Name: library_versions_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.library_versions_journal_id_seq'::regclass);


--
-- Name: memberships journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships ALTER COLUMN journal_id SET DEFAULT nextval('journal.memberships_journal_id_seq'::regclass);


--
-- Name: memberships_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.memberships_journal_id_seq'::regclass);


--
-- Name: organizations journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations ALTER COLUMN journal_id SET DEFAULT nextval('journal.organizations_journal_id_seq'::regclass);


--
-- Name: organizations_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.organizations_journal_id_seq'::regclass);


--
-- Name: project_binaries journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries ALTER COLUMN journal_id SET DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass);


--
-- Name: project_binaries_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.project_binaries_journal_id_seq'::regclass);


--
-- Name: project_libraries journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries ALTER COLUMN journal_id SET DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass);


--
-- Name: project_libraries_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.project_libraries_journal_id_seq'::regclass);


--
-- Name: projects journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects ALTER COLUMN journal_id SET DEFAULT nextval('journal.projects_journal_id_seq'::regclass);


--
-- Name: projects_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.projects_journal_id_seq'::regclass);


--
-- Name: recommendations journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations ALTER COLUMN journal_id SET DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass);


--
-- Name: recommendations_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.recommendations_journal_id_seq'::regclass);


--
-- Name: resolvers journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers ALTER COLUMN journal_id SET DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass);


--
-- Name: resolvers_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.resolvers_journal_id_seq'::regclass);


--
-- Name: subscriptions journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions ALTER COLUMN journal_id SET DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass);


--
-- Name: subscriptions_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.subscriptions_journal_id_seq'::regclass);


--
-- Name: tokens journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens ALTER COLUMN journal_id SET DEFAULT nextval('journal.tokens_journal_id_seq'::regclass);


--
-- Name: tokens_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.tokens_journal_id_seq'::regclass);


--
-- Name: user_identifiers journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers ALTER COLUMN journal_id SET DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass);


--
-- Name: user_identifiers_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.user_identifiers_journal_id_seq'::regclass);


--
-- Name: user_organizations journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations ALTER COLUMN journal_id SET DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass);


--
-- Name: user_organizations_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.user_organizations_journal_id_seq'::regclass);


--
-- Name: users journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users ALTER COLUMN journal_id SET DEFAULT nextval('journal.users_journal_id_seq'::regclass);


--
-- Name: users_default journal_id; Type: DEFAULT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_default ALTER COLUMN journal_id SET DEFAULT nextval('journal.users_journal_id_seq'::regclass);


--
-- Name: bootstrap_scripts id; Type: DEFAULT; Schema: schema_evolution_manager; Owner: api
--

ALTER TABLE ONLY schema_evolution_manager.bootstrap_scripts ALTER COLUMN id SET DEFAULT nextval('schema_evolution_manager.bootstrap_scripts_id_seq'::regclass);


--
-- Name: scripts id; Type: DEFAULT; Schema: schema_evolution_manager; Owner: api
--

ALTER TABLE ONLY schema_evolution_manager.scripts ALTER COLUMN id SET DEFAULT nextval('schema_evolution_manager.scripts_id_seq'::regclass);


--
-- Name: binaries_default binaries_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_default
    ADD CONSTRAINT binaries_default_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries_p20240901 binaries_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_p20240901
    ADD CONSTRAINT binaries_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries_p20240301 binaries_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_p20240301
    ADD CONSTRAINT binaries_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries_p20240401 binaries_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_p20240401
    ADD CONSTRAINT binaries_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries_p20240501 binaries_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_p20240501
    ADD CONSTRAINT binaries_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries_p20240601 binaries_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_p20240601
    ADD CONSTRAINT binaries_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries_p20240701 binaries_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binaries_p20240701
    ADD CONSTRAINT binaries_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_default binary_versions_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_default
    ADD CONSTRAINT binary_versions_default_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240901 binary_versions_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240901
    ADD CONSTRAINT binary_versions_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240101 binary_versions_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240101
    ADD CONSTRAINT binary_versions_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240201 binary_versions_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240201
    ADD CONSTRAINT binary_versions_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240301 binary_versions_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240301
    ADD CONSTRAINT binary_versions_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240401 binary_versions_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240401
    ADD CONSTRAINT binary_versions_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240501 binary_versions_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240501
    ADD CONSTRAINT binary_versions_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240601 binary_versions_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240601
    ADD CONSTRAINT binary_versions_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240701 binary_versions_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240701
    ADD CONSTRAINT binary_versions_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: binary_versions_p20240801 binary_versions_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.binary_versions_p20240801
    ADD CONSTRAINT binary_versions_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_default github_users_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_default
    ADD CONSTRAINT github_users_default_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_p20240901 github_users_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_p20240901
    ADD CONSTRAINT github_users_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_p20240301 github_users_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_p20240301
    ADD CONSTRAINT github_users_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_p20240401 github_users_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_p20240401
    ADD CONSTRAINT github_users_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_p20240501 github_users_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_p20240501
    ADD CONSTRAINT github_users_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_p20240601 github_users_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_p20240601
    ADD CONSTRAINT github_users_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: github_users_p20240701 github_users_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.github_users_p20240701
    ADD CONSTRAINT github_users_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_default last_emails_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_default
    ADD CONSTRAINT last_emails_default_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240901 last_emails_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240901
    ADD CONSTRAINT last_emails_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240101 last_emails_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240101
    ADD CONSTRAINT last_emails_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240201 last_emails_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240201
    ADD CONSTRAINT last_emails_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240301 last_emails_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240301
    ADD CONSTRAINT last_emails_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240401 last_emails_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240401
    ADD CONSTRAINT last_emails_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240501 last_emails_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240501
    ADD CONSTRAINT last_emails_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240601 last_emails_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240601
    ADD CONSTRAINT last_emails_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240701 last_emails_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240701
    ADD CONSTRAINT last_emails_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: last_emails_p20240801 last_emails_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.last_emails_p20240801
    ADD CONSTRAINT last_emails_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_default libraries_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_default
    ADD CONSTRAINT libraries_default_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240901 libraries_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240901
    ADD CONSTRAINT libraries_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240101 libraries_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240101
    ADD CONSTRAINT libraries_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240201 libraries_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240201
    ADD CONSTRAINT libraries_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240301 libraries_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240301
    ADD CONSTRAINT libraries_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240401 libraries_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240401
    ADD CONSTRAINT libraries_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240501 libraries_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240501
    ADD CONSTRAINT libraries_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240601 libraries_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240601
    ADD CONSTRAINT libraries_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240701 libraries_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240701
    ADD CONSTRAINT libraries_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: libraries_p20240801 libraries_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.libraries_p20240801
    ADD CONSTRAINT libraries_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_default library_versions_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_default
    ADD CONSTRAINT library_versions_default_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240901 library_versions_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240901
    ADD CONSTRAINT library_versions_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240101 library_versions_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240101
    ADD CONSTRAINT library_versions_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240201 library_versions_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240201
    ADD CONSTRAINT library_versions_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240301 library_versions_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240301
    ADD CONSTRAINT library_versions_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240401 library_versions_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240401
    ADD CONSTRAINT library_versions_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240501 library_versions_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240501
    ADD CONSTRAINT library_versions_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240601 library_versions_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240601
    ADD CONSTRAINT library_versions_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240701 library_versions_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240701
    ADD CONSTRAINT library_versions_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: library_versions_p20240801 library_versions_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.library_versions_p20240801
    ADD CONSTRAINT library_versions_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_default memberships_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_default
    ADD CONSTRAINT memberships_default_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240901 memberships_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240901
    ADD CONSTRAINT memberships_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240101 memberships_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240101
    ADD CONSTRAINT memberships_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240201 memberships_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240201
    ADD CONSTRAINT memberships_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240301 memberships_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240301
    ADD CONSTRAINT memberships_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240401 memberships_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240401
    ADD CONSTRAINT memberships_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240501 memberships_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240501
    ADD CONSTRAINT memberships_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240601 memberships_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240601
    ADD CONSTRAINT memberships_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240701 memberships_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240701
    ADD CONSTRAINT memberships_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: memberships_p20240801 memberships_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.memberships_p20240801
    ADD CONSTRAINT memberships_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_default organizations_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_default
    ADD CONSTRAINT organizations_default_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240901 organizations_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240901
    ADD CONSTRAINT organizations_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240101 organizations_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240101
    ADD CONSTRAINT organizations_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240201 organizations_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240201
    ADD CONSTRAINT organizations_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240301 organizations_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240301
    ADD CONSTRAINT organizations_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240401 organizations_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240401
    ADD CONSTRAINT organizations_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240501 organizations_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240501
    ADD CONSTRAINT organizations_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240601 organizations_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240601
    ADD CONSTRAINT organizations_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: organizations_p20240701 organizations_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.organizations_p20240701
    ADD CONSTRAINT organizations_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_default project_binaries_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_default
    ADD CONSTRAINT project_binaries_default_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240901 project_binaries_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240901
    ADD CONSTRAINT project_binaries_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240101 project_binaries_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240101
    ADD CONSTRAINT project_binaries_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240201 project_binaries_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240201
    ADD CONSTRAINT project_binaries_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240301 project_binaries_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240301
    ADD CONSTRAINT project_binaries_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240401 project_binaries_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240401
    ADD CONSTRAINT project_binaries_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240501 project_binaries_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240501
    ADD CONSTRAINT project_binaries_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240601 project_binaries_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240601
    ADD CONSTRAINT project_binaries_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240701 project_binaries_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240701
    ADD CONSTRAINT project_binaries_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: project_binaries_p20240801 project_binaries_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_binaries_p20240801
    ADD CONSTRAINT project_binaries_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_default project_libraries_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_default
    ADD CONSTRAINT project_libraries_default_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240901 project_libraries_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240901
    ADD CONSTRAINT project_libraries_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240101 project_libraries_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240101
    ADD CONSTRAINT project_libraries_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240201 project_libraries_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240201
    ADD CONSTRAINT project_libraries_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240301 project_libraries_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240301
    ADD CONSTRAINT project_libraries_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240401 project_libraries_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240401
    ADD CONSTRAINT project_libraries_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240501 project_libraries_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240501
    ADD CONSTRAINT project_libraries_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240601 project_libraries_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240601
    ADD CONSTRAINT project_libraries_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240701 project_libraries_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240701
    ADD CONSTRAINT project_libraries_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: project_libraries_p20240801 project_libraries_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.project_libraries_p20240801
    ADD CONSTRAINT project_libraries_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_default projects_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_default
    ADD CONSTRAINT projects_default_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240901 projects_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240901
    ADD CONSTRAINT projects_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240101 projects_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240101
    ADD CONSTRAINT projects_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240201 projects_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240201
    ADD CONSTRAINT projects_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240301 projects_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240301
    ADD CONSTRAINT projects_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240401 projects_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240401
    ADD CONSTRAINT projects_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240501 projects_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240501
    ADD CONSTRAINT projects_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240601 projects_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240601
    ADD CONSTRAINT projects_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: projects_p20240701 projects_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.projects_p20240701
    ADD CONSTRAINT projects_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_default recommendations_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_default
    ADD CONSTRAINT recommendations_default_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240901 recommendations_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240901
    ADD CONSTRAINT recommendations_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240101 recommendations_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240101
    ADD CONSTRAINT recommendations_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240201 recommendations_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240201
    ADD CONSTRAINT recommendations_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240301 recommendations_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240301
    ADD CONSTRAINT recommendations_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240401 recommendations_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240401
    ADD CONSTRAINT recommendations_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240501 recommendations_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240501
    ADD CONSTRAINT recommendations_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240601 recommendations_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240601
    ADD CONSTRAINT recommendations_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240701 recommendations_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240701
    ADD CONSTRAINT recommendations_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: recommendations_p20240801 recommendations_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.recommendations_p20240801
    ADD CONSTRAINT recommendations_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_default resolvers_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_default
    ADD CONSTRAINT resolvers_default_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_p20240901 resolvers_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_p20240901
    ADD CONSTRAINT resolvers_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_p20240301 resolvers_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_p20240301
    ADD CONSTRAINT resolvers_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_p20240401 resolvers_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_p20240401
    ADD CONSTRAINT resolvers_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_p20240501 resolvers_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_p20240501
    ADD CONSTRAINT resolvers_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_p20240601 resolvers_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_p20240601
    ADD CONSTRAINT resolvers_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: resolvers_p20240701 resolvers_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.resolvers_p20240701
    ADD CONSTRAINT resolvers_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_default subscriptions_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_default
    ADD CONSTRAINT subscriptions_default_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240901 subscriptions_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240901
    ADD CONSTRAINT subscriptions_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240101 subscriptions_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240101
    ADD CONSTRAINT subscriptions_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240201 subscriptions_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240201
    ADD CONSTRAINT subscriptions_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240301 subscriptions_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240301
    ADD CONSTRAINT subscriptions_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240401 subscriptions_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240401
    ADD CONSTRAINT subscriptions_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240501 subscriptions_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240501
    ADD CONSTRAINT subscriptions_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240601 subscriptions_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240601
    ADD CONSTRAINT subscriptions_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240701 subscriptions_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240701
    ADD CONSTRAINT subscriptions_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: subscriptions_p20240801 subscriptions_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.subscriptions_p20240801
    ADD CONSTRAINT subscriptions_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_default tokens_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_default
    ADD CONSTRAINT tokens_default_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240901 tokens_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240901
    ADD CONSTRAINT tokens_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240101 tokens_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240101
    ADD CONSTRAINT tokens_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240201 tokens_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240201
    ADD CONSTRAINT tokens_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240301 tokens_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240301
    ADD CONSTRAINT tokens_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240401 tokens_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240401
    ADD CONSTRAINT tokens_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240501 tokens_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240501
    ADD CONSTRAINT tokens_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240601 tokens_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240601
    ADD CONSTRAINT tokens_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240701 tokens_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240701
    ADD CONSTRAINT tokens_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: tokens_p20240801 tokens_p2024_08_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.tokens_p20240801
    ADD CONSTRAINT tokens_p2024_08_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_default user_identifiers_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_default
    ADD CONSTRAINT user_identifiers_default_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240901 user_identifiers_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240901
    ADD CONSTRAINT user_identifiers_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240101 user_identifiers_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240101
    ADD CONSTRAINT user_identifiers_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240201 user_identifiers_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240201
    ADD CONSTRAINT user_identifiers_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240301 user_identifiers_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240301
    ADD CONSTRAINT user_identifiers_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240401 user_identifiers_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240401
    ADD CONSTRAINT user_identifiers_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240501 user_identifiers_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240501
    ADD CONSTRAINT user_identifiers_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240601 user_identifiers_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240601
    ADD CONSTRAINT user_identifiers_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: user_identifiers_p20240701 user_identifiers_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_identifiers_p20240701
    ADD CONSTRAINT user_identifiers_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_default user_organizations_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_default
    ADD CONSTRAINT user_organizations_default_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240901 user_organizations_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240901
    ADD CONSTRAINT user_organizations_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240101 user_organizations_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240101
    ADD CONSTRAINT user_organizations_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240201 user_organizations_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240201
    ADD CONSTRAINT user_organizations_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240301 user_organizations_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240301
    ADD CONSTRAINT user_organizations_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240401 user_organizations_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240401
    ADD CONSTRAINT user_organizations_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240501 user_organizations_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240501
    ADD CONSTRAINT user_organizations_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240601 user_organizations_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240601
    ADD CONSTRAINT user_organizations_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: user_organizations_p20240701 user_organizations_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.user_organizations_p20240701
    ADD CONSTRAINT user_organizations_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: users_default users_default_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_default
    ADD CONSTRAINT users_default_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240901 users_p20240901_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240901
    ADD CONSTRAINT users_p20240901_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240101 users_p2024_01_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240101
    ADD CONSTRAINT users_p2024_01_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240201 users_p2024_02_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240201
    ADD CONSTRAINT users_p2024_02_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240301 users_p2024_03_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240301
    ADD CONSTRAINT users_p2024_03_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240401 users_p2024_04_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240401
    ADD CONSTRAINT users_p2024_04_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240501 users_p2024_05_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240501
    ADD CONSTRAINT users_p2024_05_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240601 users_p2024_06_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240601
    ADD CONSTRAINT users_p2024_06_pkey PRIMARY KEY (journal_id);


--
-- Name: users_p20240701 users_p2024_07_pkey; Type: CONSTRAINT; Schema: journal; Owner: api
--

ALTER TABLE ONLY journal.users_p20240701
    ADD CONSTRAINT users_p2024_07_pkey PRIMARY KEY (journal_id);


--
-- Name: part_config part_config_parent_table_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.part_config
    ADD CONSTRAINT part_config_parent_table_pkey PRIMARY KEY (parent_table);


--
-- Name: part_config_sub part_config_sub_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.part_config_sub
    ADD CONSTRAINT part_config_sub_pkey PRIMARY KEY (sub_parent);


--
-- Name: template_journal_binaries template_journal_binaries_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_binaries
    ADD CONSTRAINT template_journal_binaries_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_binary_versions template_journal_binary_versions_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_binary_versions
    ADD CONSTRAINT template_journal_binary_versions_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_github_users template_journal_github_users_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_github_users
    ADD CONSTRAINT template_journal_github_users_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_last_emails template_journal_last_emails_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_last_emails
    ADD CONSTRAINT template_journal_last_emails_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_libraries template_journal_libraries_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_libraries
    ADD CONSTRAINT template_journal_libraries_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_library_versions template_journal_library_versions_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_library_versions
    ADD CONSTRAINT template_journal_library_versions_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_memberships template_journal_memberships_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_memberships
    ADD CONSTRAINT template_journal_memberships_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_organizations template_journal_organizations_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_organizations
    ADD CONSTRAINT template_journal_organizations_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_project_binaries template_journal_project_binaries_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_project_binaries
    ADD CONSTRAINT template_journal_project_binaries_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_project_libraries template_journal_project_libraries_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_project_libraries
    ADD CONSTRAINT template_journal_project_libraries_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_projects template_journal_projects_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_projects
    ADD CONSTRAINT template_journal_projects_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_recommendations template_journal_recommendations_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_recommendations
    ADD CONSTRAINT template_journal_recommendations_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_resolvers template_journal_resolvers_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_resolvers
    ADD CONSTRAINT template_journal_resolvers_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_subscriptions template_journal_subscriptions_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_subscriptions
    ADD CONSTRAINT template_journal_subscriptions_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_tokens template_journal_tokens_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_tokens
    ADD CONSTRAINT template_journal_tokens_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_user_identifiers template_journal_user_identifiers_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_user_identifiers
    ADD CONSTRAINT template_journal_user_identifiers_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_user_organizations template_journal_user_organizations_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_user_organizations
    ADD CONSTRAINT template_journal_user_organizations_pkey PRIMARY KEY (journal_id);


--
-- Name: template_journal_users template_journal_users_pkey; Type: CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.template_journal_users
    ADD CONSTRAINT template_journal_users_pkey PRIMARY KEY (journal_id);


--
-- Name: binaries binaries_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.binaries
    ADD CONSTRAINT binaries_pkey PRIMARY KEY (id);


--
-- Name: binary_versions binary_versions_binary_id_version_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.binary_versions
    ADD CONSTRAINT binary_versions_binary_id_version_key UNIQUE (binary_id, version);


--
-- Name: binary_versions binary_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.binary_versions
    ADD CONSTRAINT binary_versions_pkey PRIMARY KEY (id);


--
-- Name: github_users github_users_github_user_id_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.github_users
    ADD CONSTRAINT github_users_github_user_id_key UNIQUE (github_user_id);


--
-- Name: github_users github_users_login_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.github_users
    ADD CONSTRAINT github_users_login_key UNIQUE (login);


--
-- Name: github_users github_users_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.github_users
    ADD CONSTRAINT github_users_pkey PRIMARY KEY (id);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (id);


--
-- Name: last_emails last_emails_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.last_emails
    ADD CONSTRAINT last_emails_pkey PRIMARY KEY (id);


--
-- Name: last_emails last_emails_user_id_publication_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.last_emails
    ADD CONSTRAINT last_emails_user_id_publication_key UNIQUE (user_id, publication);


--
-- Name: libraries libraries_group_id_artifact_id_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.libraries
    ADD CONSTRAINT libraries_group_id_artifact_id_key UNIQUE (group_id, artifact_id);


--
-- Name: libraries libraries_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.libraries
    ADD CONSTRAINT libraries_pkey PRIMARY KEY (id);


--
-- Name: library_versions library_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.library_versions
    ADD CONSTRAINT library_versions_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_user_id_organization_id_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_user_id_organization_id_key UNIQUE (user_id, organization_id);


--
-- Name: organizations organizations_key_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_key_key UNIQUE (key);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: project_binaries project_binaries_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.project_binaries
    ADD CONSTRAINT project_binaries_pkey PRIMARY KEY (id);


--
-- Name: project_libraries project_libraries_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.project_libraries
    ADD CONSTRAINT project_libraries_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: recommendations recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.recommendations
    ADD CONSTRAINT recommendations_pkey PRIMARY KEY (id);


--
-- Name: recommendations recommendations_project_id_type_object_id_name_from_version_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.recommendations
    ADD CONSTRAINT recommendations_project_id_type_object_id_name_from_version_key UNIQUE (project_id, type, object_id, name, from_version);


--
-- Name: resolvers resolvers_organization_id_uri_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.resolvers
    ADD CONSTRAINT resolvers_organization_id_uri_key UNIQUE (organization_id, uri);


--
-- Name: resolvers resolvers_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.resolvers
    ADD CONSTRAINT resolvers_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_user_id_publication_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_publication_key UNIQUE (user_id, publication);


--
-- Name: syncs syncs_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.syncs
    ADD CONSTRAINT syncs_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: tokens tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_pkey PRIMARY KEY (id);


--
-- Name: tokens tokens_token_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_token_key UNIQUE (token);


--
-- Name: user_identifiers user_identifiers_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_identifiers
    ADD CONSTRAINT user_identifiers_pkey PRIMARY KEY (id);


--
-- Name: user_organizations user_organizations_organization_id_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_organization_id_key UNIQUE (organization_id);


--
-- Name: user_organizations user_organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_pkey PRIMARY KEY (id);


--
-- Name: user_organizations user_organizations_user_id_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_user_id_key UNIQUE (user_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: bootstrap_scripts bootstrap_scripts_filename_un; Type: CONSTRAINT; Schema: schema_evolution_manager; Owner: api
--

ALTER TABLE ONLY schema_evolution_manager.bootstrap_scripts
    ADD CONSTRAINT bootstrap_scripts_filename_un UNIQUE (filename);


--
-- Name: bootstrap_scripts bootstrap_scripts_id_pk; Type: CONSTRAINT; Schema: schema_evolution_manager; Owner: api
--

ALTER TABLE ONLY schema_evolution_manager.bootstrap_scripts
    ADD CONSTRAINT bootstrap_scripts_id_pk PRIMARY KEY (id);


--
-- Name: scripts scripts_filename_un; Type: CONSTRAINT; Schema: schema_evolution_manager; Owner: api
--

ALTER TABLE ONLY schema_evolution_manager.scripts
    ADD CONSTRAINT scripts_filename_un UNIQUE (filename);


--
-- Name: scripts scripts_id_pk; Type: CONSTRAINT; Schema: schema_evolution_manager; Owner: api
--

ALTER TABLE ONLY schema_evolution_manager.scripts
    ADD CONSTRAINT scripts_id_pk PRIMARY KEY (id);


--
-- Name: binaries_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_id_idx ON ONLY journal.binaries USING btree (id);


--
-- Name: binaries_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_default_id_idx ON journal.binaries_default USING btree (id);


--
-- Name: binaries_p20240101_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p20240101_id_idx ON journal.binaries_p20240101 USING btree (id);


--
-- Name: binaries_p20240201_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p20240201_id_idx ON journal.binaries_p20240201 USING btree (id);


--
-- Name: binaries_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p20240801_id_idx ON journal.binaries_p20240801 USING btree (id);


--
-- Name: binaries_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p20240901_id_idx ON journal.binaries_p20240901 USING btree (id);


--
-- Name: binaries_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p2024_03_id_idx ON journal.binaries_p20240301 USING btree (id);


--
-- Name: binaries_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p2024_04_id_idx ON journal.binaries_p20240401 USING btree (id);


--
-- Name: binaries_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p2024_05_id_idx ON journal.binaries_p20240501 USING btree (id);


--
-- Name: binaries_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p2024_06_id_idx ON journal.binaries_p20240601 USING btree (id);


--
-- Name: binaries_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binaries_p2024_07_id_idx ON journal.binaries_p20240701 USING btree (id);


--
-- Name: binary_versions_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_id_idx ON ONLY journal.binary_versions USING btree (id);


--
-- Name: binary_versions_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_default_id_idx ON journal.binary_versions_default USING btree (id);


--
-- Name: binary_versions_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p20240901_id_idx ON journal.binary_versions_p20240901 USING btree (id);


--
-- Name: binary_versions_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_01_id_idx ON journal.binary_versions_p20240101 USING btree (id);


--
-- Name: binary_versions_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_02_id_idx ON journal.binary_versions_p20240201 USING btree (id);


--
-- Name: binary_versions_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_03_id_idx ON journal.binary_versions_p20240301 USING btree (id);


--
-- Name: binary_versions_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_04_id_idx ON journal.binary_versions_p20240401 USING btree (id);


--
-- Name: binary_versions_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_05_id_idx ON journal.binary_versions_p20240501 USING btree (id);


--
-- Name: binary_versions_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_06_id_idx ON journal.binary_versions_p20240601 USING btree (id);


--
-- Name: binary_versions_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_07_id_idx ON journal.binary_versions_p20240701 USING btree (id);


--
-- Name: binary_versions_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX binary_versions_p2024_08_id_idx ON journal.binary_versions_p20240801 USING btree (id);


--
-- Name: github_users_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_id_idx ON ONLY journal.github_users USING btree (id);


--
-- Name: github_users_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_default_id_idx ON journal.github_users_default USING btree (id);


--
-- Name: github_users_p20240101_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p20240101_id_idx ON journal.github_users_p20240101 USING btree (id);


--
-- Name: github_users_p20240201_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p20240201_id_idx ON journal.github_users_p20240201 USING btree (id);


--
-- Name: github_users_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p20240801_id_idx ON journal.github_users_p20240801 USING btree (id);


--
-- Name: github_users_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p20240901_id_idx ON journal.github_users_p20240901 USING btree (id);


--
-- Name: github_users_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p2024_03_id_idx ON journal.github_users_p20240301 USING btree (id);


--
-- Name: github_users_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p2024_04_id_idx ON journal.github_users_p20240401 USING btree (id);


--
-- Name: github_users_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p2024_05_id_idx ON journal.github_users_p20240501 USING btree (id);


--
-- Name: github_users_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p2024_06_id_idx ON journal.github_users_p20240601 USING btree (id);


--
-- Name: github_users_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX github_users_p2024_07_id_idx ON journal.github_users_p20240701 USING btree (id);


--
-- Name: last_emails_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_id_idx ON ONLY journal.last_emails USING btree (id);


--
-- Name: last_emails_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_default_id_idx ON journal.last_emails_default USING btree (id);


--
-- Name: last_emails_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p20240901_id_idx ON journal.last_emails_p20240901 USING btree (id);


--
-- Name: last_emails_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_01_id_idx ON journal.last_emails_p20240101 USING btree (id);


--
-- Name: last_emails_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_02_id_idx ON journal.last_emails_p20240201 USING btree (id);


--
-- Name: last_emails_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_03_id_idx ON journal.last_emails_p20240301 USING btree (id);


--
-- Name: last_emails_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_04_id_idx ON journal.last_emails_p20240401 USING btree (id);


--
-- Name: last_emails_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_05_id_idx ON journal.last_emails_p20240501 USING btree (id);


--
-- Name: last_emails_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_06_id_idx ON journal.last_emails_p20240601 USING btree (id);


--
-- Name: last_emails_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_07_id_idx ON journal.last_emails_p20240701 USING btree (id);


--
-- Name: last_emails_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX last_emails_p2024_08_id_idx ON journal.last_emails_p20240801 USING btree (id);


--
-- Name: libraries_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_id_idx ON ONLY journal.libraries USING btree (id);


--
-- Name: libraries_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_default_id_idx ON journal.libraries_default USING btree (id);


--
-- Name: libraries_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p20240901_id_idx ON journal.libraries_p20240901 USING btree (id);


--
-- Name: libraries_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_01_id_idx ON journal.libraries_p20240101 USING btree (id);


--
-- Name: libraries_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_02_id_idx ON journal.libraries_p20240201 USING btree (id);


--
-- Name: libraries_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_03_id_idx ON journal.libraries_p20240301 USING btree (id);


--
-- Name: libraries_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_04_id_idx ON journal.libraries_p20240401 USING btree (id);


--
-- Name: libraries_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_05_id_idx ON journal.libraries_p20240501 USING btree (id);


--
-- Name: libraries_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_06_id_idx ON journal.libraries_p20240601 USING btree (id);


--
-- Name: libraries_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_07_id_idx ON journal.libraries_p20240701 USING btree (id);


--
-- Name: libraries_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX libraries_p2024_08_id_idx ON journal.libraries_p20240801 USING btree (id);


--
-- Name: library_versions_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_id_idx ON ONLY journal.library_versions USING btree (id);


--
-- Name: library_versions_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_default_id_idx ON journal.library_versions_default USING btree (id);


--
-- Name: library_versions_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p20240901_id_idx ON journal.library_versions_p20240901 USING btree (id);


--
-- Name: library_versions_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_01_id_idx ON journal.library_versions_p20240101 USING btree (id);


--
-- Name: library_versions_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_02_id_idx ON journal.library_versions_p20240201 USING btree (id);


--
-- Name: library_versions_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_03_id_idx ON journal.library_versions_p20240301 USING btree (id);


--
-- Name: library_versions_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_04_id_idx ON journal.library_versions_p20240401 USING btree (id);


--
-- Name: library_versions_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_05_id_idx ON journal.library_versions_p20240501 USING btree (id);


--
-- Name: library_versions_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_06_id_idx ON journal.library_versions_p20240601 USING btree (id);


--
-- Name: library_versions_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_07_id_idx ON journal.library_versions_p20240701 USING btree (id);


--
-- Name: library_versions_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX library_versions_p2024_08_id_idx ON journal.library_versions_p20240801 USING btree (id);


--
-- Name: memberships_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_id_idx ON ONLY journal.memberships USING btree (id);


--
-- Name: memberships_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_default_id_idx ON journal.memberships_default USING btree (id);


--
-- Name: memberships_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p20240901_id_idx ON journal.memberships_p20240901 USING btree (id);


--
-- Name: memberships_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_01_id_idx ON journal.memberships_p20240101 USING btree (id);


--
-- Name: memberships_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_02_id_idx ON journal.memberships_p20240201 USING btree (id);


--
-- Name: memberships_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_03_id_idx ON journal.memberships_p20240301 USING btree (id);


--
-- Name: memberships_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_04_id_idx ON journal.memberships_p20240401 USING btree (id);


--
-- Name: memberships_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_05_id_idx ON journal.memberships_p20240501 USING btree (id);


--
-- Name: memberships_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_06_id_idx ON journal.memberships_p20240601 USING btree (id);


--
-- Name: memberships_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_07_id_idx ON journal.memberships_p20240701 USING btree (id);


--
-- Name: memberships_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX memberships_p2024_08_id_idx ON journal.memberships_p20240801 USING btree (id);


--
-- Name: organizations_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_id_idx ON ONLY journal.organizations USING btree (id);


--
-- Name: organizations_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_default_id_idx ON journal.organizations_default USING btree (id);


--
-- Name: organizations_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p20240801_id_idx ON journal.organizations_p20240801 USING btree (id);


--
-- Name: organizations_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p20240901_id_idx ON journal.organizations_p20240901 USING btree (id);


--
-- Name: organizations_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_01_id_idx ON journal.organizations_p20240101 USING btree (id);


--
-- Name: organizations_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_02_id_idx ON journal.organizations_p20240201 USING btree (id);


--
-- Name: organizations_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_03_id_idx ON journal.organizations_p20240301 USING btree (id);


--
-- Name: organizations_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_04_id_idx ON journal.organizations_p20240401 USING btree (id);


--
-- Name: organizations_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_05_id_idx ON journal.organizations_p20240501 USING btree (id);


--
-- Name: organizations_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_06_id_idx ON journal.organizations_p20240601 USING btree (id);


--
-- Name: organizations_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX organizations_p2024_07_id_idx ON journal.organizations_p20240701 USING btree (id);


--
-- Name: project_binaries_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_id_idx ON ONLY journal.project_binaries USING btree (id);


--
-- Name: project_binaries_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_default_id_idx ON journal.project_binaries_default USING btree (id);


--
-- Name: project_binaries_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p20240901_id_idx ON journal.project_binaries_p20240901 USING btree (id);


--
-- Name: project_binaries_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_01_id_idx ON journal.project_binaries_p20240101 USING btree (id);


--
-- Name: project_binaries_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_02_id_idx ON journal.project_binaries_p20240201 USING btree (id);


--
-- Name: project_binaries_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_03_id_idx ON journal.project_binaries_p20240301 USING btree (id);


--
-- Name: project_binaries_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_04_id_idx ON journal.project_binaries_p20240401 USING btree (id);


--
-- Name: project_binaries_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_05_id_idx ON journal.project_binaries_p20240501 USING btree (id);


--
-- Name: project_binaries_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_06_id_idx ON journal.project_binaries_p20240601 USING btree (id);


--
-- Name: project_binaries_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_07_id_idx ON journal.project_binaries_p20240701 USING btree (id);


--
-- Name: project_binaries_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_binaries_p2024_08_id_idx ON journal.project_binaries_p20240801 USING btree (id);


--
-- Name: project_libraries_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_id_idx ON ONLY journal.project_libraries USING btree (id);


--
-- Name: project_libraries_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_default_id_idx ON journal.project_libraries_default USING btree (id);


--
-- Name: project_libraries_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p20240901_id_idx ON journal.project_libraries_p20240901 USING btree (id);


--
-- Name: project_libraries_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_01_id_idx ON journal.project_libraries_p20240101 USING btree (id);


--
-- Name: project_libraries_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_02_id_idx ON journal.project_libraries_p20240201 USING btree (id);


--
-- Name: project_libraries_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_03_id_idx ON journal.project_libraries_p20240301 USING btree (id);


--
-- Name: project_libraries_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_04_id_idx ON journal.project_libraries_p20240401 USING btree (id);


--
-- Name: project_libraries_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_05_id_idx ON journal.project_libraries_p20240501 USING btree (id);


--
-- Name: project_libraries_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_06_id_idx ON journal.project_libraries_p20240601 USING btree (id);


--
-- Name: project_libraries_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_07_id_idx ON journal.project_libraries_p20240701 USING btree (id);


--
-- Name: project_libraries_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX project_libraries_p2024_08_id_idx ON journal.project_libraries_p20240801 USING btree (id);


--
-- Name: projects_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_id_idx ON ONLY journal.projects USING btree (id);


--
-- Name: projects_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_default_id_idx ON journal.projects_default USING btree (id);


--
-- Name: projects_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p20240801_id_idx ON journal.projects_p20240801 USING btree (id);


--
-- Name: projects_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p20240901_id_idx ON journal.projects_p20240901 USING btree (id);


--
-- Name: projects_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_01_id_idx ON journal.projects_p20240101 USING btree (id);


--
-- Name: projects_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_02_id_idx ON journal.projects_p20240201 USING btree (id);


--
-- Name: projects_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_03_id_idx ON journal.projects_p20240301 USING btree (id);


--
-- Name: projects_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_04_id_idx ON journal.projects_p20240401 USING btree (id);


--
-- Name: projects_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_05_id_idx ON journal.projects_p20240501 USING btree (id);


--
-- Name: projects_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_06_id_idx ON journal.projects_p20240601 USING btree (id);


--
-- Name: projects_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX projects_p2024_07_id_idx ON journal.projects_p20240701 USING btree (id);


--
-- Name: recommendations_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_id_idx ON ONLY journal.recommendations USING btree (id);


--
-- Name: recommendations_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_default_id_idx ON journal.recommendations_default USING btree (id);


--
-- Name: recommendations_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p20240901_id_idx ON journal.recommendations_p20240901 USING btree (id);


--
-- Name: recommendations_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_01_id_idx ON journal.recommendations_p20240101 USING btree (id);


--
-- Name: recommendations_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_02_id_idx ON journal.recommendations_p20240201 USING btree (id);


--
-- Name: recommendations_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_03_id_idx ON journal.recommendations_p20240301 USING btree (id);


--
-- Name: recommendations_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_04_id_idx ON journal.recommendations_p20240401 USING btree (id);


--
-- Name: recommendations_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_05_id_idx ON journal.recommendations_p20240501 USING btree (id);


--
-- Name: recommendations_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_06_id_idx ON journal.recommendations_p20240601 USING btree (id);


--
-- Name: recommendations_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_07_id_idx ON journal.recommendations_p20240701 USING btree (id);


--
-- Name: recommendations_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX recommendations_p2024_08_id_idx ON journal.recommendations_p20240801 USING btree (id);


--
-- Name: resolvers_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_id_idx ON ONLY journal.resolvers USING btree (id);


--
-- Name: resolvers_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_default_id_idx ON journal.resolvers_default USING btree (id);


--
-- Name: resolvers_p20240101_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p20240101_id_idx ON journal.resolvers_p20240101 USING btree (id);


--
-- Name: resolvers_p20240201_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p20240201_id_idx ON journal.resolvers_p20240201 USING btree (id);


--
-- Name: resolvers_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p20240801_id_idx ON journal.resolvers_p20240801 USING btree (id);


--
-- Name: resolvers_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p20240901_id_idx ON journal.resolvers_p20240901 USING btree (id);


--
-- Name: resolvers_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p2024_03_id_idx ON journal.resolvers_p20240301 USING btree (id);


--
-- Name: resolvers_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p2024_04_id_idx ON journal.resolvers_p20240401 USING btree (id);


--
-- Name: resolvers_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p2024_05_id_idx ON journal.resolvers_p20240501 USING btree (id);


--
-- Name: resolvers_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p2024_06_id_idx ON journal.resolvers_p20240601 USING btree (id);


--
-- Name: resolvers_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX resolvers_p2024_07_id_idx ON journal.resolvers_p20240701 USING btree (id);


--
-- Name: subscriptions_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_id_idx ON ONLY journal.subscriptions USING btree (id);


--
-- Name: subscriptions_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_default_id_idx ON journal.subscriptions_default USING btree (id);


--
-- Name: subscriptions_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p20240901_id_idx ON journal.subscriptions_p20240901 USING btree (id);


--
-- Name: subscriptions_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_01_id_idx ON journal.subscriptions_p20240101 USING btree (id);


--
-- Name: subscriptions_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_02_id_idx ON journal.subscriptions_p20240201 USING btree (id);


--
-- Name: subscriptions_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_03_id_idx ON journal.subscriptions_p20240301 USING btree (id);


--
-- Name: subscriptions_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_04_id_idx ON journal.subscriptions_p20240401 USING btree (id);


--
-- Name: subscriptions_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_05_id_idx ON journal.subscriptions_p20240501 USING btree (id);


--
-- Name: subscriptions_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_06_id_idx ON journal.subscriptions_p20240601 USING btree (id);


--
-- Name: subscriptions_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_07_id_idx ON journal.subscriptions_p20240701 USING btree (id);


--
-- Name: subscriptions_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX subscriptions_p2024_08_id_idx ON journal.subscriptions_p20240801 USING btree (id);


--
-- Name: tokens_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_id_idx ON ONLY journal.tokens USING btree (id);


--
-- Name: tokens_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_default_id_idx ON journal.tokens_default USING btree (id);


--
-- Name: tokens_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p20240901_id_idx ON journal.tokens_p20240901 USING btree (id);


--
-- Name: tokens_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_01_id_idx ON journal.tokens_p20240101 USING btree (id);


--
-- Name: tokens_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_02_id_idx ON journal.tokens_p20240201 USING btree (id);


--
-- Name: tokens_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_03_id_idx ON journal.tokens_p20240301 USING btree (id);


--
-- Name: tokens_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_04_id_idx ON journal.tokens_p20240401 USING btree (id);


--
-- Name: tokens_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_05_id_idx ON journal.tokens_p20240501 USING btree (id);


--
-- Name: tokens_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_06_id_idx ON journal.tokens_p20240601 USING btree (id);


--
-- Name: tokens_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_07_id_idx ON journal.tokens_p20240701 USING btree (id);


--
-- Name: tokens_p2024_08_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX tokens_p2024_08_id_idx ON journal.tokens_p20240801 USING btree (id);


--
-- Name: user_identifiers_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_id_idx ON ONLY journal.user_identifiers USING btree (id);


--
-- Name: user_identifiers_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_default_id_idx ON journal.user_identifiers_default USING btree (id);


--
-- Name: user_identifiers_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p20240801_id_idx ON journal.user_identifiers_p20240801 USING btree (id);


--
-- Name: user_identifiers_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p20240901_id_idx ON journal.user_identifiers_p20240901 USING btree (id);


--
-- Name: user_identifiers_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_01_id_idx ON journal.user_identifiers_p20240101 USING btree (id);


--
-- Name: user_identifiers_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_02_id_idx ON journal.user_identifiers_p20240201 USING btree (id);


--
-- Name: user_identifiers_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_03_id_idx ON journal.user_identifiers_p20240301 USING btree (id);


--
-- Name: user_identifiers_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_04_id_idx ON journal.user_identifiers_p20240401 USING btree (id);


--
-- Name: user_identifiers_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_05_id_idx ON journal.user_identifiers_p20240501 USING btree (id);


--
-- Name: user_identifiers_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_06_id_idx ON journal.user_identifiers_p20240601 USING btree (id);


--
-- Name: user_identifiers_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_identifiers_p2024_07_id_idx ON journal.user_identifiers_p20240701 USING btree (id);


--
-- Name: user_organizations_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_id_idx ON ONLY journal.user_organizations USING btree (id);


--
-- Name: user_organizations_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_default_id_idx ON journal.user_organizations_default USING btree (id);


--
-- Name: user_organizations_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p20240801_id_idx ON journal.user_organizations_p20240801 USING btree (id);


--
-- Name: user_organizations_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p20240901_id_idx ON journal.user_organizations_p20240901 USING btree (id);


--
-- Name: user_organizations_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_01_id_idx ON journal.user_organizations_p20240101 USING btree (id);


--
-- Name: user_organizations_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_02_id_idx ON journal.user_organizations_p20240201 USING btree (id);


--
-- Name: user_organizations_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_03_id_idx ON journal.user_organizations_p20240301 USING btree (id);


--
-- Name: user_organizations_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_04_id_idx ON journal.user_organizations_p20240401 USING btree (id);


--
-- Name: user_organizations_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_05_id_idx ON journal.user_organizations_p20240501 USING btree (id);


--
-- Name: user_organizations_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_06_id_idx ON journal.user_organizations_p20240601 USING btree (id);


--
-- Name: user_organizations_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX user_organizations_p2024_07_id_idx ON journal.user_organizations_p20240701 USING btree (id);


--
-- Name: users_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_id_idx ON ONLY journal.users USING btree (id);


--
-- Name: users_default_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_default_id_idx ON journal.users_default USING btree (id);


--
-- Name: users_p20240801_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p20240801_id_idx ON journal.users_p20240801 USING btree (id);


--
-- Name: users_p20240901_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p20240901_id_idx ON journal.users_p20240901 USING btree (id);


--
-- Name: users_p2024_01_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_01_id_idx ON journal.users_p20240101 USING btree (id);


--
-- Name: users_p2024_02_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_02_id_idx ON journal.users_p20240201 USING btree (id);


--
-- Name: users_p2024_03_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_03_id_idx ON journal.users_p20240301 USING btree (id);


--
-- Name: users_p2024_04_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_04_id_idx ON journal.users_p20240401 USING btree (id);


--
-- Name: users_p2024_05_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_05_id_idx ON journal.users_p20240501 USING btree (id);


--
-- Name: users_p2024_06_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_06_id_idx ON journal.users_p20240601 USING btree (id);


--
-- Name: users_p2024_07_id_idx; Type: INDEX; Schema: journal; Owner: api
--

CREATE INDEX users_p2024_07_id_idx ON journal.users_p20240701 USING btree (id);


--
-- Name: part_config_type_idx; Type: INDEX; Schema: partman5; Owner: api
--

CREATE INDEX part_config_type_idx ON partman5.part_config USING btree (partition_type);


--
-- Name: binaries_lower_name_un_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX binaries_lower_name_un_idx ON public.binaries USING btree (lower(name));


--
-- Name: binaries_organization_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX binaries_organization_id_idx ON public.binaries USING btree (organization_id);


--
-- Name: github_users_user_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX github_users_user_id_idx ON public.github_users USING btree (user_id);


--
-- Name: items_object_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX items_object_id_idx ON public.items USING btree (object_id);


--
-- Name: items_organization_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX items_organization_id_idx ON public.items USING btree (organization_id);


--
-- Name: libraries_artifact_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX libraries_artifact_id_idx ON public.libraries USING btree (artifact_id);


--
-- Name: libraries_organization_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX libraries_organization_id_idx ON public.libraries USING btree (organization_id);


--
-- Name: libraries_resolver_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX libraries_resolver_id_idx ON public.libraries USING btree (resolver_id);


--
-- Name: library_versions_library_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX library_versions_library_id_idx ON public.library_versions USING btree (library_id);


--
-- Name: library_versions_library_id_lower_version_lower_cross_build_ver; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX library_versions_library_id_lower_version_lower_cross_build_ver ON public.library_versions USING btree (library_id, lower(version), lower(cross_build_version)) WHERE (cross_build_version IS NOT NULL);


--
-- Name: library_versions_library_id_lower_version_not_cross_built_un_id; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX library_versions_library_id_lower_version_not_cross_built_un_id ON public.library_versions USING btree (library_id, lower(version)) WHERE (cross_build_version IS NULL);


--
-- Name: memberships_organization_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX memberships_organization_id_idx ON public.memberships USING btree (organization_id);


--
-- Name: organizations_user_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX organizations_user_id_idx ON public.organizations USING btree (user_id);


--
-- Name: project_binaries_binary_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_binaries_binary_id_idx ON public.project_binaries USING btree (binary_id);


--
-- Name: project_binaries_lower_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_binaries_lower_idx ON public.project_binaries USING btree (lower(name));


--
-- Name: project_binaries_project_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_binaries_project_id_idx ON public.project_binaries USING btree (project_id);


--
-- Name: project_binaries_project_id_lower_name_version_not_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX project_binaries_project_id_lower_name_version_not_idx ON public.project_binaries USING btree (project_id, lower(name), version);


--
-- Name: project_libraries_artifact_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_libraries_artifact_id_idx ON public.project_libraries USING btree (artifact_id);


--
-- Name: project_libraries_group_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_libraries_group_id_idx ON public.project_libraries USING btree (group_id);


--
-- Name: project_libraries_library_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_libraries_library_id_idx ON public.project_libraries USING btree (library_id);


--
-- Name: project_libraries_project_id_group_id_artifact_id_version_cross; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX project_libraries_project_id_group_id_artifact_id_version_cross ON public.project_libraries USING btree (project_id, group_id, artifact_id, version, cross_build_version) WHERE (cross_build_version IS NOT NULL);


--
-- Name: project_libraries_project_id_group_id_artifact_id_version_no_cr; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX project_libraries_project_id_group_id_artifact_id_version_no_cr ON public.project_libraries USING btree (project_id, group_id, artifact_id, version) WHERE (cross_build_version IS NULL);


--
-- Name: project_libraries_project_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_libraries_project_id_idx ON public.project_libraries USING btree (project_id);


--
-- Name: project_libraries_version_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX project_libraries_version_idx ON public.project_libraries USING btree (version);


--
-- Name: projects_organization_scms_lower_name_un_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX projects_organization_scms_lower_name_un_idx ON public.projects USING btree (organization_id, scms, lower(name));


--
-- Name: projects_user_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX projects_user_id_idx ON public.projects USING btree (user_id);


--
-- Name: recommendations_object_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX recommendations_object_id_idx ON public.recommendations USING btree (object_id);


--
-- Name: resolvers_public_position_un_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX resolvers_public_position_un_idx ON public.resolvers USING btree ("position") WHERE (visibility = 'public'::text);


--
-- Name: resolvers_public_uri_un_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX resolvers_public_uri_un_idx ON public.resolvers USING btree (uri) WHERE (visibility = 'public'::text);


--
-- Name: syncs_object_id_event_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX syncs_object_id_event_idx ON public.syncs USING btree (object_id, event);


--
-- Name: syncs_type_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX syncs_type_idx ON public.syncs USING btree (type);


--
-- Name: tasks_data_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX tasks_data_idx ON public.tasks USING btree (data) WHERE (processed_at IS NULL);


--
-- Name: tasks_num_attempts_processed_at_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX tasks_num_attempts_processed_at_idx ON public.tasks USING btree (priority, num_attempts, created_at) WHERE (processed_at IS NULL);


--
-- Name: tokens_user_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX tokens_user_id_idx ON public.tokens USING btree (user_id);


--
-- Name: user_identifiers_user_id_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE INDEX user_identifiers_user_id_idx ON public.user_identifiers USING btree (user_id);


--
-- Name: user_identifiers_value_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX user_identifiers_value_idx ON public.user_identifiers USING btree (value);


--
-- Name: users_lower_email_un_idx; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX users_lower_email_un_idx ON public.users USING btree (lower(email));


--
-- Name: binaries_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_default_id_idx;


--
-- Name: binaries_p20240101_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p20240101_id_idx;


--
-- Name: binaries_p20240201_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p20240201_id_idx;


--
-- Name: binaries_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p20240801_id_idx;


--
-- Name: binaries_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p20240901_id_idx;


--
-- Name: binaries_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p2024_03_id_idx;


--
-- Name: binaries_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p2024_04_id_idx;


--
-- Name: binaries_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p2024_05_id_idx;


--
-- Name: binaries_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p2024_06_id_idx;


--
-- Name: binaries_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binaries_id_idx ATTACH PARTITION journal.binaries_p2024_07_id_idx;


--
-- Name: binary_versions_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_default_id_idx;


--
-- Name: binary_versions_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p20240901_id_idx;


--
-- Name: binary_versions_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_01_id_idx;


--
-- Name: binary_versions_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_02_id_idx;


--
-- Name: binary_versions_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_03_id_idx;


--
-- Name: binary_versions_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_04_id_idx;


--
-- Name: binary_versions_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_05_id_idx;


--
-- Name: binary_versions_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_06_id_idx;


--
-- Name: binary_versions_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_07_id_idx;


--
-- Name: binary_versions_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.binary_versions_id_idx ATTACH PARTITION journal.binary_versions_p2024_08_id_idx;


--
-- Name: github_users_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_default_id_idx;


--
-- Name: github_users_p20240101_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p20240101_id_idx;


--
-- Name: github_users_p20240201_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p20240201_id_idx;


--
-- Name: github_users_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p20240801_id_idx;


--
-- Name: github_users_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p20240901_id_idx;


--
-- Name: github_users_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p2024_03_id_idx;


--
-- Name: github_users_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p2024_04_id_idx;


--
-- Name: github_users_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p2024_05_id_idx;


--
-- Name: github_users_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p2024_06_id_idx;


--
-- Name: github_users_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.github_users_id_idx ATTACH PARTITION journal.github_users_p2024_07_id_idx;


--
-- Name: last_emails_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_default_id_idx;


--
-- Name: last_emails_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p20240901_id_idx;


--
-- Name: last_emails_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_01_id_idx;


--
-- Name: last_emails_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_02_id_idx;


--
-- Name: last_emails_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_03_id_idx;


--
-- Name: last_emails_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_04_id_idx;


--
-- Name: last_emails_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_05_id_idx;


--
-- Name: last_emails_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_06_id_idx;


--
-- Name: last_emails_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_07_id_idx;


--
-- Name: last_emails_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.last_emails_id_idx ATTACH PARTITION journal.last_emails_p2024_08_id_idx;


--
-- Name: libraries_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_default_id_idx;


--
-- Name: libraries_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p20240901_id_idx;


--
-- Name: libraries_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_01_id_idx;


--
-- Name: libraries_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_02_id_idx;


--
-- Name: libraries_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_03_id_idx;


--
-- Name: libraries_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_04_id_idx;


--
-- Name: libraries_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_05_id_idx;


--
-- Name: libraries_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_06_id_idx;


--
-- Name: libraries_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_07_id_idx;


--
-- Name: libraries_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.libraries_id_idx ATTACH PARTITION journal.libraries_p2024_08_id_idx;


--
-- Name: library_versions_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_default_id_idx;


--
-- Name: library_versions_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p20240901_id_idx;


--
-- Name: library_versions_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_01_id_idx;


--
-- Name: library_versions_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_02_id_idx;


--
-- Name: library_versions_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_03_id_idx;


--
-- Name: library_versions_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_04_id_idx;


--
-- Name: library_versions_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_05_id_idx;


--
-- Name: library_versions_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_06_id_idx;


--
-- Name: library_versions_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_07_id_idx;


--
-- Name: library_versions_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.library_versions_id_idx ATTACH PARTITION journal.library_versions_p2024_08_id_idx;


--
-- Name: memberships_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_default_id_idx;


--
-- Name: memberships_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p20240901_id_idx;


--
-- Name: memberships_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_01_id_idx;


--
-- Name: memberships_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_02_id_idx;


--
-- Name: memberships_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_03_id_idx;


--
-- Name: memberships_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_04_id_idx;


--
-- Name: memberships_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_05_id_idx;


--
-- Name: memberships_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_06_id_idx;


--
-- Name: memberships_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_07_id_idx;


--
-- Name: memberships_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.memberships_id_idx ATTACH PARTITION journal.memberships_p2024_08_id_idx;


--
-- Name: organizations_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_default_id_idx;


--
-- Name: organizations_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p20240801_id_idx;


--
-- Name: organizations_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p20240901_id_idx;


--
-- Name: organizations_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_01_id_idx;


--
-- Name: organizations_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_02_id_idx;


--
-- Name: organizations_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_03_id_idx;


--
-- Name: organizations_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_04_id_idx;


--
-- Name: organizations_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_05_id_idx;


--
-- Name: organizations_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_06_id_idx;


--
-- Name: organizations_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.organizations_id_idx ATTACH PARTITION journal.organizations_p2024_07_id_idx;


--
-- Name: project_binaries_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_default_id_idx;


--
-- Name: project_binaries_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p20240901_id_idx;


--
-- Name: project_binaries_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_01_id_idx;


--
-- Name: project_binaries_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_02_id_idx;


--
-- Name: project_binaries_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_03_id_idx;


--
-- Name: project_binaries_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_04_id_idx;


--
-- Name: project_binaries_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_05_id_idx;


--
-- Name: project_binaries_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_06_id_idx;


--
-- Name: project_binaries_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_07_id_idx;


--
-- Name: project_binaries_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_binaries_id_idx ATTACH PARTITION journal.project_binaries_p2024_08_id_idx;


--
-- Name: project_libraries_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_default_id_idx;


--
-- Name: project_libraries_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p20240901_id_idx;


--
-- Name: project_libraries_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_01_id_idx;


--
-- Name: project_libraries_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_02_id_idx;


--
-- Name: project_libraries_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_03_id_idx;


--
-- Name: project_libraries_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_04_id_idx;


--
-- Name: project_libraries_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_05_id_idx;


--
-- Name: project_libraries_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_06_id_idx;


--
-- Name: project_libraries_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_07_id_idx;


--
-- Name: project_libraries_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.project_libraries_id_idx ATTACH PARTITION journal.project_libraries_p2024_08_id_idx;


--
-- Name: projects_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_default_id_idx;


--
-- Name: projects_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p20240801_id_idx;


--
-- Name: projects_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p20240901_id_idx;


--
-- Name: projects_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_01_id_idx;


--
-- Name: projects_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_02_id_idx;


--
-- Name: projects_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_03_id_idx;


--
-- Name: projects_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_04_id_idx;


--
-- Name: projects_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_05_id_idx;


--
-- Name: projects_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_06_id_idx;


--
-- Name: projects_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.projects_id_idx ATTACH PARTITION journal.projects_p2024_07_id_idx;


--
-- Name: recommendations_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_default_id_idx;


--
-- Name: recommendations_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p20240901_id_idx;


--
-- Name: recommendations_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_01_id_idx;


--
-- Name: recommendations_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_02_id_idx;


--
-- Name: recommendations_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_03_id_idx;


--
-- Name: recommendations_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_04_id_idx;


--
-- Name: recommendations_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_05_id_idx;


--
-- Name: recommendations_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_06_id_idx;


--
-- Name: recommendations_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_07_id_idx;


--
-- Name: recommendations_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.recommendations_id_idx ATTACH PARTITION journal.recommendations_p2024_08_id_idx;


--
-- Name: resolvers_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_default_id_idx;


--
-- Name: resolvers_p20240101_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p20240101_id_idx;


--
-- Name: resolvers_p20240201_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p20240201_id_idx;


--
-- Name: resolvers_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p20240801_id_idx;


--
-- Name: resolvers_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p20240901_id_idx;


--
-- Name: resolvers_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p2024_03_id_idx;


--
-- Name: resolvers_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p2024_04_id_idx;


--
-- Name: resolvers_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p2024_05_id_idx;


--
-- Name: resolvers_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p2024_06_id_idx;


--
-- Name: resolvers_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.resolvers_id_idx ATTACH PARTITION journal.resolvers_p2024_07_id_idx;


--
-- Name: subscriptions_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_default_id_idx;


--
-- Name: subscriptions_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p20240901_id_idx;


--
-- Name: subscriptions_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_01_id_idx;


--
-- Name: subscriptions_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_02_id_idx;


--
-- Name: subscriptions_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_03_id_idx;


--
-- Name: subscriptions_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_04_id_idx;


--
-- Name: subscriptions_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_05_id_idx;


--
-- Name: subscriptions_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_06_id_idx;


--
-- Name: subscriptions_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_07_id_idx;


--
-- Name: subscriptions_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.subscriptions_id_idx ATTACH PARTITION journal.subscriptions_p2024_08_id_idx;


--
-- Name: tokens_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_default_id_idx;


--
-- Name: tokens_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p20240901_id_idx;


--
-- Name: tokens_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_01_id_idx;


--
-- Name: tokens_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_02_id_idx;


--
-- Name: tokens_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_03_id_idx;


--
-- Name: tokens_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_04_id_idx;


--
-- Name: tokens_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_05_id_idx;


--
-- Name: tokens_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_06_id_idx;


--
-- Name: tokens_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_07_id_idx;


--
-- Name: tokens_p2024_08_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.tokens_id_idx ATTACH PARTITION journal.tokens_p2024_08_id_idx;


--
-- Name: user_identifiers_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_default_id_idx;


--
-- Name: user_identifiers_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p20240801_id_idx;


--
-- Name: user_identifiers_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p20240901_id_idx;


--
-- Name: user_identifiers_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_01_id_idx;


--
-- Name: user_identifiers_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_02_id_idx;


--
-- Name: user_identifiers_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_03_id_idx;


--
-- Name: user_identifiers_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_04_id_idx;


--
-- Name: user_identifiers_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_05_id_idx;


--
-- Name: user_identifiers_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_06_id_idx;


--
-- Name: user_identifiers_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_identifiers_id_idx ATTACH PARTITION journal.user_identifiers_p2024_07_id_idx;


--
-- Name: user_organizations_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_default_id_idx;


--
-- Name: user_organizations_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p20240801_id_idx;


--
-- Name: user_organizations_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p20240901_id_idx;


--
-- Name: user_organizations_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_01_id_idx;


--
-- Name: user_organizations_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_02_id_idx;


--
-- Name: user_organizations_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_03_id_idx;


--
-- Name: user_organizations_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_04_id_idx;


--
-- Name: user_organizations_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_05_id_idx;


--
-- Name: user_organizations_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_06_id_idx;


--
-- Name: user_organizations_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.user_organizations_id_idx ATTACH PARTITION journal.user_organizations_p2024_07_id_idx;


--
-- Name: users_default_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_default_id_idx;


--
-- Name: users_p20240801_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p20240801_id_idx;


--
-- Name: users_p20240901_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p20240901_id_idx;


--
-- Name: users_p2024_01_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_01_id_idx;


--
-- Name: users_p2024_02_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_02_id_idx;


--
-- Name: users_p2024_03_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_03_id_idx;


--
-- Name: users_p2024_04_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_04_id_idx;


--
-- Name: users_p2024_05_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_05_id_idx;


--
-- Name: users_p2024_06_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_06_id_idx;


--
-- Name: users_p2024_07_id_idx; Type: INDEX ATTACH; Schema: journal; Owner: api
--

ALTER INDEX journal.users_id_idx ATTACH PARTITION journal.users_p2024_07_id_idx;


--
-- Name: binaries binaries_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER binaries_prevent_delete_trigger BEFORE DELETE ON journal.binaries FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: binaries binaries_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER binaries_prevent_updaate_trigger BEFORE UPDATE ON journal.binaries FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: binary_versions binary_versions_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER binary_versions_prevent_delete_trigger BEFORE DELETE ON journal.binary_versions FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: binary_versions binary_versions_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER binary_versions_prevent_updaate_trigger BEFORE UPDATE ON journal.binary_versions FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: github_users github_users_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER github_users_prevent_delete_trigger BEFORE DELETE ON journal.github_users FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: github_users github_users_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER github_users_prevent_updaate_trigger BEFORE UPDATE ON journal.github_users FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: last_emails last_emails_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER last_emails_prevent_delete_trigger BEFORE DELETE ON journal.last_emails FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: last_emails last_emails_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER last_emails_prevent_updaate_trigger BEFORE UPDATE ON journal.last_emails FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: libraries libraries_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER libraries_prevent_delete_trigger BEFORE DELETE ON journal.libraries FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: libraries libraries_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER libraries_prevent_updaate_trigger BEFORE UPDATE ON journal.libraries FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: library_versions library_versions_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER library_versions_prevent_delete_trigger BEFORE DELETE ON journal.library_versions FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: library_versions library_versions_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER library_versions_prevent_updaate_trigger BEFORE UPDATE ON journal.library_versions FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: memberships memberships_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER memberships_prevent_delete_trigger BEFORE DELETE ON journal.memberships FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: memberships memberships_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER memberships_prevent_updaate_trigger BEFORE UPDATE ON journal.memberships FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: organizations organizations_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER organizations_prevent_delete_trigger BEFORE DELETE ON journal.organizations FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: organizations organizations_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER organizations_prevent_updaate_trigger BEFORE UPDATE ON journal.organizations FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: project_binaries project_binaries_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER project_binaries_prevent_delete_trigger BEFORE DELETE ON journal.project_binaries FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: project_binaries project_binaries_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER project_binaries_prevent_updaate_trigger BEFORE UPDATE ON journal.project_binaries FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: project_libraries project_libraries_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER project_libraries_prevent_delete_trigger BEFORE DELETE ON journal.project_libraries FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: project_libraries project_libraries_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER project_libraries_prevent_updaate_trigger BEFORE UPDATE ON journal.project_libraries FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: projects projects_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER projects_prevent_delete_trigger BEFORE DELETE ON journal.projects FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: projects projects_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER projects_prevent_updaate_trigger BEFORE UPDATE ON journal.projects FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: recommendations recommendations_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER recommendations_prevent_delete_trigger BEFORE DELETE ON journal.recommendations FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: recommendations recommendations_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER recommendations_prevent_updaate_trigger BEFORE UPDATE ON journal.recommendations FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: resolvers resolvers_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER resolvers_prevent_delete_trigger BEFORE DELETE ON journal.resolvers FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: resolvers resolvers_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER resolvers_prevent_updaate_trigger BEFORE UPDATE ON journal.resolvers FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: subscriptions subscriptions_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER subscriptions_prevent_delete_trigger BEFORE DELETE ON journal.subscriptions FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: subscriptions subscriptions_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER subscriptions_prevent_updaate_trigger BEFORE UPDATE ON journal.subscriptions FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: tokens tokens_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER tokens_prevent_delete_trigger BEFORE DELETE ON journal.tokens FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: tokens tokens_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER tokens_prevent_updaate_trigger BEFORE UPDATE ON journal.tokens FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: user_identifiers user_identifiers_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER user_identifiers_prevent_delete_trigger BEFORE DELETE ON journal.user_identifiers FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: user_identifiers user_identifiers_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER user_identifiers_prevent_updaate_trigger BEFORE UPDATE ON journal.user_identifiers FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: user_organizations user_organizations_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER user_organizations_prevent_delete_trigger BEFORE DELETE ON journal.user_organizations FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: user_organizations user_organizations_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER user_organizations_prevent_updaate_trigger BEFORE UPDATE ON journal.user_organizations FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: users users_prevent_delete_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER users_prevent_delete_trigger BEFORE DELETE ON journal.users FOR EACH ROW EXECUTE FUNCTION journal.prevent_delete();


--
-- Name: users users_prevent_updaate_trigger; Type: TRIGGER; Schema: journal; Owner: api
--

CREATE TRIGGER users_prevent_updaate_trigger BEFORE UPDATE ON journal.users FOR EACH ROW EXECUTE FUNCTION journal.prevent_update();


--
-- Name: binaries binaries_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER binaries_journal_delete_trigger AFTER DELETE ON public.binaries FOR EACH ROW EXECUTE FUNCTION journal.binaries_delete();


--
-- Name: binaries binaries_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER binaries_journal_insert_trigger AFTER INSERT OR UPDATE ON public.binaries FOR EACH ROW EXECUTE FUNCTION journal.binaries_insert();


--
-- Name: binary_versions binary_versions_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER binary_versions_journal_delete_trigger AFTER DELETE ON public.binary_versions FOR EACH ROW EXECUTE FUNCTION journal.binary_versions_delete();


--
-- Name: binary_versions binary_versions_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER binary_versions_journal_insert_trigger AFTER INSERT OR UPDATE ON public.binary_versions FOR EACH ROW EXECUTE FUNCTION journal.binary_versions_insert();


--
-- Name: github_users github_users_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER github_users_journal_delete_trigger AFTER DELETE ON public.github_users FOR EACH ROW EXECUTE FUNCTION journal.github_users_delete();


--
-- Name: github_users github_users_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER github_users_journal_insert_trigger AFTER INSERT OR UPDATE ON public.github_users FOR EACH ROW EXECUTE FUNCTION journal.github_users_insert();


--
-- Name: items items_updated_at_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER items_updated_at_trigger BEFORE UPDATE ON public.items FOR EACH ROW EXECUTE FUNCTION schema_evolution_manager.set_updated_at_trigger_function();


--
-- Name: last_emails last_emails_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER last_emails_journal_delete_trigger AFTER DELETE ON public.last_emails FOR EACH ROW EXECUTE FUNCTION journal.last_emails_delete();


--
-- Name: last_emails last_emails_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER last_emails_journal_insert_trigger AFTER INSERT OR UPDATE ON public.last_emails FOR EACH ROW EXECUTE FUNCTION journal.last_emails_insert();


--
-- Name: libraries libraries_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER libraries_journal_delete_trigger AFTER DELETE ON public.libraries FOR EACH ROW EXECUTE FUNCTION journal.libraries_delete();


--
-- Name: libraries libraries_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER libraries_journal_insert_trigger AFTER INSERT OR UPDATE ON public.libraries FOR EACH ROW EXECUTE FUNCTION journal.libraries_insert();


--
-- Name: library_versions library_versions_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER library_versions_journal_delete_trigger AFTER DELETE ON public.library_versions FOR EACH ROW EXECUTE FUNCTION journal.library_versions_delete();


--
-- Name: library_versions library_versions_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER library_versions_journal_insert_trigger AFTER INSERT OR UPDATE ON public.library_versions FOR EACH ROW EXECUTE FUNCTION journal.library_versions_insert();


--
-- Name: memberships memberships_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER memberships_journal_delete_trigger AFTER DELETE ON public.memberships FOR EACH ROW EXECUTE FUNCTION journal.memberships_delete();


--
-- Name: memberships memberships_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER memberships_journal_insert_trigger AFTER INSERT OR UPDATE ON public.memberships FOR EACH ROW EXECUTE FUNCTION journal.memberships_insert();


--
-- Name: organizations organizations_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER organizations_journal_delete_trigger AFTER DELETE ON public.organizations FOR EACH ROW EXECUTE FUNCTION journal.organizations_delete();


--
-- Name: organizations organizations_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER organizations_journal_insert_trigger AFTER INSERT OR UPDATE ON public.organizations FOR EACH ROW EXECUTE FUNCTION journal.organizations_insert();


--
-- Name: project_binaries project_binaries_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER project_binaries_journal_delete_trigger AFTER DELETE ON public.project_binaries FOR EACH ROW EXECUTE FUNCTION journal.project_binaries_delete();


--
-- Name: project_binaries project_binaries_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER project_binaries_journal_insert_trigger AFTER INSERT OR UPDATE ON public.project_binaries FOR EACH ROW EXECUTE FUNCTION journal.project_binaries_insert();


--
-- Name: project_libraries project_libraries_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER project_libraries_journal_delete_trigger AFTER DELETE ON public.project_libraries FOR EACH ROW EXECUTE FUNCTION journal.project_libraries_delete();


--
-- Name: project_libraries project_libraries_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER project_libraries_journal_insert_trigger AFTER INSERT OR UPDATE ON public.project_libraries FOR EACH ROW EXECUTE FUNCTION journal.project_libraries_insert();


--
-- Name: project_libraries project_libraries_updated_at_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER project_libraries_updated_at_trigger BEFORE UPDATE ON public.project_libraries FOR EACH ROW EXECUTE FUNCTION schema_evolution_manager.set_updated_at_trigger_function();


--
-- Name: projects projects_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER projects_journal_delete_trigger AFTER DELETE ON public.projects FOR EACH ROW EXECUTE FUNCTION journal.projects_delete();


--
-- Name: projects projects_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER projects_journal_insert_trigger AFTER INSERT OR UPDATE ON public.projects FOR EACH ROW EXECUTE FUNCTION journal.projects_insert();


--
-- Name: recommendations recommendations_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER recommendations_journal_delete_trigger AFTER DELETE ON public.recommendations FOR EACH ROW EXECUTE FUNCTION journal.recommendations_delete();


--
-- Name: recommendations recommendations_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER recommendations_journal_insert_trigger AFTER INSERT OR UPDATE ON public.recommendations FOR EACH ROW EXECUTE FUNCTION journal.recommendations_insert();


--
-- Name: resolvers resolvers_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER resolvers_journal_delete_trigger AFTER DELETE ON public.resolvers FOR EACH ROW EXECUTE FUNCTION journal.resolvers_delete();


--
-- Name: resolvers resolvers_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER resolvers_journal_insert_trigger AFTER INSERT OR UPDATE ON public.resolvers FOR EACH ROW EXECUTE FUNCTION journal.resolvers_insert();


--
-- Name: subscriptions subscriptions_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER subscriptions_journal_delete_trigger AFTER DELETE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION journal.subscriptions_delete();


--
-- Name: subscriptions subscriptions_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER subscriptions_journal_insert_trigger AFTER INSERT OR UPDATE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION journal.subscriptions_insert();


--
-- Name: tasks tasks_updated_at_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER tasks_updated_at_trigger BEFORE UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION schema_evolution_manager.set_updated_at_trigger_function();


--
-- Name: tokens tokens_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER tokens_journal_delete_trigger AFTER DELETE ON public.tokens FOR EACH ROW EXECUTE FUNCTION journal.tokens_delete();


--
-- Name: tokens tokens_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER tokens_journal_insert_trigger AFTER INSERT OR UPDATE ON public.tokens FOR EACH ROW EXECUTE FUNCTION journal.tokens_insert();


--
-- Name: user_identifiers user_identifiers_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER user_identifiers_journal_delete_trigger AFTER DELETE ON public.user_identifiers FOR EACH ROW EXECUTE FUNCTION journal.user_identifiers_delete();


--
-- Name: user_identifiers user_identifiers_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER user_identifiers_journal_insert_trigger AFTER INSERT OR UPDATE ON public.user_identifiers FOR EACH ROW EXECUTE FUNCTION journal.user_identifiers_insert();


--
-- Name: user_organizations user_organizations_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER user_organizations_journal_delete_trigger AFTER DELETE ON public.user_organizations FOR EACH ROW EXECUTE FUNCTION journal.user_organizations_delete();


--
-- Name: user_organizations user_organizations_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER user_organizations_journal_insert_trigger AFTER INSERT OR UPDATE ON public.user_organizations FOR EACH ROW EXECUTE FUNCTION journal.user_organizations_insert();


--
-- Name: users users_journal_delete_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER users_journal_delete_trigger AFTER DELETE ON public.users FOR EACH ROW EXECUTE FUNCTION journal.users_delete();


--
-- Name: users users_journal_insert_trigger; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER users_journal_insert_trigger AFTER INSERT OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION journal.users_insert();


--
-- Name: part_config_sub part_config_sub_sub_parent_fkey; Type: FK CONSTRAINT; Schema: partman5; Owner: api
--

ALTER TABLE ONLY partman5.part_config_sub
    ADD CONSTRAINT part_config_sub_sub_parent_fkey FOREIGN KEY (sub_parent) REFERENCES partman5.part_config(parent_table) ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: binaries binaries_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.binaries
    ADD CONSTRAINT binaries_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: binary_versions binary_versions_binary_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.binary_versions
    ADD CONSTRAINT binary_versions_binary_id_fkey FOREIGN KEY (binary_id) REFERENCES public.binaries(id);


--
-- Name: github_users github_users_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.github_users
    ADD CONSTRAINT github_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: items items_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: last_emails last_emails_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.last_emails
    ADD CONSTRAINT last_emails_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: libraries libraries_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.libraries
    ADD CONSTRAINT libraries_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: libraries libraries_resolver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.libraries
    ADD CONSTRAINT libraries_resolver_id_fkey FOREIGN KEY (resolver_id) REFERENCES public.resolvers(id);


--
-- Name: library_versions library_versions_library_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.library_versions
    ADD CONSTRAINT library_versions_library_id_fkey FOREIGN KEY (library_id) REFERENCES public.libraries(id);


--
-- Name: memberships memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: memberships memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: organizations organizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: project_binaries project_binaries_binary_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.project_binaries
    ADD CONSTRAINT project_binaries_binary_id_fkey FOREIGN KEY (binary_id) REFERENCES public.binaries(id);


--
-- Name: project_binaries project_binaries_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.project_binaries
    ADD CONSTRAINT project_binaries_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: project_libraries project_libraries_library_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.project_libraries
    ADD CONSTRAINT project_libraries_library_id_fkey FOREIGN KEY (library_id) REFERENCES public.libraries(id);


--
-- Name: project_libraries project_libraries_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.project_libraries
    ADD CONSTRAINT project_libraries_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: projects projects_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: projects projects_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: recommendations recommendations_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.recommendations
    ADD CONSTRAINT recommendations_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: resolvers resolvers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.resolvers
    ADD CONSTRAINT resolvers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: tokens tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_identifiers user_identifiers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_identifiers
    ADD CONSTRAINT user_identifiers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_organizations user_organizations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: user_organizations user_organizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: SCHEMA audit; Type: ACL; Schema: -; Owner: api
--



--
-- Name: SCHEMA journal; Type: ACL; Schema: -; Owner: api
--



--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: root
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO PUBLIC;


--
-- Name: SCHEMA queue; Type: ACL; Schema: -; Owner: api
--



--
-- Name: SCHEMA schema_evolution_manager; Type: ACL; Schema: -; Owner: api
--



--
-- Name: SCHEMA util; Type: ACL; Schema: -; Owner: api
--



--
-- Name: SCHEMA vividcortex; Type: ACL; Schema: -; Owner: vividcortex
--



--
-- Name: TABLE binaries_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binaries_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binaries_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binaries_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binaries_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binaries_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binary_versions_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE github_users_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE github_users_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE github_users_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE github_users_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE github_users_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE github_users_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE last_emails_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE libraries_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE library_versions_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE memberships_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE organizations_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_binaries_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE project_libraries_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE projects_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE recommendations_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE resolvers_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE resolvers_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE resolvers_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE resolvers_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE resolvers_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE resolvers_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE subscriptions_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE tokens_p20240801; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_identifiers_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE user_organizations_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_default; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240101; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240201; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240301; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240401; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240501; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240601; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE users_p20240701; Type: ACL; Schema: journal; Owner: api
--



--
-- Name: TABLE binaries; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE binary_versions; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE github_users; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE items; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE items_bak; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE last_emails; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE libraries; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE library_versions; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE memberships; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE organizations; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE pg_stat_statements; Type: ACL; Schema: public; Owner: rdsadmin
--



--
-- Name: TABLE project_binaries; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE project_libraries; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE projects; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE recommendations; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE resolvers; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE subscriptions; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE syncs; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE tasks; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE tokens; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE user_identifiers; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE user_organizations; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: api
--



--
-- Name: TABLE bootstrap_scripts; Type: ACL; Schema: schema_evolution_manager; Owner: api
--



--
-- Name: TABLE scripts; Type: ACL; Schema: schema_evolution_manager; Owner: api
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: audit; Owner: vividcortex
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: journal; Owner: vividcortex
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: vividcortex
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: schema_evolution_manager; Owner: vividcortex
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: util; Owner: vividcortex
--



--
-- PostgreSQL database dump complete
--

