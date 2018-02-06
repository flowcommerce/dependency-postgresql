alter table users add column status VARCHAR(20) null;

update users set status = 'active';

alter table users alter column status set not null;