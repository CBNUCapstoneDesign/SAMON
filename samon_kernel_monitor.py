#!/usr/bin/env python3
"""
SAMON Kernel Monitor - Collects data from DAMON saddr operation set
via damon_aggregated tracepoint and outputs CSV compatible with samon_plot.py
"""
import subprocess
import time
import csv
import argparse
import os
import signal
import re

def setup_damon(nr_regions=8, sample_us=100000, aggr_us=1000000):
    """Configure DAMON with saddr operation set via sysfs"""
    base = "/sys/kernel/mm/damon/admin/kdamonds"
    
    cmds = [
        f"echo 1 > {base}/nr_kdamonds",
        f"echo 1 > {base}/0/contexts/nr_contexts",
        f"echo saddr > {base}/0/contexts/0/operations",
        f"echo {sample_us} > {base}/0/contexts/0/monitoring_attrs/intervals/sample_us",
        f"echo {aggr_us} > {base}/0/contexts/0/monitoring_attrs/intervals/aggr_us",
        f"echo 1 > {base}/0/contexts/0/targets/nr_targets",
        f"echo {nr_regions} > {base}/0/contexts/0/targets/0/regions/nr_regions",
    ]
    
    # Set up initial regions spanning the LBA space (0 to 250M sectors)
    max_sector = 251658240
    step = max_sector // nr_regions
    for i in range(nr_regions):
        start = i * step
        end = (i + 1) * step if i < nr_regions - 1 else max_sector
        cmds.append(f"echo {start} > {base}/0/contexts/0/targets/0/regions/{i}/start")
        cmds.append(f"echo {end} > {base}/0/contexts/0/targets/0/regions/{i}/end")
    
    for cmd in cmds:
        os.system(cmd)

def start_damon():
    base = "/sys/kernel/mm/damon/admin/kdamonds/0"
    os.system(f"echo on > {base}/state")

def stop_damon():
    base = "/sys/kernel/mm/damon/admin/kdamonds/0"
    os.system(f"echo off > {base}/state")

def collect_trace(duration, output_csv, aggr_interval=1.0):
    """Collect damon_aggregated tracepoint data and write CSV"""
    trace_dir = "/sys/kernel/debug/tracing"
    
    # Enable tracepoint
    os.system(f"echo 0 > {trace_dir}/events/damon/damon_aggregated/enable")
    os.system(f"echo > {trace_dir}/trace")
    os.system(f"echo 1 > {trace_dir}/events/damon/damon_aggregated/enable")
    
    start_time = time.time()
    
    with open(output_csv, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp", "elapsed_s", "region_id", "start_sector", "end_sector", "reads", "writes"])
        
        last_read_time = start_time
        
        while time.time() - start_time < duration:
            time.sleep(aggr_interval)
            elapsed = time.time() - start_time
            ts = time.strftime("%H:%M:%S")
            
            # Read trace buffer
            with open(f"{trace_dir}/trace", "r") as tf:
                lines = tf.readlines()
            # Clear trace buffer
            os.system(f"echo > {trace_dir}/trace")
            
            # Parse damon_aggregated lines
            # Format: ... damon_aggregated: target_id=0 nr_regions=N START-END: NR_ACCESSES AGE
            region_id = 0
            for line in lines:
                if "damon_aggregated" not in line:
                    continue
                # Extract region info
                m = re.search(r'(\d+)-(\d+): (\d+) (\d+)', line)
                if m:
                    start = int(m.group(1))
                    end = int(m.group(2))
                    nr_accesses = int(m.group(3))
                    # We can't distinguish R/W from tracepoint alone,
                    # so put all in writes (block_rq_complete catches both)
                    writer.writerow([ts, f"{elapsed:.1f}", region_id, start, end, 0, nr_accesses])
                    region_id += 1
            
            if region_id > 0:
                f.flush()
                print(f"[{ts}] +{elapsed:.0f}s | regions={region_id}")
    
    # Disable tracepoint
    os.system(f"echo 0 > {trace_dir}/events/damon/damon_aggregated/enable")

def main():
    parser = argparse.ArgumentParser(description="SAMON Kernel Monitor (saddr)")
    parser.add_argument("-d", "--duration", type=float, default=60, help="duration in seconds")
    parser.add_argument("-o", "--output", type=str, default="samon_kernel_log.csv")
    parser.add_argument("-r", "--regions", type=int, default=8, help="initial number of regions")
    parser.add_argument("-s", "--sample-ms", type=int, default=100, help="sample interval in ms")
    parser.add_argument("-a", "--aggr-ms", type=int, default=1000, help="aggregation interval in ms")
    args = parser.parse_args()
    
    print(f"SAMON Kernel Monitor | duration={args.duration}s | output={args.output}")
    
    setup_damon(nr_regions=args.regions, 
                sample_us=args.sample_ms * 1000,
                aggr_us=args.aggr_ms * 1000)
    start_damon()
    print("DAMON started with saddr ops")
    
    try:
        collect_trace(args.duration, args.output, aggr_interval=args.aggr_ms/1000.0)
    except KeyboardInterrupt:
        pass
    finally:
        stop_damon()
        print(f"\nDone. Log saved to {args.output}")

if __name__ == "__main__":
    main()
