#!/usr/bin/env python3
"""
B-tree lookup workload for SAMON visualization.
Creates a large SQLite DB with B-tree index, then performs
phased lookups to produce distinct access patterns.
"""
import sqlite3
import random
import time
import sys
import os

DB_PATH = "/tmp/samon_btree_test.db"
NUM_ROWS = 2_000_000
BATCH = 10000

def create_db():
    """Create DB with large indexed table"""
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("CREATE TABLE data (id INTEGER PRIMARY KEY, key INTEGER, value TEXT)")
    conn.execute("CREATE INDEX idx_key ON data(key)")

    print("Inserting rows...", flush=True)
    for i in range(0, NUM_ROWS, BATCH):
        rows = [(j, random.randint(0, NUM_ROWS * 10), "x" * 200) for j in range(i, min(i + BATCH, NUM_ROWS))]
        conn.executemany("INSERT INTO data VALUES (?, ?, ?)", rows)
    conn.commit()

    # force WAL checkpoint to flush to main DB
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    size = os.path.getsize(DB_PATH)
    print(f"DB created: {size / 1024 / 1024:.0f}MB, {NUM_ROWS} rows", flush=True)

def phase_sequential_scan(conn, duration):
    """Full table scan - sequential I/O pattern"""
    end = time.time() + duration
    count = 0
    while time.time() < end:
        for row in conn.execute("SELECT * FROM data WHERE value LIKE 'x%' LIMIT 50000"):
            pass
        count += 1
    print(f"  Sequential scan: {count} iterations", flush=True)

def phase_random_point_lookup(conn, duration):
    """Random primary key lookups - B-tree root+internal hot, leaf scattered"""
    end = time.time() + duration
    count = 0
    while time.time() < end:
        key = random.randint(0, NUM_ROWS - 1)
        conn.execute("SELECT * FROM data WHERE id = ?", (key,)).fetchone()
        count += 1
    print(f"  Random PK lookup: {count} queries", flush=True)

def phase_index_range_scan(conn, duration):
    """Range scan on secondary index - B-tree traversal pattern"""
    end = time.time() + duration
    count = 0
    while time.time() < end:
        start_key = random.randint(0, NUM_ROWS * 9)
        for row in conn.execute("SELECT * FROM data WHERE key BETWEEN ? AND ? LIMIT 100",
                                (start_key, start_key + 1000)):
            pass
        count += 1
    print(f"  Index range scan: {count} queries", flush=True)

def phase_hot_key_lookup(conn, duration):
    """Concentrated lookups on small key range - very hot B-tree subtree"""
    end = time.time() + duration
    hot_range = NUM_ROWS // 100  # 1% of keys
    count = 0
    while time.time() < end:
        key = random.randint(0, hot_range)
        conn.execute("SELECT * FROM data WHERE id = ?", (key,)).fetchone()
        count += 1
    print(f"  Hot key lookup: {count} queries", flush=True)

def phase_mixed(conn, duration):
    """Mixed: random lookups + inserts"""
    end = time.time() + duration
    next_id = NUM_ROWS
    count = 0
    while time.time() < end:
        if random.random() < 0.7:
            key = random.randint(0, NUM_ROWS - 1)
            conn.execute("SELECT * FROM data WHERE id = ?", (key,)).fetchone()
        else:
            conn.execute("INSERT OR REPLACE INTO data VALUES (?, ?, ?)",
                         (next_id, random.randint(0, NUM_ROWS * 10), "y" * 200))
            next_id += 1
            if count % 500 == 0:
                conn.commit()
        count += 1
    conn.commit()
    print(f"  Mixed R/W: {count} ops", flush=True)

def main():
    create_db()

    # drop page cache so reads hit disk
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null")

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA cache_size=256")  # small cache to force more disk I/O
    conn.execute("PRAGMA mmap_size=0")     # disable mmap

    phases = [
        ("Phase 1: Sequential scan (20s)", phase_sequential_scan, 20),
        ("Phase 2: Random PK lookup (20s)", phase_random_point_lookup, 20),
        ("Phase 3: Index range scan (20s)", phase_index_range_scan, 20),
        ("Phase 4: Hot key lookup (15s)", phase_hot_key_lookup, 15),
        ("Phase 5: Mixed R/W (15s)", phase_mixed, 15),
    ]

    for name, func, dur in phases:
        print(name, flush=True)
        # drop cache between phases for distinct patterns
        conn.close()
        os.system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null")
        conn = sqlite3.connect(DB_PATH)
        conn.execute("PRAGMA cache_size=256")
        conn.execute("PRAGMA mmap_size=0")
        func(conn, dur)

    conn.close()
    os.remove(DB_PATH)
    print("Done.", flush=True)

if __name__ == "__main__":
    main()
