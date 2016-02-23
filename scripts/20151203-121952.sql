drop table if exists items;

create table items (
  id                       text primary key,
  organization_id          text not null references organizations,
  visibility                 text not null check(util.lower_non_empty_trimmed_string(visibility)),
  object_id                text not null,
  label                      text not null check(util.non_empty_trimmed_string(label)),
  description                text check(trim(description) = description),
  summary                    json,
  contents                   text not null check(util.non_empty_trimmed_string(contents)) check(lower(contents) = contents),
  unique(organization_id, object_id)
);

comment on table items is '
  A denormalization of things that we want to search for. Basic model
  is that as the types are updated, we store a denormalized copy here
  just for search - e.g. projects, libraries, and binaries are
  denormalized here.
';

comment on column items.summary is '
  Information specific to the type of object indexed. See the
  item_detail union type at http://apidoc.me/bryzek/dependency/latest
';

comment on column items.contents is '
  All of the actual textual contents we search.
';

select audit.setup('public', 'items');
