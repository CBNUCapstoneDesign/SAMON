#!/usr/bin/env python3
"""samon_demo_plot.py — 대시보드 기록(--record CSV)을 발표용 PNG 타임라인으로 그린다.

usage: python3 demo/samon_demo_plot.py run.csv -o samon_demo.png

위: 패턴별 초당 판정 segment 수(det_p1..p6, 누적 영역), 시나리오 단계 구간을 음영과 이름으로 표시
가운데: Deferred_Queue 초당 req / exec 합과 큐 가득 참 유실(drop_queue)
아래(기록에 cgroup 열이 있을 때만): cgroup별 active_file / inactive_file 크기 (시나리오 -A의 on/off 비교)
root가 필요 없다(matplotlib만 쓴다).
"""
from __future__ import annotations

import argparse
import csv
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

COLORS = {1: "#1f9fd6", 2: "#2ca02c", 3: "#b04fc4", 4: "#e0b000", 5: "#d62728", 6: "#9e9e9e"}
NAMES = {1: "P1 seq read", 2: "P2 reread", 3: "P3 loop", 4: "P4 seq write", 5: "P5 hot write", 6: "P6 other"}
SKIP_PHASES = {"-", "pause", "setup", "done"}


def fnum(s: str) -> float:
    try:
        return float(s)
    except (TypeError, ValueError):
        return 0.0


def load(path: str) -> list[dict[str, str]]:
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def cgroups_in(rows: list[dict[str, str]]) -> list[str]:
    """cg_<name>_active_file 열이 있고 값이 하나라도 있는 cgroup 이름."""
    if not rows:
        return []
    out = []
    for col in rows[0]:
        if col.startswith("cg_") and col.endswith("_active_file"):
            name = col[3:-len("_active_file")]
            if any(r.get(col) for r in rows):
                out.append(name)
    return out


def phase_spans(rows: list[dict[str, str]], t: list[float]) -> list[tuple[str, float, float]]:
    """연속된 같은 phase 구간 -> (이름, 시작, 끝)."""
    spans: list[tuple[str, float, float]] = []
    cur, start = None, 0.0
    for r, x in zip(rows, t):
        p = r.get("phase", "-")
        if p != cur:
            if cur is not None:
                spans.append((cur, start, x))
            cur, start = p, x
    if cur is not None and t:
        spans.append((cur, start, t[-1]))
    return spans


def plot(rows: list[dict[str, str]], out: str, title: str) -> None:
    if not rows:
        raise SystemExit("CSV에 데이터 행이 없다")
    t0 = fnum(rows[0]["elapsed_s"])
    t = [fnum(r["elapsed_s"]) - t0 for r in rows]
    cgs = cgroups_in(rows)
    if cgs:
        fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(13, 9.5), sharex=True,
                                            gridspec_kw={"height_ratios": [3, 1.3, 1.6]})
    else:
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 7), sharex=True,
                                       gridspec_kw={"height_ratios": [3, 1.3]})
        ax3 = None
    ys = [[fnum(r[f"det_p{n}"]) for r in rows] for n in range(1, 7)]
    ax1.stackplot(t, *ys, labels=[NAMES[n] for n in range(1, 7)],
                  colors=[COLORS[n] for n in range(1, 7)], alpha=0.85, step="pre")
    ax1.set_ylabel("segments / s")
    ax1.legend(loc="upper left", ncol=6, fontsize=8, frameon=False)
    ax1.set_title(title)
    ymax = max((sum(col) for col in zip(*ys)), default=0) or 1
    ax1.set_ylim(0, ymax * 1.25)

    shade = False
    axes = (ax1, ax2) if ax3 is None else (ax1, ax2, ax3)
    for name, a, b in phase_spans(rows, t):
        if name in SKIP_PHASES:
            continue
        for ax in axes:
            ax.axvspan(a, b, color="#000000", alpha=0.06 if shade else 0.03, lw=0)
        ax1.text((a + b) / 2, ymax * 1.15, name, ha="center", va="center", fontsize=9)
        shade = not shade

    req = [fnum(r["req_p1"]) + fnum(r["req_p2"]) + fnum(r["req_p3"]) + fnum(r["req_p4"]) + fnum(r["req_p5"])
           for r in rows]
    exe = [fnum(r["exec_p1"]) + fnum(r["exec_p2"]) + fnum(r["exec_p3"]) + fnum(r["exec_p4"]) + fnum(r["exec_p5"])
           for r in rows]
    dq = [fnum(r["drop_queue_all"]) for r in rows]
    ax2.step(t, req, where="pre", label="req / s", color="#444444")
    ax2.step(t, exe, where="pre", label="exec / s", color="#1f9fd6")
    ax2.step(t, dq, where="pre", label="drop_queue / s", color="#d62728")
    ax2.set_ylabel("queue items / s")
    ax2.legend(loc="upper left", ncol=3, fontsize=8, frameon=False)
    if ax3 is not None:
        styles = ("-", "--", ":", "-.")
        for i, cg in enumerate(cgs):
            ls = styles[i % len(styles)]
            act = [fnum(r.get(f"cg_{cg}_active_file", "")) / 1048576 for r in rows]
            ina = [fnum(r.get(f"cg_{cg}_inactive_file", "")) / 1048576 for r in rows]
            ax3.step(t, act, where="post", ls=ls, color="#2ca02c", label=f"{cg} active_file")
            ax3.step(t, ina, where="post", ls=ls, color="#7f7f7f", label=f"{cg} inactive_file")
        ax3.set_ylabel("cgroup page cache (MiB)")
        ax3.legend(loc="upper left", ncol=4, fontsize=8, frameon=False)
        ax3.set_xlabel("time (s)")
    else:
        ax2.set_xlabel("time (s)")
    fig.tight_layout()
    fig.savefig(out, dpi=130)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="SAMON 대시보드 기록 CSV -> PNG 타임라인")
    p.add_argument("csv")
    p.add_argument("-o", "--output", default="samon_demo.png")
    p.add_argument("--title", default="SAMON pattern detection (saddr, block_rq_complete)")
    a = p.parse_args(argv)
    plot(load(a.csv), a.output, a.title)
    print(a.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
