drop table if exists memberships;

create table memberships (
  id                      text primary key,
  user_id                 text not null references users,
  organization_id         text not null references organizations,
  role                    text not null check(util.lower_non_empty_trimmed_string(role)),
  unique(user_id, organization_id)
);

comment on table memberships is '
  Users can join other organizations. Note that the user_organizations table
  records the specific organization assigned to a user while this table lists
  all the members of an org and is used to represent group accounts (e.g. an
  organization representing a company). Note that we only allow one row
  per user/org - and we store only the higher role (e.g. admin).
';

select audit.setup('public', 'memberships');
create index on memberships(organization_id);
