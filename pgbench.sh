#!/usr/bin/env bash

LOGS=$1
XACTS=$2
CLIENTS=$3
DBNAME=$4

echo `date` "running pgbench on database $DBNAME transactions $XACTS clients $CLIENTS"

pgbench -n -t $XACTS -c $CLIENTS $DBNAME >> $LOGS/debug.log 2>&1

echo `date` "completed pgbench on database $DBNAME transactions $XACTS clients $CLIENTS"
