#!/usr/bin/env python3
"""
YCSB-style zipfian workload on SQLite with direct I/O characteristics.
Demonstrates how skewed key distribution creates hot LBA regions.
"""
import sqlite3
import numpy as np
import time
import os

DB_PATH = "/tmp/samon_zipfian.db"
NUM_ROWS = 2_000_000
BATCH = 10000

def zipfian_keys(n, num_keys, alpha=1.2):
    """Generate n keys following zipfian distribution"""
    x = np.arange(1, num_keys + 1, dtype=np.float64)
    weights = 1.0 / np.power(x, alpha)
    weights /= weights.sum()
    return np.random.choice(num_keys, size=n, p=weights)

def create_db():
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("CREATE TABLE data (id INTEGER PRIMARY KEY, value TEXT)")
    
    print("Inserting rows...", flush=True)
    for i in range(0, NUM_ROWS, BATCH):
        rows = [(j, "x" * 256) for j in range(i, min(i + BATCH, NUM_ROWS))]
        conn.executemany("INSERT INTO data VALUES (?, ?)", rows)
    conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    print(f"DB created: {os.path.getsize(DB_PATH) / 1024 / 1024:.0f}MB", flush=True)

def phase_uniform_read(conn, duration):
    """Uniform random reads - spread across all LBAs"""
    end = time.time() + duration
    count = 0
    while time.time() < end:
        key = np.random.randint(0, NUM_ROWS)
        conn.execute("SELECT * FROM data WHERE id = ?", (int(key),)).fetchone()
        count += 1
    print(f"  Uniform read: {count} queries", flush=True)

def phase_zipfian_read(conn, duration, alpha=1.2):
    """Zipfian reads - heavily skewed to small keys (hot region)"""
    end = time.time() + duration
    count = 0
    batch_size = 10000
    keys = zipfian_keys(batch_size, NUM_ROWS, alpha)
    idx = 0
    while time.time() < end:
        if idx >= batch_size:
            keys = zipfian_keys(batch_size, NUM_ROWS, alpha)
            idx = 0
        conn.execute("SELECT * FROM data WHERE id = ?", (int(keys[idx]),)).fetchone()
        idx += 1
        count += 1
    print(f"  Zipfian read (alpha={alpha}): {count} queries", flush=True)

def phase_zipfian_write(conn, duration, alpha=1.2):
    """Zipfian updates - write-heavy on hot keys"""
    end = time.time() + duration
    count = 0
    batch_size = 10000
    keys = zipfian_keys(batch_size, NUM_ROWS, alpha)
    idx = 0
    while time.time() < end:
        if idx >= batch_size:
            keys = zipfian_keys(batch_size, NUM_ROWS, alpha)
            idx = 0
            conn.commit()
        conn.execute("UPDATE data SET value = ? WHERE id = ?",
                     ("y" * 256, int(keys[idx])))
        idx += 1
        count += 1
    conn.commit()
    print(f"  Zipfian write (alpha={alpha}): {count} queries", flush=True)

def phase_zipfian_mixed(conn, duration, alpha=1.5):
    """Highly skewed mixed R/W - very concentrated hot spot"""
    end = time.time() + duration
    count = 0
    batch_size = 10000
    keys = zipfian_keys(batch_size, NUM_ROWS, alpha)
    idx = 0
    while time.time() < end:
        if idx >= batch_size:
            keys = zipfian_keys(batch_size, NUM_ROWS, alpha)
            idx = 0
            conn.commit()
        key = int(keys[idx])
        if np.random.random() < 0.7:
            conn.execute("SELECT * FROM data WHERE id = ?", (key,)).fetchone()
        else:
            conn.execute("UPDATE data SET value = ? WHERE id = ?", ("z" * 256, key))
        idx += 1
        count += 1
    conn.commit()
    print(f"  Zipfian mixed (alpha={alpha}): {count} ops", flush=True)

def main():
    create_db()
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null")

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA cache_size=256")
    conn.execute("PRAGMA mmap_size=0")

    phases = [
        ("Phase 1: Uniform read (20s)", lambda c: phase_uniform_read(c, 20)),
        ("Phase 2: Zipfian read alpha=1.2 (20s)", lambda c: phase_zipfian_read(c, 20, 1.2)),
        ("Phase 3: Zipfian read alpha=1.5 (20s)", lambda c: phase_zipfian_read(c, 20, 1.5)),
        ("Phase 4: Zipfian write alpha=1.2 (15s)", lambda c: phase_zipfian_write(c, 15, 1.2)),
        ("Phase 5: Zipfian mixed alpha=1.5 (15s)", lambda c: phase_zipfian_mixed(c, 15, 1.5)),
    ]

    for name, func in phases:
        print(name, flush=True)
        conn.close()
        os.system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null")
        conn = sqlite3.connect(DB_PATH)
        conn.execute("PRAGMA cache_size=256")
        conn.execute("PRAGMA mmap_size=0")
        func(conn)

    conn.close()
    os.remove(DB_PATH)
    wal = DB_PATH + "-wal"
    if os.path.exists(wal):
        os.remove(wal)
    print("Done.", flush=True)

if __name__ == "__main__":
    main()
