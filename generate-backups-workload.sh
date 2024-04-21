#!/usr/bin/env bash

set -e

MOUNT=$1
LOGS=$2
SCALE=$3

DATADIR=$MOUNT/test-$LOGS/data
DEBUG=$LOGS/debug.log
BACKUPS=$MOUNT/test-$LOGS/backups
CHECKSUMS=$MOUNT/test-$LOGS/checksums

PATH=/var/lib/postgresql/builds/master/bin:$PATH

# backup index
backup=0
manifest="-"

killall -9 postgres || true
sleep 5


echo `date` initializing cluster

# init and start the cluster
rm -Rf $DATADIR $BACKUPS $CHECKSUMS $LOGS/pg.log $DEBUG

pg_ctl -D $DATADIR -o "-k" init >> $DEBUG 2>&1
cp postgresql.conf $DATADIR

mkdir $BACKUPS $CHECKSUMS

# maybe enable/disable checksums?

# start the cluster
pg_ctl -D $DATADIR -l $LOGS/pg.log start >> $DEBUG 2>&1

# initialize the database
echo `date` "creating pgbench databases (db, scale $SCALE)"
createdb db

echo `date` "creating amcheck extension"
psql db -c "create extension amcheck" >> $LOGS/debug.log 2>&1

echo `date` "pgbench init (db)"
pgbench -i -s $SCALE --partitions=$PARTITIONS db >> $LOGS/debug.log 2>&1
echo `date` "pgbench database db initialized (db)"

# create initial full basebackup
echo `date` "basebackup full (db) / start"
pg_basebackup -c fast -D $BACKUPS/full >> $DEBUG 2>&1
manifest=$BACKUPS/full/backup_manifest
echo `date` "basebackup full (db) / done"

echo `date` "dumpall calculating checksum (db)"
chsum=$(pg_dumpall | md5sum | awk '{print $1}')
echo $chsum > $CHECKSUMS/full
echo `date` "dumpall checksum calculated (db)"

# forger previous runs
rm -f "workload.done"

# start the workload that creates/drops databases and runs pgbench on them
./generate-workload.sh $MOUNT $LOGS $SCALE 10 &

# now run pgbench on all the databases, with more and more changes
while /bin/true; do

	# stop after this run, if there's she .stop file"
	stop=0
	if [ -f "workload.done" ]; then
		stop=1
	fi

	backup=$((backup+1))

	# generate another incremental backup
	echo `date` "increment $backup : performing incremental backup"

	# checkpoint mode
	r=$((RANDOM % 2))

	# random strategy to create the database
	if [ "$r" == 0 ]; then
		checkpoint="fast"
	else
		checkpoint="spread"
	fi

	echo `date` "increment $backup START : pg_basebackup -c $checkpoint --incremental=$manifest -D $BACKUPS/increment-$backup"

	# create another incremental backup
	pg_basebackup -c $checkpoint --incremental=$manifest -D $BACKUPS/increment-$backup >> $DEBUG 2>&1
	manifest=$BACKUPS/increment-$backup/backup_manifest

	echo `date` "increment $backup STOP : incremental backup completed"

	# maybe stop (if workload generator completed)
	if [ "$stop" == "1" ]; then
		break
	fi

	# sleep for a bit between runs
	sleep $((5 + RANDOM % 30))

done

echo `date` "calculating final checksum"
chsum=$(pg_dumpall | md5sum | awk '{print $1}')
echo $chsum > $CHECKSUMS/final
echo `date` "final checksum calculated"

echo `date` stopping cluster
pg_ctl -D $DATADIR stop >> $LOGS/debug.log 2>&1
echo `date` "cluster stopped"

du -s $DATADIR/ $DATADIR/base $BACKUPS/*

killall -9 postgres || true

echo "$LOGS : $backup incremental backups generated"
