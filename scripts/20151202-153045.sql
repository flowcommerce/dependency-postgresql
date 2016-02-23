drop table if exists recommendations;

create table recommendations (
  id                       text primary key,
  project_id               text not null references projects,
  type                       text not null check(util.lower_non_empty_trimmed_string(type)),
  object_id                text not null,
  name                       text not null check(util.non_empty_trimmed_string(name)),
  from_version               text not null check(util.non_empty_trimmed_string(from_version)),
  to_version                 text not null check(util.non_empty_trimmed_string(to_version)),
  unique(project_id, type, object_id, name, from_version)
);

comment on table recommendations is '
  For each project we automatically record what our recommendations
  are in terms of which libraries and binaries to upgrade. These
  recommendations are created in the background by monitoring updates
  to both the project and its dependencies (for example, if a new
  version of a dependent library is released, we created a
  recommendation).
';

select audit.setup('public', 'recommendations');
create index on recommendations(object_id);
