PG incremental backups tests
============================

A set of scripts to test incremental backups - generating workload,
taking incremental backups, and validating them in various ways. The
basic scripts are:

* run.sh - the main driver, executing the other scripts in a loop

* generate-backups-workload.sh - initialize database, run a workload in
  the background, and take incremental backups until the workload
  finishes.

* generate-workload.sh - workload generator (running in the background),
  creates a database using specified strategy, runs short pgbench on
  both the source/target databases (all of this a number of times)

* restore-backups-workload.sh - restore the incremental backups, in a
  somewhat randomized way (random number of increments, random copy
  method, with/without manifest, ...) and then test the result in
  various ways (pg_checksums, pg_verifybackup, dump the data, ...)
