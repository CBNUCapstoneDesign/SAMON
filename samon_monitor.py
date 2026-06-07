#!/usr/bin/env python3
"""
SAMON - Storage Access MONitor
Adaptive regioning + CSV logging for heatmap visualization
"""
from bcc import BPF
from time import sleep, time, strftime
import sys
import csv
import argparse

# --- BPF Program ---
bpf_text = """
#include <uapi/linux/ptrace.h>
#include <linux/blk_types.h>

struct event_t {
    u64 sector;
    u32 size;
    u8 rwflag;
};

BPF_PERF_OUTPUT(events);

int trace_bio(struct pt_regs *ctx, struct bio *bio) {
    struct event_t e = {};
    e.sector = bio->bi_iter.bi_sector;
    e.size = bio->bi_iter.bi_size;
    e.rwflag = (bio->bi_opf & 1) ? 1 : 0;
    events.perf_submit(ctx, &e, sizeof(e));
    return 0;
}
"""

class Region:
    __slots__ = ['start', 'end', 'reads', 'writes']
    def __init__(self, start, end):
        self.start = start
        self.end = end
        self.reads = 0
        self.writes = 0

    @property
    def total(self):
        return self.reads + self.writes

    @property
    def size(self):
        return self.end - self.start

class AdaptiveRegions:
    def __init__(self, max_sector, min_regions=8, max_regions=128):
        self.min_regions = min_regions
        self.max_regions = max_regions
        self.max_sector = max_sector
        # start with evenly divided regions
        nr = min_regions
        step = max_sector // nr
        self.regions = []
        for i in range(nr):
            s = i * step
            e = (i + 1) * step if i < nr - 1 else max_sector
            self.regions.append(Region(s, e))

    def record(self, sector, is_write):
        # binary search for region
        lo, hi = 0, len(self.regions) - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            r = self.regions[mid]
            if sector < r.start:
                hi = mid - 1
            elif sector >= r.end:
                lo = mid + 1
            else:
                if is_write:
                    r.writes += 1
                else:
                    r.reads += 1
                return
        # fallback: last region
        if is_write:
            self.regions[-1].writes += 1
        else:
            self.regions[-1].reads += 1

    def adapt(self):
        """DAMON-style merge similar neighbors, split hot regions"""
        # merge: adjacent regions with similar access frequency
        i = 0
        while i < len(self.regions) - 1 and len(self.regions) > self.min_regions:
            a, b = self.regions[i], self.regions[i + 1]
            diff = abs(a.total - b.total)
            avg = (a.total + b.total) / 2.0 + 1
            if diff / avg < 0.3:  # similar enough
                merged = Region(a.start, b.end)
                merged.reads = a.reads + b.reads
                merged.writes = a.writes + b.writes
                self.regions[i:i+2] = [merged]
            else:
                i += 1

        # split: hot regions that are large
        if len(self.regions) >= self.max_regions:
            return
        avg_total = sum(r.total for r in self.regions) / max(len(self.regions), 1) + 1
        new_regions = []
        for r in self.regions:
            if r.total > avg_total * 2 and r.size > 1000 and len(new_regions) + (len(self.regions) - len(new_regions)) < self.max_regions:
                mid = (r.start + r.end) // 2
                a = Region(r.start, mid)
                b = Region(mid, r.end)
                a.reads = r.reads // 2
                a.writes = r.writes // 2
                b.reads = r.reads - a.reads
                b.writes = r.writes - a.writes
                new_regions.extend([a, b])
            else:
                new_regions.append(r)
        self.regions = new_regions

    def reset_counts(self):
        for r in self.regions:
            r.reads = 0
            r.writes = 0

    def snapshot(self):
        return [(r.start, r.end, r.reads, r.writes) for r in self.regions]


def main():
    parser = argparse.ArgumentParser(description="SAMON - Storage Access MONitor")
    parser.add_argument("-i", "--interval", type=float, default=2.0, help="aggregation interval in seconds")
    parser.add_argument("-d", "--duration", type=float, default=0, help="total duration (0=infinite)")
    parser.add_argument("-o", "--output", type=str, default="samon_log.csv", help="CSV output file")
    parser.add_argument("-s", "--max-sector", type=int, default=500000000, help="max sector of device")
    parser.add_argument("--min-regions", type=int, default=8, help="minimum regions")
    parser.add_argument("--max-regions", type=int, default=128, help="maximum regions")
    parser.add_argument("-q", "--quiet", action="store_true", help="suppress terminal output")
    args = parser.parse_args()

    b = BPF(text=bpf_text)
    # Auto-detect block I/O submission function for kernel compatibility
    # 5.9+: blk_mq_submit_bio, 5.8: submit_bio_noacct, <5.8: generic_make_request
    bio_func = None
    for func in ["blk_mq_submit_bio", "submit_bio_noacct", "generic_make_request"]:
        if BPF.ksymname(func) != -1:
            bio_func = func
            break
    if not bio_func:
        print("Error: no supported block I/O function found in this kernel.")
        exit(1)
    b.attach_kprobe(event=bio_func, fn_name="trace_bio")
    if not args.quiet:
        print(f"Attached to {bio_func}")

    ar = AdaptiveRegions(args.max_sector, args.min_regions, args.max_regions)

    def handle_event(cpu, data, size):
        e = b["events"].event(data)
        ar.record(e.sector, bool(e.rwflag))

    b["events"].open_perf_buffer(handle_event, page_cnt=64)

    csvfile = open(args.output, "w", newline="")
    writer = csv.writer(csvfile)
    writer.writerow(["timestamp", "elapsed_s", "region_id", "start_sector", "end_sector", "reads", "writes"])

    start_time = time()
    interval_num = 0

    if not args.quiet:
        print(f"SAMON started | interval={args.interval}s | output={args.output}")
        print(f"Ctrl+C to stop\n")

    try:
        while True:
            # poll for events during the interval
            deadline = time() + args.interval
            while time() < deadline:
                b.perf_buffer_poll(timeout=100)

            interval_num += 1
            elapsed = time() - start_time
            snap = ar.snapshot()
            ts = strftime("%H:%M:%S")

            # write CSV
            for i, (s, e, r, w) in enumerate(snap):
                writer.writerow([ts, f"{elapsed:.1f}", i, s, e, r, w])
            csvfile.flush()

            # terminal output
            if not args.quiet:
                total_r = sum(x[2] for x in snap)
                total_w = sum(x[3] for x in snap)
                nr = len(ar.regions)
                print(f"[{ts}] +{elapsed:.0f}s | regions={nr} | R={total_r} W={total_w}")

                blocks = " ░▒▓█"
                max_val = max(max(x[2]+x[3] for x in snap), 1)
                sys.stdout.write("  ")
                for s, e, r, w in snap:
                    idx = min(int((r+w) * (len(blocks)-1) / max_val), len(blocks)-1)
                    sys.stdout.write(blocks[idx])
                print()

            # adapt regions then reset
            ar.adapt()
            ar.reset_counts()

            if args.duration > 0 and elapsed >= args.duration:
                break

    except KeyboardInterrupt:
        pass

    csvfile.close()
    if not args.quiet:
        print(f"\nLog saved to {args.output}")

if __name__ == "__main__":
    main()
