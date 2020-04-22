alter table project_libraries add updated_at                  timestamptz not null default now();
alter table project_libraries add hash_code bigint default 0 not null;
alter table project_libraries alter column hash_code drop default;

select schema_evolution_manager.create_updated_at_trigger('public', 'project_libraries');
