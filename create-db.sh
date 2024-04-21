#!/usr/bin/env bash

echo `date` "creating database db_copy strategy $1"

createdb -S $1 -T "db" "db_copy"

echo `date` "database db_copy created"
