drop index tasks_num_attempts_processed_at_idx;

create index tasks_num_attempts_processed_at_idx on tasks(priority, num_attempts, created_at) where processed_at is null;
