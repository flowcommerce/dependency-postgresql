 drop table if exists user_identifiers;
 
 create table user_identifiers (
  id                      text primary key,
  user_id                 text not null references users,
  value                   text not null check(util.non_empty_trimmed_string(value)) check(length(value) >= 40)
);

comment on table user_identifiers is '
  Stores unique, randomly generated identifiers that identify this
  user. The basic use case is to enable things like unsubscribe w/out
  login. Identifiers can be rotated regularly with last n identifiers
  being valid (allowing eventual expiration).
';

select audit.setup('public', 'user_identifiers');
create index on user_identifiers(user_id);
create unique index on user_identifiers(value);

