create or replace function make_resolver(uri text) returns text language plpgsql as $$
declare
  v_num integer;
  v_resolver_id text;
begin
  select coalesce(count(*), 0) into v_num from resolvers;
  v_resolver_id := 'res-20151231-' || v_num + 1;

  insert into resolvers
  (id, position, visibility, uri, updated_by_user_id)
  values
  (v_resolver_id, v_num, 'public', uri, 'usr-20151231-1');

  return v_resolver_id;
end;
$$;

select make_resolver('http://jcenter.bintray.com/');
select make_resolver('http://repo.typesafe.com/typesafe/ivy-releases/');
select make_resolver('http://oss.sonatype.org/content/repositories/snapshots');
select make_resolver('http://repo1.maven.org/maven2/');

drop function make_resolver(text);
