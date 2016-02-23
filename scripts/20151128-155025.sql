drop table if exists tokens;

create table tokens (
  id                      text primary key,
  user_id                 text not null references users,
  tag                     text not null check(util.lower_non_empty_trimmed_string(tag)),
  token                   text unique not null check (trim(token) = token),
  number_views            bigint default 0 not null check (number_views >= 0),
  description             text
);

select audit.setup('public', 'tokens');

create index on tokens(user_id);

comment on table tokens is '
  Stores oauth tokens for a given user.
';

comment on column tokens.tag is '
  Identifies the token - e.g. github_oauth
';

comment on column tokens.number_views is '
  Controls retrieval of cleartext token - e.g. only can see the token once
';

