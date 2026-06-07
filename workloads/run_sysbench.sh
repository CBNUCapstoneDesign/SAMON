#!/bin/bash
# Workload 5: sysbench fileio (direct I/O)
# Requires: sysbench, sudo

set -e
echo "=== sysbench fileio Workload ==="

cd /tmp
sysbench fileio --file-total-size=1G --file-num=4 --file-test-mode=seqwr \
    --file-extra-flags=direct prepare > /dev/null

echo "Phase 1: Sequential write (30s)"
sysbench fileio --file-total-size=1G --file-num=4 --file-test-mode=seqwr \
    --time=30 --file-extra-flags=direct run

echo "Phase 2: Random R/W (30s)"
sysbench fileio --file-total-size=1G --file-num=4 --file-test-mode=rndrw \
    --time=30 --file-extra-flags=direct run

echo "Phase 3: Random read (25s)"
sysbench fileio --file-total-size=1G --file-num=4 --file-test-mode=rndrd \
    --time=25 --file-extra-flags=direct run

sysbench fileio --file-total-size=1G --file-num=4 cleanup > /dev/null
echo "Done."
