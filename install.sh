#!/bin/sh
DBNAME=dependencydb

if test "$1" = '--reset'
then
	psql -q -U postgres -d postgres -c "DROP DATABASE $DBNAME"
fi

if psql -q -U postgres -d $DBNAME -c '\q' 2>/dev/null
then
	echo $DBNAME already exists, not bootstrapping >&2
else
	psql -q -U postgres -d postgres -c "CREATE DATABASE $DBNAME"
	psql -q -U postgres -d postgres -c 'CREATE ROLE api LOGIN PASSWORD NULL'
	psql -q -U postgres -d postgres -c "GRANT ALL ON DATABASE $DBNAME TO api"
	psql -q -U postgres -d $DBNAME -f $DBNAME.schema.sql
	psql -q -U postgres -d $DBNAME -f $DBNAME.data.sql
	psql -q -U api -d $DBNAME -c 'SELECT partman5.run_maintenance()'
fi

sem-apply --url postgresql://api@localhost/$DBNAME
