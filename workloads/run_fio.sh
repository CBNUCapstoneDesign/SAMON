#!/bin/bash
# Workload 1: fio synthetic I/O (multi-phase)
# Requires: fio, sudo

set -e
echo "=== fio Multi-Phase Workload ==="

echo "Phase 1: Random R/W mix (25s)"
fio --name=p1 --filename=/tmp/samon_fio1 --size=256M \
    --rw=randrw --rwmixread=70 --bs=4k --direct=1 \
    --numjobs=2 --runtime=25 --time_based --group_reporting --quiet

echo "Phase 2: Sequential write (20s)"
fio --name=p2 --filename=/tmp/samon_fio2 --size=512M \
    --rw=write --bs=128k --direct=1 --runtime=20 --time_based --quiet

echo "Phase 3: Random read + Sequential write (25s)"
fio --name=p3r --filename=/tmp/samon_fio1 --size=256M \
    --rw=randread --bs=4k --direct=1 --runtime=25 --time_based --quiet &
fio --name=p3w --filename=/tmp/samon_fio3 --size=128M \
    --rw=write --bs=64k --direct=1 --runtime=25 --time_based --quiet
wait

echo "Phase 4: Burst random write (15s)"
fio --name=p4 --filename=/tmp/samon_fio4 --size=1G \
    --rw=randwrite --bs=16k --direct=1 \
    --numjobs=4 --runtime=15 --time_based --quiet

rm -f /tmp/samon_fio*
echo "Done."
