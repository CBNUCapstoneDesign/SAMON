#!/usr/bin/env python3
"""samon_live_score.py — samon_live_ab.sh 시연 화면 (시연 도구).

한 화면에 세 가지를 보여 준다.
  1) 지금 실행 중인 단계(MGLRU / SAMON)와 경과 시간, 1초 refault/s 추이   ← cgroup samon_live memory.stat
  2) SAMON 패턴 판정(P1~P6)과 실제 조작 수의 초당 값                     ← /sys/kernel/debug/samon/stats
  3) 끝난 사이클마다 MGLRU 와 SAMON 의 refault/s, 변화율, 누적 평균         ← samon_live_ab.sh 의 CSV

usage: sudo python3 demo/samon_live_score.py [--csv /var/tmp/samon_live/cycles.csv] [--interval 1]
debugfs 를 읽으므로 root 가 필요하다. 화면은 rich(python3-rich).
"""
import argparse, csv, os, statistics, time
from collections import deque

from rich.console import Group
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

DBG = "/sys/kernel/debug/samon/stats"
CG = "/sys/fs/cgroup/samon_live/memory.stat"
PHASE = "/run/samon_demo/phase"
RUNNER_PID = "/run/samon_demo/runner.pid"
PATTERNS = [  # (번호, 이름, 조작) — samon_classifier=1 (Region_Classifier) 기준, kernel/README.md
    (1, "순차 read (scan)", "demote"),
    (2, "hot read", "mark_accessed (p2_mode=2)"),
    (3, "loop read", "앞 25%(상한) promote, 나머지 demote"),
    (4, "순차 write", "demote"),
    (5, "hot write", "(P5 끔)"),
    (6, "기타", "조작 없음"),
]
COLOR = {"MGLRU": "cyan", "SAMON": "red"}
SPARK = "▁▂▃▄▅▆▇█"


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def kv(text, sep="="):
    d = {}
    for line in (text or "").splitlines():
        if sep == "=":
            k, _, v = line.partition("=")
        else:
            k, _, v = line.partition(" ")
        try:
            d[k.strip()] = int(v.split()[0])
        except (ValueError, IndexError):
            pass
    return d


def spark(vals, width=60):
    v = list(vals)[-width:]
    if not v:
        return Text("")
    top = max(x for x, _ in v) or 1
    t = Text()
    for x, mode in v:
        t.append(SPARK[min(7, int(x / top * 7.999))], style=COLOR.get(mode, "white"))
    return t


class State:
    def __init__(self, a):
        self.a = a
        self.prev_st = None; self.prev_cg = None; self.prev_t = None
        self.hist = deque(maxlen=90)          # (refault/s, mode)
        self.rates = {}

    def tick(self):
        now = time.time()
        st = kv(read(DBG)); cgs = kv(read(CG), sep=" ")
        ph = (read(PHASE) or "-\t\t").rstrip("\n").split("\t")
        self.phase = (ph + ["", "", ""])[:3]
        if self.prev_t is not None:
            dt = now - self.prev_t
            if self.prev_st:
                self.rates = {k: max(0, st.get(k, 0) - self.prev_st.get(k, 0)) / dt for k in st}
            r = cgs.get("workingset_refault_file"); pr = (self.prev_cg or {}).get("workingset_refault_file")
            if r is not None and pr is not None and r >= pr:
                self.hist.append(((r - pr) / dt, self.phase[0]))
        self.prev_st, self.prev_cg, self.prev_t = st, cgs, now
        self.rows = []
        try:
            with open(self.a.csv) as f:
                self.rows = list(csv.DictReader(f))
        except OSError:
            pass


def runner_alive():
    try:
        pid = int(open(RUNNER_PID).read().strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def header(s):
    name, desc, start = s.phase
    if not runner_alive():
        t = Text()
        t.append(" 워크로드 실행 중 아님 ", style="bold white on dark_red")
        t.append(f"  실행기(samon_live_ab.sh)가 돌고 있지 않다. 아래 칸 메시지를 확인할 것.  마지막 상태: {name} {desc}")
        return Panel(t, title="SAMON 라이브 시연 — mixed 워크로드 (10/28 측정 조건)", border_style="red")
    el = ""
    try:
        el = f"{time.time() - float(start):5.0f}초"
    except ValueError:
        pass
    t = Text()
    t.append(f" {name} ", style=f"bold white on {COLOR.get(name, 'grey30')}")
    t.append(f"  {desc}  {el}")
    return Panel(t, title="SAMON 라이브 시연 — mixed 워크로드 (10/28 측정 조건)", border_style="white")


def live_panel(s):
    cur = s.hist[-1][0] if s.hist else 0.0
    t = Text()
    t.append("지금 refault/s  ", style="bold"); t.append(f"{cur:8.0f}\n", style=f"bold {COLOR.get(s.phase[0], 'white')}")
    t.append("최근 90초 (")
    t.append("■ MGLRU", style=COLOR["MGLRU"]); t.append("  "); t.append("■ SAMON", style=COLOR["SAMON"]); t.append(")\n")
    t.append_text(spark(s.hist, 90))
    return Panel(t, title="① 페이지 캐시 refault (cgroup samon_live, 1초 단위)", border_style="yellow")


def pattern_panel(s):
    tb = Table(expand=True, box=None)
    tb.add_column("패턴"); tb.add_column("판정/초", justify="right"); tb.add_column("조작/초", justify="right"); tb.add_column("SAMON 조작")
    on = s.phase[0] == "SAMON"
    mx = max([s.rates.get(f"det_p{n}", 0) for n, *_ in PATTERNS] + [1])
    for n, nm, act in PATTERNS:
        d = s.rates.get(f"det_p{n}", 0); e = s.rates.get(f"exec_p{n}", 0)
        bar = "█" * int(d / mx * 12)
        tb.add_row(f"P{n} {nm}", f"{d:9,.0f} [green]{bar}[/]", f"{e:9,.0f}", act)
    note = "" if on else "\n[dim]SAMON 이 꺼진 단계에서는 판정이 멈춘다 (kdamond off)[/]"
    if not runner_alive():
        note = "\n[bold red]실행기가 돌고 있지 않다: 여기 보이는 판정은 시연 워크로드가 아니라 다른 디스크 I/O 다[/]"
    rg = s.prev_st.get("rgn_nr", 0) if s.prev_st else 0
    return Panel(Group(tb, Text.from_markup(f"[dim]현재 DAMON region 라벨 수 rgn_nr={rg}[/]{note}")),
                 title="② SAMON 패턴 판정 (블록 요청 → 영역 라벨 → P1~P6)", border_style="green")


def cycle_panel(s):
    by = {}
    for r in s.rows:
        by.setdefault(int(r["cycle"]), {})[r["mode"]] = r
    tb = Table(expand=True)
    for c, j in (("사이클", "right"), ("MGLRU refault/s", "right"), ("SAMON refault/s", "right"), ("변화", "right"),
                 ("hot read IOPS (M→S)", "right")):
        tb.add_column(c, justify=j)
    offs, ons, wins, n = [], [], 0, 0
    for c in sorted(by)[-10:]:
        o, x = by[c].get("off"), by[c].get("samon")
        ov = float(o["refault_per_s"]) if o else None; xv = float(x["refault_per_s"]) if x else None
        ch = ""
        if ov and xv is not None:
            p = (xv - ov) / ov * 100; ch = f"[{'green' if p < 0 else 'red'}]{p:+.0f}%[/]"
        io = f"{float(o['hot_r_iops']):,.0f} → {float(x['hot_r_iops']):,.0f}" if o and x else ""
        tb.add_row(str(c), f"{ov:,.0f}" if ov is not None else "…", f"{xv:,.0f}" if xv is not None else "…", ch, io)
    for c in by:
        o, x = by[c].get("off"), by[c].get("samon")
        if o and x:
            ov, xv = float(o["refault_per_s"]), float(x["refault_per_s"]); offs.append(ov); ons.append(xv)
            n += 1; wins += xv < ov
    summ = Text()
    if n:
        mo, ms = statistics.mean(offs), statistics.mean(ons)
        summ.append(f"\n완료 사이클 {n}개 평균:  MGLRU {mo:,.0f}/s  →  SAMON {ms:,.0f}/s  ")
        summ.append(f"({(ms - mo) / mo * 100:+.0f}%)", style="bold green" if ms < mo else "bold red")
        summ.append(f"\nSAMON 이 더 낮았던 사이클: {wins}/{n}")
        w = 40; top = max(mo, ms) or 1
        summ.append("\nMGLRU " + "█" * int(mo / top * w), style=COLOR["MGLRU"])
        summ.append("\nSAMON " + "█" * int(ms / top * w), style=COLOR["SAMON"])
    summ.append("\n[참고] 한 사이클 값은 잡음이 크다 (같은 설정끼리도 ±25%). 평균을 본다.", style="dim")
    return Panel(Group(tb, summ), title="③ 사이클별 결과 (측정 40초 평균)", border_style="magenta")


def render(s):
    lay = Layout()
    lay.split_column(Layout(header(s), size=3), Layout(name="mid", size=13), Layout(cycle_panel(s)))
    lay["mid"].split_row(Layout(live_panel(s)), Layout(pattern_panel(s)))
    return lay


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="/var/tmp/samon_live/cycles.csv")
    ap.add_argument("--interval", type=float, default=1.0)
    a = ap.parse_args()
    if os.geteuid() != 0:
        raise SystemExit("root 필요: sudo python3 demo/samon_live_score.py")
    s = State(a); s.tick()
    with Live(render(s), refresh_per_second=4, screen=True) as lv:
        try:
            while True:
                time.sleep(a.interval); s.tick(); lv.update(render(s))
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
