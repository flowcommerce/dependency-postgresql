#!/bin/sh -e
DBNAME=dependencydb

exists=$(psql -q -U postgres -d $DBNAME -c '\q' 2>/dev/null && echo "yes" || echo "no")

if test "$1" = '--reset' -a "$exists" = 'yes'
then
	psql -q -U postgres -d postgres -c "DROP DATABASE $DBNAME"
	exists=no
fi

if test "$exists" = 'no'
then
	psql -q -U postgres -d postgres -c "CREATE DATABASE $DBNAME"
	if test $(psql -q -U postgres -d postgres -c "SELECT COUNT(1) FROM pg_user WHERE usename = 'api'" -t) -eq 0
	then
		psql -q -U postgres -d postgres -c 'CREATE ROLE api LOGIN PASSWORD NULL'
	fi
	psql -q -U postgres -d postgres -c "GRANT ALL ON DATABASE $DBNAME TO api"
	psql -q -U postgres -d $DBNAME -f $DBNAME.schema.sql
	psql -q -U postgres -d $DBNAME -f $DBNAME.data.sql
	psql -q -U api -d $DBNAME -c 'SELECT partman5.run_maintenance()'
fi

sem-apply --url postgresql://api@localhost/$DBNAME

if test "$exists" = 'no'
then
	for f in testdata/*
	do
		psql -q -U api -d $DBNAME -f $f -1 -v ON_ERROR_STOP=1
	done
fi
