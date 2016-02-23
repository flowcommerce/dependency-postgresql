drop table if exists subscriptions;

create table subscriptions (
  id                       text primary key,
  user_id                  text not null references users,
  publication                text not null check(util.lower_non_empty_trimmed_string(publication)),
  unique(user_id, publication)
);

comment on table subscriptions is '
  Keeps track of things the user has subscribed to (like a daily email)
';

select audit.setup('public', 'subscriptions');
