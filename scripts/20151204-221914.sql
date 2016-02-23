drop table if exists syncs;

create table syncs (
  id                         text primary key,
  type                       text not null check(util.lower_non_empty_trimmed_string(type)),
  object_id                  text not null,
  event                      text not null check(util.lower_non_empty_trimmed_string(event)),
  created_at                 timestamptz default now() not null,
  updated_by_user_id         text not null
);

comment on table syncs is '
  Records when we start and complete each sync of a module (e.g. project)
';

create index on syncs(type);
create index on syncs(object_id, event);

