#!/usr/bin/env bash

DIR=/home/user/tmp/backups

rm -Rf $DIR
mkdir -p $DIR

while /bin/true; do

	scale=$((100 + RANDOM % 100))

	p=$(date +%Y%m%d-%H%M%S)-workload-20240408

	mkdir $p

	echo `date` START $p

	./generate-backups-workload.sh $DIR $p $scale 0 > $p/run.log 2>&1

	./restore-backups-workload.sh $DIR $p $scale 0 >> $p/run.log 2>&1;

	echo `date` END $p

	exit

done
