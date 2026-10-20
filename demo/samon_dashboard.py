#!/usr/bin/env python3
"""samon_dashboard.py — SAMON 라이브 대시보드 (시연 도구, 구현의 기반 아님).

saddr가 내보내는 debugfs 파일을 주기적으로 읽어 터미널에 보여 준다.
  /sys/kernel/debug/samon/stats    누적 카운터 -> 초당 변화량
  /sys/kernel/debug/samon/streams  Stream_Table, Loop_History
  /sys/kernel/debug/samon/wb_hist  최근 60초 write segment 수
  /sys/fs/cgroup/<cg>/memory.stat  --cgroup으로 고른 cgroup(기본 samon_on, samon_off)의 page cache
                                   LRU 상태(active_file, inactive_file, pgactivate, pgdeactivate)
lba_page_map은 읽지 않는다(엔트리가 많으면 읽는 동안 LBA 트리 spinlock을 오래 잡는다).
cgroup 패널은 시나리오 -A(같은 단계를 토글 on/off로 각 cgroup에서 실행)의 비교를 보여 준다.

시나리오 스크립트(demo/samon_demo_scenario.sh)가 쓰는 phase 파일이 있으면
현재 단계 이름과 설명, 경과 시간을 머리에 보여 주고, --record CSV에도 남긴다.

usage:
  sudo python3 demo/samon_dashboard.py                 # 라이브 화면 (Ctrl-C로 종료)
  sudo python3 demo/samon_dashboard.py --record run.csv
  sudo python3 demo/samon_dashboard.py --once --svg shot.svg   # 한 화면만 그리고 종료

debugfs와 kdamond sysfs는 root만 읽을 수 있다. 화면은 rich(시스템 패키지 python3-rich)로 그린다.
"""
from __future__ import annotations

import argparse
import csv
import os
import platform
import re
import sys
import time
from collections import deque
from typing import Iterable

try:
    from rich.console import Console, Group
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:  # pragma: no cover - 환경 문제를 바로 알린다
    sys.exit("rich가 없다: sudo apt install python3-rich")

# ---------------------------------------------------------------------------
# 상수
# ---------------------------------------------------------------------------
# (번호, 이름, 판정 조건 요약, 토글을 켰을 때의 조작, 색)
PATTERNS = (
    (1, "순차 read", "demote", "cyan"),
    (2, "재읽기", "promote", "green"),
    (3, "loop read", "promote/demote", "magenta"),
    (4, "순차 write", "demote", "yellow"),
    (5, "hot write", "mark_accessed", "red"),
    (6, "기타", "-", "grey62"),
)
DROP_REASONS = ("queue", "stale", "revalidate", "toggle", "shutdown")
SPARK = " ▁▂▃▄▅▆▇█"
HIST_KEYS = tuple(f"det_p{n}" for n in range(1, 7)) + ("rq_seen", "req_all", "exec_all")
KD_DEF = "/sys/kernel/mm/damon/admin/kdamonds"
PARM_DEF = "/sys/module/saddr/parameters"
DBG_DEF = "/sys/kernel/debug/samon"
PHASE_DEF = "/run/samon_demo/phase"
LRU_GEN = "/sys/kernel/mm/lru_gen/enabled"
CGROOT_DEF = "/sys/fs/cgroup"
CG_DEF = "samon_on,samon_off"     # samon_demo_scenario.sh -A가 만드는 cgroup
# cgroup memory.stat에서 보여 주고 기록하는 키
CG_KEYS = ("file", "active_file", "inactive_file", "pgactivate", "pgdeactivate",
           "pgscan", "pgsteal", "workingset_refault_file")

_KV_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(\S+)")


# ---------------------------------------------------------------------------
# 파서 (순수 함수)
# ---------------------------------------------------------------------------
def read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _int(s: str) -> int | None:
    try:
        return int(s, 0)
    except ValueError:
        return None


def parse_stats(text: str) -> dict[str, int]:
    """`key=value` 줄을 읽는다. 한 줄에 여러 쌍이 있으면(entries=.. max_entries=..) 모두 읽는다."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        for k, v in _KV_RE.findall(line):
            n = _int(v)
            if n is not None:
                out[k] = n
    add_derived(out)
    return out


def add_derived(d: dict[str, int]) -> None:
    """패턴별 drop 합(drop_pN), 전체 req/exec/drop_queue 합을 더한다."""
    req = exe = dq = 0
    have = False
    for n in range(1, 6):
        if f"req_p{n}" in d:
            have = True
            req += d[f"req_p{n}"]
            exe += d.get(f"exec_p{n}", 0)
        s = sum(d.get(f"drop_{r}_p{n}", 0) for r in DROP_REASONS)
        d[f"drop_p{n}"] = s
        dq += d.get(f"drop_queue_p{n}", 0)
    if have:
        d["req_all"] = req
        d["exec_all"] = exe
        d["drop_queue_all"] = dq


def _kv_line(line: str) -> dict[str, str]:
    return dict(_KV_RE.findall(line))


def parse_streams(text: str) -> tuple[dict[str, str], list[dict[str, str]], list[dict[str, str]]]:
    """streams 파일 -> (머리 줄 값, stream 칸 목록, loop 기록 목록)."""
    head: dict[str, str] = {}
    slots: list[dict[str, str]] = []
    loops: list[dict[str, str]] = []
    for line in text.splitlines():
        if line.startswith("#"):
            head.update(_kv_line(line))
        elif line.startswith("stream "):
            slots.append(_kv_line(line))
        elif line.startswith("loop "):
            loops.append(_kv_line(line))
    return head, slots, loops


def parse_wb_hist(text: str) -> list[int]:
    """wb_hist 파일 -> 오래된 구간부터의 write 수 목록."""
    vals: list[tuple[int, int]] = []
    for line in text.splitlines():
        kv = _kv_line(line)
        if "t" in kv and "writes" in kv:
            t, w = _int(kv["t"]), _int(kv["writes"])
            if t is not None and w is not None:
                vals.append((t, w))
    vals.sort()
    return [w for _, w in vals]


def parse_memstat(text: str) -> dict[str, int]:
    """cgroup v2 memory.stat (`key value` 줄) -> dict."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            n = _int(parts[1])
            if n is not None:
                out[parts[0]] = n
    return out


def parse_phase(text: str | None) -> tuple[str, str, float | None]:
    """phase 파일 `이름<TAB>설명<TAB>시작 epoch초` -> (이름, 설명, 시작 시각)."""
    if not text:
        return "-", "", None
    parts = text.rstrip("\n").split("\t")
    name = parts[0] if parts and parts[0] else "-"
    desc = parts[1] if len(parts) > 1 else ""
    start = None
    if len(parts) > 2:
        try:
            start = float(parts[2])
        except ValueError:
            start = None
    return name, desc, start


def kernel_hz(default: int = 1000) -> int:
    txt = read_text(f"/boot/config-{platform.release()}")
    if txt:
        m = re.search(r"^CONFIG_HZ=(\d+)$", txt, re.M)
        if m:
            return int(m.group(1))
    return default


# ---------------------------------------------------------------------------
# 표시 도우미
# ---------------------------------------------------------------------------
def fmt_num(v: float | None) -> str:
    if v is None:
        return "—"
    a = abs(v)
    if a >= 1e6:
        return f"{v / 1e6:.1f}M"
    if a >= 1e4:
        return f"{v / 1e3:.0f}k"
    if a >= 1e3:
        return f"{v / 1e3:.1f}k"
    return f"{v:.0f}"


def spark(vals: Iterable[float | None], width: int, vmax: float | None = None) -> str:
    vs = list(vals)[-width:]
    if not vs:
        return ""
    m = vmax if vmax is not None else max((v for v in vs if v is not None), default=0)
    out = []
    for v in vs:
        if v is None:          # 아직 표본 없음
            out.append(" ")
        elif v <= 0 or m <= 0:  # 0: 점으로 표시해 '측정했고 0'임을 보인다
            out.append("·")
        else:                   # 0보다 크면 가장 낮은 막대 이상
            i = round(v / m * (len(SPARK) - 1))
            out.append(SPARK[max(1, min(len(SPARK) - 1, i))])
    return "".join(out).rjust(width)


def share_bar(parts: list[tuple[float, str]], width: int) -> Text:
    total = sum(max(0.0, p) for p, _ in parts)
    t = Text()
    if total <= 0:
        t.append("·" * width, style="grey35")
        return t
    used = 0
    for i, (p, style) in enumerate(parts):
        n = round(max(0.0, p) / total * width) if i < len(parts) - 1 else width - used
        n = max(0, min(n, width - used))
        t.append("█" * n, style=style)
        used += n
    return t


def mib(sectors: int) -> float:
    return sectors * 512 / 1048576


# ---------------------------------------------------------------------------
# 표본 수집
# ---------------------------------------------------------------------------
class Sampler:
    def __init__(self, args: argparse.Namespace):
        self.a = args
        self.stats: dict[str, int] = {}
        self.base: dict[str, int] | None = None
        self.prev: dict[str, int] | None = None
        self.prev_t: float | None = None
        self.rates: dict[str, float] = {}
        self.hist = {k: deque(maxlen=args.hist) for k in HIST_KEYS}
        self.error: str | None = None
        self.streams: tuple[dict[str, str], list[dict[str, str]], list[dict[str, str]]] | None = None
        self.wb: list[int] = []
        self.params: dict[str, str | None] = {}
        self.kd: dict[str, str | None] = {}
        self.phase = ("-", "", None)
        self.t0 = time.time()
        # cgroup 이름 -> memory.stat 값 (cgroup이 없으면 None)
        self.cg_names = [c for c in args.cgroup.split(",") if c] if args.cgroup else []
        self.cg: dict[str, dict[str, int] | None] = {c: None for c in self.cg_names}

    def _param(self, name: str) -> str | None:
        v = read_text(os.path.join(self.a.param, name))
        return v.strip() if v is not None else None

    def sample(self) -> None:
        now = time.monotonic()
        text = read_text(os.path.join(self.a.dbg, "stats"))
        if text is None:
            self.error = (f"{self.a.dbg}/stats를 읽을 수 없다. root로 실행했는지, "
                          "SAMON 커널(6.8.0-SAMON)인지 확인한다.")
            self.rates = {}
        else:
            self.error = None
            cur = parse_stats(text)
            if self.base is None:
                self.base = dict(cur)
            if self.prev is not None and self.prev_t is not None and now > self.prev_t:
                dt = now - self.prev_t
                # 누적 카운터가 줄어들면(재부팅 없이는 생기지 않음) 그 표본은 값 없음으로 둔다
                self.rates = {k: (cur[k] - self.prev[k]) / dt for k in cur
                              if k in self.prev and cur[k] >= self.prev[k]}
            else:
                self.rates = {}
            self.prev, self.prev_t, self.stats = cur, now, cur
        for k in HIST_KEYS:
            self.hist[k].append(self.rates.get(k))

        if not self.a.no_streams:
            st = read_text(os.path.join(self.a.dbg, "streams"))
            self.streams = parse_streams(st) if st is not None else None
        wb = read_text(os.path.join(self.a.dbg, "wb_hist"))
        self.wb = parse_wb_hist(wb) if wb is not None else []

        for n in ("samon_act_p1", "samon_act_p2", "samon_act_p3", "samon_act_p4",
                  "samon_opt_b", "samon_q_len", "samon_seq_min", "samon_dbg_lba",
                  "samon_dev_major", "samon_dev_minor"):
            self.params[n] = self._param(n)
        kd0 = os.path.join(self.a.kd, "0")
        self.kd = {
            "nr": (read_text(os.path.join(self.a.kd, "nr_kdamonds")) or "").strip() or None,
            "state": (read_text(os.path.join(kd0, "state")) or "").strip() or None,
            "ops": (read_text(os.path.join(kd0, "contexts/0/operations")) or "").strip() or None,
            "sample_us": (read_text(os.path.join(kd0, "contexts/0/monitoring_attrs/intervals/sample_us"))
                          or "").strip() or None,
        }
        self.kd["lru_gen"] = (read_text(LRU_GEN) or "").strip() or None
        self.phase = parse_phase(read_text(self.a.phase_file))
        for c in self.cg_names:
            ms = read_text(os.path.join(self.a.cgroot, c, "memory.stat"))
            self.cg[c] = parse_memstat(ms) if ms is not None else None

    def since(self, k: str) -> int | None:
        if self.base is None or k not in self.stats or k not in self.base:
            return None
        return self.stats[k] - self.base[k]

    def toggle(self, n: int) -> bool | None:
        v = self.params.get("samon_opt_b" if n == 5 else f"samon_act_p{n}")
        if v is None:
            return None
        return v in ("1", "Y", "y")


# ---------------------------------------------------------------------------
# 화면 조각
# ---------------------------------------------------------------------------
def _onoff(v: bool | None) -> Text:
    if v is None:
        return Text("?", style="grey50")
    return Text("on", style="bold green") if v else Text("off", style="grey50")


def render_head(s: Sampler) -> Panel:
    kd = s.kd
    state = kd.get("state") or "없음"
    ops = kd.get("ops") or "-"
    st_style = "bold green" if state == "on" and ops == "saddr" else "bold red"
    line1 = Text()
    line1.append("SAMON live  ", style="bold")
    line1.append("kdamond ")
    line1.append(f"{state}", style=st_style)
    line1.append(f" (ops={ops}, sample_us={kd.get('sample_us') or '-'})   ")
    line1.append(f"q_cap {s.stats.get('q_cap', '-')} / q_len {s.params.get('samon_q_len') or '-'}   ")
    line1.append(f"dev {s.params.get('samon_dev_major') or '-'}:{s.params.get('samon_dev_minor') or '-'}   ")
    line1.append(f"lru_gen {kd.get('lru_gen') or '-'}   ")
    line1.append(time.strftime("%H:%M:%S"), style="grey62")

    name, desc, start = s.phase
    line2 = Text()
    line2.append("단계 ")
    line2.append(f" {name} ", style="bold black on bright_white" if name != "-" else "grey50")
    if desc:
        line2.append(f"  {desc}")
    if start is not None:
        line2.append(f"   ({time.time() - start:5.1f}s)", style="grey62")
    if s.error:
        line2 = Text(s.error, style="bold red")
    elif state != "on":
        line2.append("   kdamond가 꺼져 있어 카운터가 멈춰 있다", style="bold yellow")
    return Panel(Group(line1, line2), padding=(0, 1))


def render_patterns(s: Sampler, width: int) -> Panel:
    t = Table(expand=True, box=None, pad_edge=False)
    t.add_column("패턴", no_wrap=True, min_width=4)
    t.add_column("의미", no_wrap=True, min_width=10)
    t.add_column("조작", no_wrap=True, min_width=14)
    t.add_column("토글", justify="center", no_wrap=True, min_width=4)
    t.add_column("seg/s", justify="right", no_wrap=True, min_width=6)
    t.add_column(f"최근 {width}표본", no_wrap=True, min_width=width, overflow="crop")
    t.add_column("누적", justify="right", no_wrap=True, min_width=6)
    parts = []
    for n, name, act, color in PATTERNS:
        k = f"det_p{n}"
        r = s.rates.get(k)
        parts.append((r or 0.0, color))
        t.add_row(Text(f"P{n}", style=f"bold {color}"), name, act,
                  _onoff(s.toggle(n)) if n <= 5 else Text("-", style="grey50"),
                  Text(fmt_num(r), style="bold" if r else ""),
                  Text(spark(s.hist[k], width), style=color),
                  fmt_num(s.since(k)))
    bar = Text("직전 표본 분포 ")
    bar.append_text(share_bar(parts, max(10, width + 30)))
    sub = "segment마다 정확히 하나로 판정 (우선순위 P3 > P1 > P2 > P4 > P5 > P6)"
    return Panel(Group(t, Text(""), bar), title="패턴 감지 det_pN", subtitle=sub, padding=(0, 1))


def render_queue(s: Sampler) -> Panel:
    t = Table(expand=True, box=None, pad_edge=False)
    for c, j in (("", "left"), ("req/s", "right"), ("exec/s", "right"), ("drop/s", "right"),
                 ("req", "right"), ("exec", "right"), ("drop q/st/rv/tg/sd", "right")):
        t.add_column(c, justify=j, no_wrap=True)
    for n, _, _, color in PATTERNS[:5]:
        drops = "/".join(fmt_num(s.since(f"drop_{r}_p{n}")) for r in DROP_REASONS)
        t.add_row(Text(f"P{n}", style=f"bold {color}"),
                  fmt_num(s.rates.get(f"req_p{n}")), fmt_num(s.rates.get(f"exec_p{n}")),
                  fmt_num(s.rates.get(f"drop_p{n}")),
                  fmt_num(s.since(f"req_p{n}")), fmt_num(s.since(f"exec_p{n}")), drops)
    foot = Text()
    foot.append(f"q_cur {s.stats.get('q_cur', '-')}   q_max_delay_us {s.stats.get('q_max_delay_us', '-')}   ")
    dop = s.stats.get("direct_ops")
    foot.append(f"direct_ops {dop if dop is not None else '-'}",
                style="bold red" if dop else "green")
    dq = s.since("drop_queue_all")
    if dq:
        foot.append(f"   큐 가득 참 유실 +{fmt_num(dq)}", style="bold yellow")
    toggles = [s.toggle(n) for n in range(1, 6)]
    sub = ("토글이 모두 off: 감지·집계만 하고 큐에 넣지 않는다" if toggles and not any(toggles)
           else "완료 콜백은 큐에 넣기만, kdamond가 sample 주기마다 실행")
    return Panel(Group(t, Text(""), foot), title="Deferred_Queue (req = exec + drop + q_cur)",
                 subtitle=sub, padding=(0, 1))


def render_streams(s: Sampler, hz: int, rows: int) -> Panel:
    if s.a.no_streams:
        return Panel(Text("--no-streams", style="grey50"), title="Stream_Table")
    if s.streams is None:
        return Panel(Text("streams 파일 없음", style="grey50"), title="Stream_Table")
    head, slots, loops = s.streams
    now = _int(head.get("now", "")) if head.get("now") else None
    seq_min = _int(s.params.get("samon_seq_min") or "") or 4
    t = Table(expand=True, box=None, pad_edge=False)
    for c, j in (("dir", "left"), ("시작 MiB", "right"), ("길이 MiB", "right"),
                 ("count", "right"), ("흐름", "left"), ("L MiB", "right"), ("idle ms", "right")):
        t.add_column(c, justify=j, no_wrap=True)

    def tl(x: dict[str, str]) -> int:
        return _int(x.get("t_last", "0")) or 0

    for x in sorted(slots, key=tl, reverse=True)[:rows]:
        start = _int(x.get("start", "0")) or 0
        end = _int(x.get("end", "0")) or 0
        cnt = _int(x.get("count", "0")) or 0
        loop = x.get("loop") == "1"
        d = x.get("dir", "?")
        if loop:
            kind = Text("LOOP → P3", style="bold magenta")
        elif cnt >= seq_min:
            kind = Text("순차 → P1" if d == "r" else "순차 → P4",
                        style="bold cyan" if d == "r" else "bold yellow")
        else:
            kind = Text("후보", style="grey62")
        idle = "—"
        if now is not None:
            idle = f"{max(0, now - tl(x)) * 1000 // hz}"
        t.add_row(d, f"{mib(start):.0f}", f"{mib(end - start):.1f}", str(cnt), kind,
                  f"{mib(_int(x.get('L', '0')) or 0):.0f}" if loop else "", idle)
    nr = sum(1 for x in slots if x.get("dir") == "r")
    nw = len(slots) - nr
    cap = f"사용 칸 r {nr} / w {nw} (방향마다 {head.get('stream_slots', '-')})   " \
          f"Loop_History 기록 {len(loops)} / {head.get('loop_slots', '-')}"
    if not slots:
        t.add_row("", "", "", "", Text("추적 중인 흐름 없음", style="grey50"), "", "")
    return Panel(t, title="Stream_Table (최근 갱신 순)", subtitle=cap, padding=(0, 1))


def render_entry(s: Sampler) -> Panel:
    t = Table(expand=True, box=None, pad_edge=False)
    t.add_column("", no_wrap=True)
    t.add_column("/s", justify="right", no_wrap=True)
    t.add_column("시작 이후", justify="right", no_wrap=True)
    rows = (("rq_seen", "관측 request"), ("seg_buffered", "buffered segment"),
            ("skip_anon", "제외: direct(anon)"), ("skip_pinned", "제외: direct(pinned)"),
            ("skip_nomap", "제외: mapping 없음"), ("skip_dev", "제외: 다른 디스크"),
            ("skip_passthru", "제외: passthrough"), ("drop_full", "LBA 트리 포화"))
    for k, label in rows:
        t.add_row(label, fmt_num(s.rates.get(k)), fmt_num(s.since(k)))
    ctx = Text(f"완료 컨텍스트(시작 이후) softirq {fmt_num(s.since('ctx_softirq'))}  "
               f"hardirq {fmt_num(s.since('ctx_hardirq'))}  task {fmt_num(s.since('ctx_task'))}",
               style="grey70")
    return Panel(Group(t, ctx), title="관측 (block_rq_complete)", padding=(0, 1))


def active_bar(active: int, inactive: int, width: int) -> Text:
    t = Text()
    total = active + inactive
    if total <= 0:
        t.append("·" * width, style="grey35")
        return t
    n = round(active / total * width)
    t.append("█" * n, style="green")
    t.append("█" * (width - n), style="grey35")
    return t


def render_lru(s: Sampler) -> Panel:
    """cgroup별 page cache LRU 상태. 값은 cgroup이 만들어진 뒤의 누적(pg*)과 현재 크기(*_file)."""
    title = "page cache 반영 (cgroup memory.stat)"
    if not s.cg_names:
        return Panel(Text("--cgroup 없음", style="grey50"), title=title)
    t = Table(expand=True, box=None, pad_edge=False)
    for c, j, w in (("cgroup", "left", 9), ("active MiB", "right", 10), ("inactive MiB", "right", 12),
                    ("active 비율", "left", 17), ("pgactivate", "right", 10),
                    ("pgdeactivate", "right", 12), ("scan", "right", 4)):
        t.add_column(c, justify=j, no_wrap=True, min_width=w)
    present = 0
    for c in s.cg_names:
        m = s.cg.get(c)
        if m is None:
            t.add_row(c, Text("없음", style="grey50"), "", "", "", "", "")
            continue
        present += 1
        act, ina = m.get("active_file", 0), m.get("inactive_file", 0)
        bar = active_bar(act, ina, 12)
        bar.append(f" {100 * act / (act + ina):3.0f}%" if act + ina else "")
        scan = m.get("pgscan", 0)
        t.add_row(Text(c, style="bold"), f"{act / 1048576:.1f}", f"{ina / 1048576:.1f}", bar,
                  fmt_num(m.get("pgactivate")), fmt_num(m.get("pgdeactivate")),
                  Text(fmt_num(scan), style="bold yellow" if scan else ""))
    sub = "pg*: cgroup 생성 이후 누적 · scan > 0이면 회수 발생 · MGLRU pgdeactivate는 이미 오래된 page도 셈"
    if not present:
        sub = "cgroup이 아직 없다 (sudo bash demo/samon_demo_scenario.sh -A ...)"
    return Panel(t, title=title, subtitle=sub, padding=(0, 1))


def render_wb(s: Sampler, width: int) -> Panel:
    if not s.wb:
        return Panel(Text("wb_hist 없음", style="grey50"), title="write segment / 1s (최근 60s)")
    line = Text(spark(s.wb, min(width, len(s.wb))), style="yellow")
    line.append(f"  max {max(s.wb)}  now {s.wb[-1]}", style="grey70")
    return Panel(line, title="write segment / 1s (wb_hist, 최근 60s)", padding=(0, 1))


def render(s: Sampler, args: argparse.Namespace, hz: int) -> Layout:
    # 고정 높이: 패턴 6행 + 머리 + 빈 줄 + 분포 막대 + 테두리 = 11, 관측 표 8행 + 머리 + ctx + 테두리 = 12
    lay = Layout()
    lay.split_column(Layout(render_head(s), name="head", size=4), Layout(name="body"))
    lay["body"].split_row(Layout(name="left", ratio=3), Layout(name="right", ratio=2))
    parts = [Layout(render_patterns(s, args.hist), name="pat", size=11),
             Layout(render_queue(s), name="queue", ratio=1)]
    if s.cg_names:   # 머리 + cgroup 행 + 테두리
        parts.append(Layout(render_lru(s), name="lru", size=3 + len(s.cg_names)))
    parts.append(Layout(render_wb(s, 60), name="wb", size=3))
    lay["left"].split_column(*parts)
    lay["right"].split_column(Layout(render_streams(s, hz, args.rows), name="streams", ratio=1),
                              Layout(render_entry(s), name="entry", size=12))
    return lay


# ---------------------------------------------------------------------------
# 기록
# ---------------------------------------------------------------------------
REC_COLS = (["ts", "elapsed_s", "phase"]
            + [f"det_p{n}" for n in range(1, 7)]
            + [f"req_p{n}" for n in range(1, 6)]
            + [f"exec_p{n}" for n in range(1, 6)]
            + ["drop_queue_all", "rq_seen", "q_cur"])


def cg_col(cg: str, key: str) -> str:
    return f"cg_{cg}_{key}"


def rec_columns(cg_names: Iterable[str]) -> list[str]:
    """기록 열: 고정 열 + cgroup마다 CG_KEYS (현재 값, 초당 변화량이 아님)."""
    return list(REC_COLS) + [cg_col(c, k) for c in cg_names for k in CG_KEYS]


class Recorder:
    def __init__(self, path: str | None, cg_names: Iterable[str] = ()):
        self.f = None
        self.w = None
        self.cg_names = list(cg_names)
        self.cols = rec_columns(self.cg_names)
        if path:
            new = not os.path.exists(path) or os.path.getsize(path) == 0
            if not new:
                with open(path, newline="") as f:
                    head = next(csv.reader(f), [])
                if head != self.cols:
                    raise SystemExit(f"{path}의 열 구성이 이번 설정(--cgroup)과 다르다. "
                                     "새 파일 이름을 쓰거나 기존 파일을 옮긴다.")
            self.f = open(path, "a", newline="")
            self.w = csv.writer(self.f)
            if new:
                self.w.writerow(self.cols)

    def write(self, s: Sampler) -> None:
        if not self.w or not s.rates:
            return
        row: list[object] = [f"{time.time():.3f}", f"{time.time() - s.t0:.2f}", s.phase[0]]
        for c in REC_COLS[3:]:
            if c == "q_cur":
                row.append(s.stats.get("q_cur", ""))
            else:
                v = s.rates.get(c)
                row.append("" if v is None else f"{v:.1f}")
        for c in self.cg_names:
            m = s.cg.get(c)
            for k in CG_KEYS:
                row.append("" if m is None or k not in m else m[k])
        self.w.writerow(row)
        self.f.flush()

    def close(self) -> None:
        if self.f:
            self.f.close()


# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="SAMON live dashboard (debugfs 기반 시연 도구)")
    p.add_argument("-i", "--interval", type=float, default=1.0, help="표본 간격 초 (기본 1)")
    p.add_argument("--hist", type=int, default=30, help="sparkline 길이(표본 수, 기본 30)")
    p.add_argument("--rows", type=int, default=8, help="Stream_Table에 보여 줄 칸 수 (기본 8)")
    p.add_argument("--record", metavar="CSV", help="표본마다 초당 변화량을 CSV에 덧붙인다")
    p.add_argument("--once", action="store_true", help="두 번 표본을 뜬 뒤 한 화면만 출력하고 끝낸다")
    p.add_argument("--samples", type=int, default=2, help="--once에서 출력 전에 뜰 표본 수 (기본 2)")
    p.add_argument("--svg", metavar="FILE", help="--once 화면을 SVG로 저장")
    p.add_argument("--width", type=int, help="--once 출력 폭")
    p.add_argument("--height", type=int, default=42, help="--once 출력 높이 (기본 42)")
    p.add_argument("--no-streams", action="store_true", help="streams 파일을 읽지 않는다")
    p.add_argument("--hz", type=int, help="커널 HZ (기본: /boot/config의 CONFIG_HZ)")
    p.add_argument("--cgroup", default=CG_DEF,
                   help=f"memory.stat을 보여 줄 cgroup 이름, 쉼표로 구분 (기본 {CG_DEF}, 빈 문자열이면 패널 없음)")
    p.add_argument("--cgroot", default=CGROOT_DEF, help=argparse.SUPPRESS)
    p.add_argument("--dbg", default=DBG_DEF, help=argparse.SUPPRESS)
    p.add_argument("--param", default=PARM_DEF, help=argparse.SUPPRESS)
    p.add_argument("--kd", default=KD_DEF, help=argparse.SUPPRESS)
    p.add_argument("--phase-file", default=PHASE_DEF, help=argparse.SUPPRESS)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.interval <= 0 or args.hist < 1 or args.rows < 1:
        print("interval > 0, hist >= 1, rows >= 1", file=sys.stderr)
        return 2
    if args.dbg == DBG_DEF and os.geteuid() != 0:
        print("debugfs를 읽으려면 root가 필요하다: sudo python3 " + sys.argv[0], file=sys.stderr)
        return 2
    hz = args.hz or kernel_hz()
    s = Sampler(args)
    rec = Recorder(args.record, s.cg_names)
    try:
        if args.once:
            s.sample()
            for _ in range(max(1, args.samples - 1)):
                time.sleep(args.interval)
                s.sample()
                rec.write(s)
            con = Console(record=bool(args.svg), width=args.width, height=args.height)
            con.print(render(s, args, hz), height=args.height)
            if args.svg:
                con.save_svg(args.svg, title="SAMON dashboard")
            return 0
        s.sample()
        with Live(render(s, args, hz), screen=True, auto_refresh=False) as live:
            while True:
                time.sleep(args.interval)
                s.sample()
                rec.write(s)
                live.update(render(s, args, hz), refresh=True)
    except KeyboardInterrupt:
        return 0
    finally:
        rec.close()


if __name__ == "__main__":
    sys.exit(main())
