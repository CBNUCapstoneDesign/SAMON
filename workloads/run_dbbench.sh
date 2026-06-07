#!/bin/bash
# Workload 4: db_bench (RocksDB LSM-tree)
# Requires: rocksdb-tools (db_bench), sudo

set -e
echo "=== db_bench (RocksDB) Workload ==="

db_bench --benchmarks=fillrandom,readrandom,readwhilewriting,compactall \
    --db=/tmp/samon_rocksdb --num=2000000 --value_size=256 \
    --use_direct_io_for_flush_and_compaction=true \
    --use_direct_reads=true

rm -rf /tmp/samon_rocksdb
echo "Done."
