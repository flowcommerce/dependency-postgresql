alter table project_libraries add organization_id text default 'tmp' not null;
update project_libraries set organization_id = (Select organization_id from projects where projects.id = project_id);
delete from project_libraries where organization_id = 'tmp';
alter table project_libraries alter column organization_id drop default;
