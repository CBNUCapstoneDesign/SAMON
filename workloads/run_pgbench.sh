#!/bin/bash
# Workload 2: PostgreSQL pgbench (OLTP)
# Requires: postgresql, sudo
# Setup (once): sudo -u postgres createdb samontest
#               sudo -u postgres pgbench -i -s 50 samontest

set -e
DB="samontest"
echo "=== pgbench Workload ==="

echo "Phase 1: Select-only OLTP (30s)"
sudo -u postgres pgbench -S -c 4 -j 2 -T 30 $DB

echo "Phase 2: TPC-B mixed (30s)"
sudo -u postgres pgbench -c 4 -j 2 -T 30 $DB

echo "Phase 3: TPC-B + full scan (20s)"
sudo -u postgres pgbench -c 2 -j 2 -T 20 $DB &
sudo -u postgres psql $DB -c "SELECT count(*) FROM pgbench_accounts WHERE abalance > 0;" > /dev/null
wait

echo "Done."
