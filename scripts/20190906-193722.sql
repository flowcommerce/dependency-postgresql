drop table if exists public.tasks;

set search_path to public;

create table tasks (
  id                          text primary key check(util.non_empty_trimmed_string(id)),
  data                        text not null check(util.non_empty_trimmed_string(data)),
  num_attempts                bigint not null check(num_attempts >= 0),
  processed_at                timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  updated_by_user_id          text not null check(util.non_empty_trimmed_string(updated_by_user_id)),
  hash_code                   bigint not null
);

create index tasks_num_attempts_processed_at_idx on tasks(num_attempts, processed_at);

select schema_evolution_manager.create_updated_at_trigger('public', 'tasks');