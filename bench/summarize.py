#!/usr/bin/env python3
"""Summarize samon_bench.sh runs.csv: mean/std per mode, difference vs the
'off' baseline, and the baseline-vs-baseline difference (off vs off2) as the
noise reference.  A difference is only called real if it exceeds both the
baseline noise and 2 standard deviations of the baseline; this is a rough
screening rule, not a significance test (few repetitions)."""
import csv, sys, statistics as st
from collections import defaultdict

path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
if not rows:
    sys.exit("no rows")
modes = ["off", "off2", "on_noB", "on_B"]
metrics = [k for k in rows[0].keys() if k not in ("run", "mode", "rep")]
data = defaultdict(lambda: defaultdict(list))
for r in rows:
    for m in metrics:
        data[r["mode"]][m].append(float(r[m]))

def mean(m, k): return st.mean(data[m][k]) if data[m][k] else float("nan")
def sd(m, k):   return st.stdev(data[m][k]) if len(data[m][k]) > 1 else 0.0
def pct(a, b):  return 0.0 if b == 0 else 100.0 * (a - b) / b

print(f"runs: {len(rows)}; reps per mode: " +
      ", ".join(f"{m}={len(data[m][metrics[0]])}" for m in modes if m in data))
print()
print("| metric | " + " | ".join(f"{m} mean (sd)" for m in modes if m in data) +
      " | on_noB vs off | on_B vs off | on_B vs on_noB | noise (off2 vs off) | verdict on_B vs on_noB |")
print("|---|" + "---|" * (len([m for m in modes if m in data]) + 5))
for k in metrics:
    cells = [f"{mean(m,k):.1f} ({sd(m,k):.1f})" for m in modes if m in data]
    base = mean("off", k)
    d_noB = pct(mean("on_noB", k), base) if "on_noB" in data else float("nan")
    d_B = pct(mean("on_B", k), base) if "on_B" in data else float("nan")
    d_BB = pct(mean("on_B", k), mean("on_noB", k)) if "on_B" in data and "on_noB" in data else float("nan")
    noise = pct(mean("off2", k), base) if "off2" in data else float("nan")
    verdict = "n/a"
    if "on_B" in data and "on_noB" in data:
        delta = abs(mean("on_B", k) - mean("on_noB", k))
        floor = max(abs(mean("off2", k) - base) if "off2" in data else 0,
                    2 * max(sd("on_noB", k), sd("on_B", k)))
        verdict = "above noise" if delta > floor else "within noise"
    print(f"| {k} | " + " | ".join(cells) +
          f" | {d_noB:+.1f}% | {d_B:+.1f}% | {d_BB:+.1f}% | {noise:+.1f}% | {verdict} |")
