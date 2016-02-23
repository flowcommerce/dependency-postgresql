update organizations
   set deleted_at=now()
 where deleted_at is null
   and key like 'z-test%';

update projects
   set deleted_at=now()
 where deleted_at is null
   and name like 'Z Test %';

update project_libraries
   set deleted_at=now()
 where deleted_at is null
   and project_id in (select id from projects where deleted_at is not null);

update project_binaries
   set deleted_at=now()
 where deleted_at is null
   and project_id in (select id from projects where deleted_at is not null);

update libraries
   set deleted_at=now()
 where deleted_at is null
   and group_id like 'z-test%';

update library_versions
   set deleted_at=now()
 where deleted_at is null
   and library_id not in (
     select libraries.id
       from libraries
      where libraries.deleted_at is null
  );

update binaries
   set deleted_at=now()
 where deleted_at is null
   and (lower(name) like 'z-test%' or lower(name) like 'z test%'); 

update binary_versions
   set deleted_at=now()
 where deleted_at is null
   and binary_id in (
     select binaries.id
       from binaries
      where binaries.deleted_at is not null
  );

update users
   set deleted_at=now()
 where deleted_at is null
   and email like 'z-test-%';

update github_users
   set deleted_at=now()
 where deleted_at is null
   and login like 'z-test-%';

update resolvers
   set deleted_at=now()
 where deleted_at is null
   and uri like '%z-test.flow.io%';

update tokens
   set deleted_at=now()
 where deleted_at is null
   and tag like 'z test%';

update items
   set deleted_at=now()
 where deleted_at is null
   and label like 'z-test%';

update subscriptions
   set deleted_at=now()
 where deleted_at is null
   and user_id in (select id from users where deleted_at is not null);

update last_emails
   set deleted_at=now()
 where deleted_at is null
   and user_id in (select id from users where deleted_at is not null);

