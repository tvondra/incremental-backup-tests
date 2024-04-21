#!/usr/bin/env bash

set -e

MOUNT=$1
LOGS=$2
SCALE=$3
LOOPS=$4

DATADIR=$MOUNT/test-$LOGS/data
DEBUG=$LOGS/debug.log
BACKUPS=$MOUNT/test-$LOGS/backups
CHECKSUMS=$MOUNT/test-$LOGS/checksums


MAXPCT=10

echo `date` backups $NUMBACKUPS maxpct $MAXPCT

PATH=/var/lib/postgresql/builds/master/bin:$PATH


# now run pgbench on all the databases, with more and more changes
for l in $(seq 1 $LOOPS); do

	echo `date` "loop $l of $LOOPS"

	pct=$((1 + RANDOM % MAXPCT))

	# scale is a multiple of 100k rows in pgbench_accounts, but only ~1640 pages
	# and the backups work at page level, so assume each update hits one random page
	# (ignore collisions)
	ROWS=$((1640 * SCALE * pct / 100))

	# calculate number of clients and transactions per client
	c=$((16))
	t=$((ROWS/c))

	# drop the database copy (if exists)
	echo `date` "dropping database db_copy"
	dropdb --if-exists "db_copy"
	echo `date` "db_copy dropped"

	# now do three things almost at the same time - create a copy of the database, start pgbench on both the source and the new DB
	r=$((RANDOM % 2))

	# random strategy to create the database
	if [ "$r" == 0 ]; then
		strategy="wal_log"
	else
		strategy="file_copy"
	fi

	# start the CREATEDB from the source db
	./create-db.sh $strategy &

	# give the createdb bit of time to start
	sleep 1

	# start a pgbench on both databases
	./pgbench.sh $LOGS $t $c db &

	# wait for the createdb and pgbench runs to complete
	wait

	# now also run pgbench on the new database
	./pgbench.sh $LOGS $t $c db_copy &

	echo `date` "calculating dumpall checksum"
	chsum=$(pg_dumpall | md5sum | awk '{print $1}')
	echo `date` "dumpall checksum calculated"

	echo "$l $chsum" >> $CHECKSUMS/workload.checksums

	# sleep for a bit 5-35 seconds
	sleep $((5 + RANDOM % 30))

done

touch workload.done

echo `date` "workload generator completed"
