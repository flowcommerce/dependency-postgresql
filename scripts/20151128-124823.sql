drop table if exists github_users;

create table github_users (
  id                       text not null primary key,
  user_id                  text not null references users,
  github_user_id           bigint unique not null,
  login                    text unique not null check(util.non_empty_trimmed_string(login))
);

select audit.setup('public', 'github_users');
create index on github_users(user_id);

comment on table github_users is '
  Maps our users to their IDs in third party systems (e.g. github)
';

