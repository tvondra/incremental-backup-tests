#!/usr/bin/env bash

set -e

MOUNT=$1
LOGS=$2
SCALE=$3
PARTITIONS=$4

RESTOREDIR=$MOUNT/test-$LOGS/restored
DEBUG=debug.log
BACKUPS=$MOUNT/test-$LOGS/backups
CHECKSUMS=$MOUNT/test-$LOGS/checksums
PATH_OLD=$PATH
RUNS=1

# number of incremental-backups
NUM_BACKUPS=$(ls $BACKUPS | grep increment | grep -v checksum | wc -l)

function wait_for_reclaim {
	prev=$(df | grep pgdata | awk '{print $3}')

	while /bin/true; do

		sleep 5;

		curr=$(df | grep pgdata | awk '{print $3}')

		if  [ "$curr" == "$prev" ]; then
			break
		fi

		prev=$curr

	done
}

rm -f parameters.txt

for p in master; do

	for b in $(seq 1 $NUM_BACKUPS); do

		checksums="no"
		if [ "$b" == "$NUM_BACKUPS" ]; then
			checksums="yes"
		fi

		for method in copy copy-file-range; do

			for manifest in on off; do

				echo $p $b $method $manifest $checksums >> parameters.txt

			done

		done

	done

done

sort -R parameters.txt > parameters.random

NUM_RESTORES=$(wc -l parameters.random | awk '{print $1}')
NUM_RESTORES=$((NUM_RESTORES * RUNS))

restore=0
result="OK"

while IFS= read -r line
do

	IFS=' ' read -a params <<< "$line"

	p="${params[0]}"
	b="${params[1]}"
	method="${params[2]}"
	manifest="${params[3]}"
	checksums="${params[4]}"

	mkdir -p $LOGS/$p
	rm -Rf $RESTOREDIR/restore-*
	PATH=/var/lib/postgresql/builds/master/bin:$PATH_OLD

	# build the list of backups
	backups="$BACKUPS/full"
	for s in $(seq 1 $b); do
		backups="$backups $BACKUPS/increment-$s"
	done

	OPTIONS=""

	if [ "$manifest" == "off" ]; then
		OPTIONS="$OPTIONS --no-manifest"
	fi

	if [ "$method" == "copy-file-range" ]; then
		OPTIONS="$OPTIONS --copy-file-range"
	fi

	for r in $(seq 1 $RUNS); do

		restore=$((restore+1))

		echo `date` "restore $restore of $NUM_RESTORES : build $p combining backups method $method manifest $manifest ($backups)"

		rm -Rf $RESTOREDIR/restore-*

		echo `date` "restore $restore of $NUM_RESTORES : fstrim"
		sudo fstrim $MOUNT || true

		sync
		wait_for_reclaim

		used_before=$(df $MOUNT | grep pgdata | awk '{print $3}')

		echo `date` "restore $restore of $NUM_RESTORES :" $(which pg_combinebackup)

		echo `date` "restore $restore of $NUM_RESTORES : pg_combinebackup -o $RESTOREDIR/restore-$b-$r $OPTIONS $backups"

		s=$(date +"%s.%6N")
		pg_combinebackup -o $RESTOREDIR/restore-$b-$r $OPTIONS $backups > $LOGS/$p/debug-$b-$r-$method-$manifest.log 2>&1
		e=$(date +"%s.%6N")
		d=$(echo "$e - $s" | bc)

		used_after=$(df $MOUNT | grep pgdata | awk '{print $3}')

		echo `date` "restore $restore of $NUM_RESTORES : backups combined"

		verify=""
		if [ "$manifest" == "on" ]; then
			echo `date` verifying combined backup
			pg_verifybackup -P -e -m $RESTOREDIR/restore-$b-$r/backup_manifest $RESTOREDIR/restore-$b-$r > $LOGS/$p/verify-$b-$r-$method-$manifest.log 2>&1
			verify=$?
			echo `date` backup verified
		fi

		echo `date` "restore $restore of $NUM_RESTORES : finishing recovery"

		# restart the cluster, so finish recovery before checksums check
		pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log start > /dev/null 2>&1
		pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log stop > /dev/null 2>&1

		sync

		#zpool get allocated,bcloneratio,bclonesaved,bcloneused

		echo `date` "restore $restore of $NUM_RESTORES : recovery finished, verifying checksums"

		# verify checksums
		pg_checksums --check $RESTOREDIR/restore-$b-$r > $LOGS/$p/checksums-$b-$r-$method-$manifest.log 2>&1
		checksums=$?

		echo `date` "restore $restore of $NUM_RESTORES : checksums verified ($checksums)"

		if [ "$checksums" == "yes" ]; then

			chsum_correct=$(cat $CHECKSUMS/final)

			echo `date` "restore $restore of $NUM_RESTORES : calculading checksum of restored database"

			# calculate checksum on the contents of the restored database
			pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log start > /dev/null 2>&1
			chsum_data=$(pg_dumpall | md5sum | awk '{print $1}')
			pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log stop > /dev/null 2>&1

			echo `date` "restore $restore of $NUM_RESTORES : checksum of restored database: $chsum_data (correct $chsum_correct)"

			if [ "$chsum_data" != "$chsum_correct" ]; then
				exit 1
			fi

		fi

		echo `date` "restore $restore of $NUM_RESTORES : running amcheck"
                pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log start > /dev/null 2>&1
		psql db < check-tables.sql > $LOGS/$p/amcheck-tables-$b-$r-$method-$manifest.log
		psql db < check-indexes.sql > $LOGS/$p/amcheck-indexes-$b-$r-$method-$manifest.log
                pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log stop > /dev/null 2>&1
		echo `date` "restore $restore of $NUM_RESTORES : amcheck completed"


		echo `date` "restore $restore of $NUM_RESTORES : running SQL check"
		pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log start > /dev/null 2>&1
		psql db -c "SELECT 'accounts', count(*), sum(abalance) FROM pgbench_accounts" > $LOGS/$p/sql-$b-$r-$method-$manifest.log
		psql db -c "SELECT 'branches', count(*), sum(bbalance) FROM pgbench_branches" >> $LOGS/$p/sql-$b-$r-$method-$manifest.log
		psql db -c "SELECT 'tellers', count(*), sum(tbalance) FROM pgbench_tellers" >> $LOGS/$p/sql-$b-$r-$method-$manifest.log
		psql db -c "SELECT 'history', count(*), sum(delta) FROM pgbench_history" >> $LOGS/$p/sql-$b-$r-$method-$manifest.log

		s1=$(psql db -t -A -c "SELECT sum(abalance) FROM pgbench_accounts")
		s2=$(psql db -t -A -c "SELECT sum(bbalance) FROM pgbench_branches")
		s3=$(psql db -t -A -c "SELECT sum(tbalance) FROM pgbench_tellers")
		s4=$(psql db -t -A -c "SELECT sum(delta) FROM pgbench_history")

		# remember if the copy DB exists
		x=$(psql -t -A -c "select 1 from pg_database where datname = 'db_copy'" db)

                pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log stop > /dev/null 2>&1
		echo `date` "restore $restore of $NUM_RESTORES : SQL check completed db (account $s1 branches $s2 tellers $s3 history $s4)"

		if [ "$s1" != "$s2" ] || [ "$s1" != "$s3" ] || [ "$s1" != "$s4" ]; then
			echo "ERROR: balance mismatch (db) $p $b $method $manifest $checksums"
			result="ERROR"
		fi

		if [ "$x" == "1" ]; then

			echo `date` "restore $restore of $NUM_RESTORES : running amcheck"
			pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log start > /dev/null 2>&1
			psql db_copy < check-tables.sql > $LOGS/$p/amcheck-tables-$b-$r-$method-$manifest.log
			psql db_copy < check-indexes.sql > $LOGS/$p/amcheck-indexes-$b-$r-$method-$manifest.log
			pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log stop > /dev/null 2>&1
			echo `date` "restore $restore of $NUM_RESTORES : amcheck completed"

			echo `date` "restore $restore of $NUM_RESTORES : running SQL check"
			pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log start > /dev/null 2>&1
			psql db_copy -c "SELECT 'accounts', count(*), sum(abalance) FROM pgbench_accounts" > $LOGS/$p/sql-$b-$r-$method-$manifest.log
			psql db_copy -c "SELECT 'branches', count(*), sum(bbalance) FROM pgbench_branches" >> $LOGS/$p/sql-$b-$r-$method-$manifest.log
			psql db_copy -c "SELECT 'tellers', count(*), sum(tbalance) FROM pgbench_tellers" >> $LOGS/$p/sql-$b-$r-$method-$manifest.log
			psql db_copy -c "SELECT 'history', count(*), sum(delta) FROM pgbench_history" >> $LOGS/$p/sql-$b-$r-$method-$manifest.log

			s1=$(psql db_copy -t -A -c "SELECT sum(abalance) FROM pgbench_accounts")
			s2=$(psql db_copy -t -A -c "SELECT sum(bbalance) FROM pgbench_branches")
			s3=$(psql db_copy -t -A -c "SELECT sum(tbalance) FROM pgbench_tellers")
			s4=$(psql db_copy -t -A -c "SELECT sum(delta) FROM pgbench_history")

			pg_ctl -D $RESTOREDIR/restore-$b-$r -l $LOGS/$p/restore-$b-$r-$method-$manifest.log stop > /dev/null 2>&1
			echo `date` "restore $restore of $NUM_RESTORES : SQL check completed db_copy (account $s1 branches $s2 tellers $s3 history $s4)"

			if [ "$s1" != "$s2" ] || [ "$s1" != "$s3" ] || [ "$s1" != "$s4" ]; then
				echo "ERROR: balance mismatch (db_copy) $p $b $method $manifest $checksums"
				result="ERROR"
			fi

		fi

		echo `date` "restore $restore of $NUM_RESTORES : combinebackup done: " $((used_after - used_before)) "KB, $d seconds, checksums $checksums md5 $chsum_data verify $verify"

		du -s $RESTOREDIR/restore-$b-$r $RESTOREDIR/restore-$b-$r/base

		ls $RESTOREDIR/restore-$b-$r/base > $LOGS/$p/dbs-$b-$r-$method-$manifest.log
		find $RESTOREDIR/restore-$b-$r > $LOGS/$p/files-$b-$r-$method-$manifest.log

	done

done < parameters.random

if [ "$result" == "OK" ]; then
	rm -Rf $MOUNT/test-$LOGS
fi

echo "$LOGS : done ($restore restores) $result"
