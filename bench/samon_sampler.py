#!/usr/bin/env python3
"""samon_sampler.py — 1초 간격 커널 카운터 샘플러 (측정 도구).

측정하는 동안 매초 /proc/vmstat, 대상 디스크의 /proc/diskstats, 측정 cgroup의
memory.stat·memory.current를 읽어 CSV 한 줄로 남긴다. 값은 누적 카운터 원문이며
차분(초당 값)은 분석 단계에서 계산한다. 실행 구간과의 연결은 시각으로 한다
(하네스 snap_*/ts = realtime 초).

- debugfs(samon stats)와 DAMON_LRU_SORT 파일은 읽지 않는다(하네스의 측정 구간 규칙).
- 파일은 매번 열고 닫는다. cgroup이 없으면(실행 사이) 해당 칸은 빈 값, cg_present=0.
- 시각: rt_ns = CLOCK_REALTIME, mono_ns = CLOCK_MONOTONIC (bpftrace nsecs와 같은 시계).

usage: samon_sampler.py -o OUT.csv [-d nvme0n2] [-c /sys/fs/cgroup/samon_bench] [-i 1.0]
SIGTERM/SIGINT로 종료한다. 매 줄 flush. 시작 정보는 OUT.csv.meta에 한 줄씩 덧붙인다.
"""
import argparse, os, signal, sys, time

VMSTAT = ["pgpgin", "pgpgout", "workingset_refault_file", "workingset_activate_file",
          "workingset_restore_file", "pgscan_kswapd", "pgscan_direct", "pgsteal_kswapd",
          "pgsteal_direct", "pgactivate", "pgdeactivate", "pgrefill", "nr_dirty",
          "nr_writeback", "nr_file_pages", "nr_active_file", "nr_inactive_file", "nr_free_pages"]
DISK = ["rd_ios", "rd_merges", "rd_sectors", "rd_ms", "wr_ios", "wr_merges", "wr_sectors",
        "wr_ms", "in_flight", "io_ticks_ms", "time_in_queue_ms"]
CGSTAT = ["file", "active_file", "inactive_file", "file_dirty", "file_writeback",
          "workingset_refault_file", "workingset_activate_file", "pgscan", "pgsteal",
          "pgactivate", "pgdeactivate"]

def read_kv(path):
    d = {}
    try:
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) == 2:
                    d[p[0]] = p[1]
    except OSError:
        return None
    return d

def read_disk(dev):
    try:
        with open("/proc/diskstats") as f:
            for line in f:
                p = line.split()
                if len(p) >= 14 and p[2] == dev:
                    return p[3:14]
    except OSError:
        pass
    return None

def read_one(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("-d", "--disk", default="nvme0n2")
    ap.add_argument("-c", "--cgroup", default="/sys/fs/cgroup/samon_bench")
    ap.add_argument("-i", "--interval", type=float, default=1.0)
    a = ap.parse_args()
    stop = []
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: stop.append(1))
    new = not os.path.exists(a.out)
    out = open(a.out, "a", buffering=1)
    if new:
        hdr = ["rt_ns", "mono_ns"] + ["vm_" + k for k in VMSTAT] + ["disk_" + k for k in DISK] \
              + ["cg_present", "cg_memory_current"] + ["cg_" + k for k in CGSTAT]
        out.write(",".join(hdr) + "\n")
    with open(a.out + ".meta", "a") as m:
        m.write("start rt_ns=%d mono_ns=%d disk=%s cgroup=%s interval=%s pid=%d\n" % (
            time.time_ns(), time.clock_gettime_ns(time.CLOCK_MONOTONIC), a.disk, a.cgroup, a.interval, os.getpid()))
    nxt = time.monotonic()
    while not stop:
        rt, mono = time.time_ns(), time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        vm = read_kv("/proc/vmstat") or {}
        dk = read_disk(a.disk) or [""] * len(DISK)
        cg = read_kv(os.path.join(a.cgroup, "memory.stat"))
        cur = read_one(os.path.join(a.cgroup, "memory.current"))
        row = [str(rt), str(mono)] + [vm.get(k, "") for k in VMSTAT] + dk
        if cg is None:
            row += ["0", ""] + [""] * len(CGSTAT)
        else:
            row += ["1", cur or ""] + [cg.get(k, "") for k in CGSTAT]
        out.write(",".join(row) + "\n")
        nxt += a.interval
        delay = nxt - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            nxt = time.monotonic()  # 밀렸으면 다시 맞춘다(따라잡기 연속 기록 없음)
    out.close()

if __name__ == "__main__":
    main()
