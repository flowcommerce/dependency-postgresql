create or replace function journal.refresh_journaling_native(
  p_source_schema_name in varchar, p_source_table_name in varchar,
  p_target_schema_name in varchar, p_target_table_name in varchar
) returns varchar language plpgsql as $$
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
