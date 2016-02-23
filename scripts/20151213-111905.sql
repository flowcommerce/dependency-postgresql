drop table if exists user_organizations;

create table user_organizations (
  id                      text primary key,
  user_id                 text unique not null references users,
  organization_id         text unique not null references organizations
);

comment on table user_organizations is '
  Each user is assigned a single organization to represent their own
  projects. This table records the org assigned to a user.
';

select audit.setup('public', 'user_organizations');
