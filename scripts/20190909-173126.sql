alter table items add updated_at timestamptz not null default now();
update items set updated_at = created_at;
alter table items add hash_code bigint not null default 0;
select schema_evolution_manager.create_updated_at_trigger('public', 'items');
