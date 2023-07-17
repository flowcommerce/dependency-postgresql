create or replace function journal.is_journal_erm_schema(p_schema_name in varchar) returns boolean language plpgsql IMMUTABLE as $$
declare
  v_position smallint;
begin
  select position('journal_erm' in p_schema_name) into v_position;
  return v_position > 0;
end;
$$;

create or replace function journal.refresh_journal_delete_trigger(
  p_source_schema_name in varchar, p_source_table_name in varchar,
  p_target_schema_name in varchar, p_target_table_name in varchar
) returns varchar language plpgsql as $$
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
    v_sql := v_sql || ', ' || row.column_name;

    if row.column_name = 'updated_by_user_id' and NOT journal.is_journal_erm_schema(p_target_schema_name) then
      v_target_sql := v_target_sql || ', journal.get_deleted_by_user_id()';
    else
      v_target_sql := v_target_sql || ', old.' || row.column_name;
    end if;
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
