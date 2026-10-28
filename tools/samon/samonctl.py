"""samonctl.py — samon 제어 코어.

samon 명령어의 대화형 CLI(samon_cli.py)와 웹 서버(samon_web.py)는 모두 이 모듈로만
SAMON 상태를 읽고 바꾼다. sysfs 경로를 직접 다루는 곳은 이 파일 하나다.

  /sys/kernel/mm/damon/admin/kdamonds      감시 시작·정지, operations, 감시 간격
  /sys/module/saddr/parameters             패턴 토글과 성능 파라미터
  /sys/kernel/debug/samon/stats            누적 카운터 (읽기 전용)
  /sys/kernel/debug/samon/regions          Region_Classifier 라벨 표 (읽기 전용)
  /sys/block/*/size, /sys/dev/block/M:m    감시 시작 때 DAMON target region 범위(대상 디스크 크기)
  /run/samon/{snapshot.json,pending,lock}  복원용 스냅샷, 재시작 필요 항목, 쓰기 잠금

환경 변수 SAMON_SYSROOT를 주면 위 경로 앞에 붙인다(가짜 sysfs로 시험할 때 쓴다).
saddr.c는 바꾸지 않는다. 바꿀 수 있는 항목은 아래 ITEMS 표에 있는 것뿐이다.
감시를 켤 때 kdamond 0의 target region이 비어 있으면(nr_regions = 0) 대상 디스크 전체를 region
하나로 설정한다(Region_Classifier 입력). 이미 설정된 region은 바꾸지 않는다.
"""
from __future__ import annotations

import configparser
import json
import os
import re
import time
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass

try:
    import fcntl
except ImportError:  # pragma: no cover - 리눅스 밖에서 시험할 때만
    fcntl = None

KD_DEF = "/sys/kernel/mm/damon/admin/kdamonds"
PARM_DEF = "/sys/module/saddr/parameters"
DBG_DEF = "/sys/kernel/debug/samon"
LRUS_DEF = "/sys/module/damon_lru_sort/parameters/enabled"
LRU_GEN_DEF = "/sys/kernel/mm/lru_gen/enabled"
BLOCK_DEF = "/sys/block"
DEVBLK_DEF = "/sys/dev/block"
REGIONS = "contexts/0/targets/0/regions"
RUN_DEF = "/run/samon"
PROC_DEF = "/proc"
CONF_DEF = "/etc/samon/samon.conf"
ATTRS = "contexts/0/monitoring_attrs/intervals"
DEFAULT_PORT = 8765

DROP_REASONS = ("queue", "stale", "revalidate", "toggle", "shutdown")
U32_MAX = 0xFFFFFFFF


# ---------------------------------------------------------------------------
# 항목 정의표
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Item:
    name: str            # samon에서 쓰는 짧은 이름
    kind: str            # "toggle" | "param"
    where: str           # "param"(모듈 파라미터) | "attr"(kdamond 감시 간격) | "kd" | "device"
    file: str            # where 기준 상대 경로
    label: str
    lo: int = 0
    hi: int = U32_MAX
    apply: str = "now"   # "now" = 즉시 | "restart" = 다음 감시 시작
    main: bool = False   # 화면에서 먼저 보일 항목
    default: object = None  # 모듈 적재 시 기본값 (default 프리셋)


ITEMS: tuple[Item, ...] = (
    Item("monitor", "toggle", "kd", "0/state", "SAMON 감시 (kdamond saddr)"),
    Item("p1", "toggle", "param", "samon_act_p1", "P1 순차 read demote", default=False),
    Item("p2", "toggle", "param", "samon_act_p2", "P2 재읽기 promote", default=False),
    Item("p3", "toggle", "param", "samon_act_p3", "P3 loop read 조작", default=False),
    Item("p4", "toggle", "param", "samon_act_p4", "P4 순차 write demote", default=False),
    Item("p5", "toggle", "param", "samon_opt_b", "P5 hot write mark_accessed", default=True),
    Item("lba_map", "toggle", "param", "samon_dbg_lba",
         "SAMON_Map 신규 삽입 (요청 단위 판정에서 off면 P5 감지 안 됨)", default=True),
    Item("classifier", "toggle", "param", "samon_classifier",
         "region 기반 판정 (on: DAMON adaptive region, off: 요청 단위 판정)", default=True),
    Item("rgn_seq_kb", "param", "param", "samon_rgn_seq_kb", "region 판정: 큰 요청 기준 (KiB)",
         lo=0, main=True, default=64),
    Item("rgn_min_ios", "param", "param", "samon_rgn_min_ios", "region 판정: 주기당 최소 요청 수",
         lo=0, default=4),
    Item("rgn_hot_pct", "param", "param", "samon_rgn_hot_pct", "region 판정: hot nr_accesses 비율 (%)",
         lo=0, hi=100, main=True, default=50),
    Item("rgn_loop_gap", "param", "param", "samon_rgn_loop_gap", "region 판정: 재스캔 최소 공백 (집계 주기)",
         lo=0, default=3),
    Item("rgn_hold", "param", "param", "samon_rgn_hold", "region 판정: scan 이력 유지 (집계 주기)",
         lo=1, default=100),

    Item("hot_threshold", "param", "param", "samon_hot_threshold", "hot 판정 접근 횟수",
         lo=1, main=True, default=10),
    Item("window_ms", "param", "param", "samon_window_ms", "hot 판정 관측 창 (ms)",
         lo=1, main=True, default=1000),
    Item("reread_ms", "param", "param", "samon_reread_ms", "재읽기 판정 간격 (ms)",
         lo=1, main=True, default=10000),
    Item("seq_min", "param", "param", "samon_seq_min", "순차 판정 최소 연속 수",
         lo=1, main=True, default=4),
    Item("loop_protect_pct", "param", "param", "samon_loop_protect_pct", "loop 보호 비율 (%)",
         lo=0, hi=100, main=True, default=50),
    Item("device", "param", "device", "", "관측 대상 디스크 major:minor (0:0 = 전체)",
         main=True, default="0:0"),
    Item("max_entries", "param", "param", "samon_max_entries", "LBA 트리 최대 항목 수",
         lo=1, default=65536),
    Item("q_max_ms", "param", "param", "samon_q_max_ms", "큐 대기 시간 상한 (ms)",
         lo=1, default=100),
    Item("stream_new_kb", "param", "param", "samon_stream_new_kb", "새 stream 시작 최소 크기 (KiB)",
         lo=1, default=64),
    Item("stream_gap_req", "param", "param", "samon_stream_gap_req", "stream 간격 허용 배수",
         lo=1, default=2),
    Item("stream_idle_ms", "param", "param", "samon_stream_idle_ms", "stream idle 판정 (ms)",
         lo=1, default=1000),
    Item("loop_min_kb", "param", "param", "samon_loop_min_kb", "loop 기록 최소 길이 (KiB)",
         lo=1, default=8192),
    Item("q_len", "param", "param", "samon_q_len", "per-CPU 큐 크기",
         lo=1, apply="restart", default=1024),
    Item("stream_slots", "param", "param", "samon_stream_slots", "Stream_Table 칸 수",
         lo=1, apply="restart", default=16),
    Item("loop_slots", "param", "param", "samon_loop_slots", "Loop_History 칸 수",
         lo=1, apply="restart", default=16),
    Item("reread_slots", "param", "param", "samon_reread_slots", "Reread_Table 칸 수",
         lo=1, apply="restart", default=65536),
    Item("sample_us", "param", "attr", "sample_us", "DAMON 표본 간격 (us)",
         lo=1, hi=2**63 - 1, apply="restart"),
    Item("aggr_us", "param", "attr", "aggr_us", "DAMON 집계 간격 (us)",
         lo=1, hi=2**63 - 1, apply="restart"),
)
ITEM = {it.name: it for it in ITEMS}
PATTERN_TOGGLES = ("p1", "p2", "p3", "p4", "p5")

BUILTIN_PRESETS: dict[str, dict[str, object]] = {
    "observe": {"monitor": True, **{p: False for p in PATTERN_TOGGLES}},
    "all": {"monitor": True, **{p: True for p in PATTERN_TOGGLES}},
    "default": {it.name: it.default for it in ITEMS if it.default is not None},
}


class SamonError(Exception):
    """사용자에게 그대로 보여 줄 수 있는 실패 사유."""


# ---------------------------------------------------------------------------
# 값 변환 (순수 함수)
# ---------------------------------------------------------------------------
_TRUE = {"1", "y", "yes", "on", "true"}
_FALSE = {"0", "n", "no", "off", "false"}


def parse_bool(v: object) -> bool:
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in _TRUE:
        return True
    if s in _FALSE:
        return False
    raise SamonError(f"on/off 값이 아니다: {v!r}")


def parse_device(v: object) -> tuple[int, int]:
    m = re.fullmatch(r"\s*(\d+)\s*:\s*(\d+)\s*", str(v))
    if not m:
        raise SamonError(f"device는 major:minor 형식이다 (예: 8:0, 전체는 0:0): {v!r}")
    major, minor = int(m.group(1)), int(m.group(2))
    if major > U32_MAX or minor > U32_MAX:
        raise SamonError(f"device 번호가 너무 크다: {v!r}")
    return major, minor


def coerce(it: Item, v: object) -> object:
    """사용자가 준 값을 검증해 항목 형식(bool / int / 'maj:min')으로 바꾼다."""
    if it.kind == "toggle":
        return parse_bool(v)
    if it.where == "device":
        major, minor = parse_device(v)
        return f"{major}:{minor}"
    if isinstance(v, bool):
        raise SamonError(f"{it.name}: 숫자가 필요하다")
    try:
        n = int(str(v).strip(), 10)
    except ValueError:
        raise SamonError(f"{it.name}: 정수가 필요하다: {v!r}") from None
    if not it.lo <= n <= it.hi:
        rng = f"{it.lo} 이상" if it.hi >= U32_MAX else f"{it.lo}~{it.hi}"
        raise SamonError(f"{it.name}: 범위는 {rng}이다 (받은 값 {n})")
    return n


# ---------------------------------------------------------------------------
# stats 파서 (demo/samon_dashboard.py와 같은 형식)
# ---------------------------------------------------------------------------
_KV_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(\S+)")


def parse_stats(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        for k, v in _KV_RE.findall(line):
            try:
                out[k] = int(v, 0)
            except ValueError:
                pass
    req = exe = dq = 0
    have = False
    for n in range(1, 6):
        if f"req_p{n}" in out:
            have = True
            req += out[f"req_p{n}"]
            exe += out.get(f"exec_p{n}", 0)
        out[f"drop_p{n}"] = sum(out.get(f"drop_{r}_p{n}", 0) for r in DROP_REASONS)
        dq += out.get(f"drop_queue_p{n}", 0)
    if have:
        out["req_all"], out["exec_all"], out["drop_queue_all"] = req, exe, dq
        out["drop_all"] = sum(out[f"drop_p{n}"] for n in range(1, 6))
    return out


RATE_KEYS = tuple(f"det_p{n}" for n in range(1, 7)) + (
    "rq_seen", "seg_buffered", "req_all", "exec_all", "drop_all", "drop_queue_all")


class Sampler:
    """stats를 주기적으로 읽어 초당 변화량과 최근 이력을 만든다."""

    def __init__(self, ctl: "Ctl", hist: int = 60):
        self.ctl = ctl
        self.stats: dict[str, int] = {}
        self.rates: dict[str, float] = {}
        self.hist: dict[str, deque] = {k: deque(maxlen=hist) for k in RATE_KEYS}
        self.error: str | None = None
        self._prev: dict[str, int] | None = None
        self._prev_t: float | None = None

    def sample(self) -> None:
        now = time.monotonic()
        text = self.ctl.read_text(self.ctl.dbg, "stats")
        if text is None:
            self.error = "debugfs stats를 읽을 수 없다 (root 권한, SAMON 커널, debugfs 마운트 확인)"
            self.rates, self._prev = {}, None
        else:
            self.error = None
            cur = parse_stats(text)
            if self._prev is not None and self._prev_t is not None and now > self._prev_t:
                dt = now - self._prev_t
                # 카운터가 줄었으면(모듈 재적재 등) 그 표본은 버린다
                self.rates = {k: (cur[k] - self._prev[k]) / dt for k in cur
                              if k in self._prev and cur[k] >= self._prev[k]}
            else:
                self.rates = {}
            self._prev, self._prev_t, self.stats = cur, now, cur
        for k in RATE_KEYS:
            self.hist[k].append(self.rates.get(k))

    def as_dict(self) -> dict:
        return {"error": self.error, "stats": self.stats, "rates": self.rates,
                "hist": {k: list(v) for k, v in self.hist.items()}}


# ---------------------------------------------------------------------------
# 성능·자원 지표 (/proc)
# ---------------------------------------------------------------------------
REGION_COLS = ("start", "end", "acc", "rd_big", "rd_small", "wr_big", "wr_small",
               "rd_kb", "wr_kb", "flags", "last_scan", "span_start", "span_len")
REGION_FLAGS = {"S": "scan", "L": "loop", "H": "hot_r", "W": "seqw", "w": "hot_w"}


def parse_regions(text: str) -> dict:
    """debugfs regions 원문 → {"head": {"iv":.., "nr":.., "max_acc":.., "classifier":..}, "rows": [...]}.
    줄 형식은 saddr.c samon_regions_show()와 같다. 숫자 열은 int, flags는 문자열."""
    head: dict[str, int] = {}
    rows: list[dict] = []
    for line in text.splitlines():
        if line.startswith("# iv="):
            for tok in line[2:].split():
                k, _, v = tok.partition("=")
                if v.isdigit():
                    head[k] = int(v)
            continue
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != len(REGION_COLS):
            continue
        r: dict = {}
        for k, v in zip(REGION_COLS, parts):
            r[k] = v if k == "flags" else (int(v) if v.isdigit() else None)
        rows.append(r)
    return {"head": head, "rows": rows}


def parse_kv_table(text: str) -> dict[str, int]:
    """/proc/meminfo(`이름: 값 kB`)와 /proc/vmstat(`이름 값`)을 읽는다."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.replace(":", " ").split()
        if len(parts) >= 2:
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return out


def parse_cpu(text: str) -> tuple[int, int, int] | None:
    """/proc/stat -> (busy tick, 전체 tick, CPU 수). busy = 전체 - idle - iowait."""
    busy = total = None
    ncpu = 0
    for line in text.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "cpu":
            v = [int(x) for x in f[1:9]]
            total = sum(v)
            busy = total - v[3] - (v[4] if len(v) > 4 else 0)
        elif re.fullmatch(r"cpu\d+", f[0]):
            ncpu += 1
    return (busy, total, max(ncpu, 1)) if total is not None else None


def parse_pid_ticks(text: str) -> int | None:
    """/proc/<pid>/stat -> utime + stime (tick). comm에 공백이 있을 수 있어 마지막 ')' 뒤를 센다."""
    rest = text[text.rfind(")") + 1:].split()
    try:
        return int(rest[11]) + int(rest[12])   # 14, 15번째 필드
    except (IndexError, ValueError):
        return None


# 화면에 보이는 지표: (키, 이름, 단위, 낮을수록 좋은가)
SYS_METRICS = (
    ("cpu_pct", "전체 CPU 사용률", "%", True),
    ("kd_cpu_pct", "kdamond CPU, SAMON 오버헤드", "%, 1코어 기준", True),
    ("mem_used_mb", "사용 메모리 (MemTotal - MemAvailable)", "MiB", True),
    ("cached_mb", "page cache (Cached)", "MiB", None),
    ("active_file_mb", "Active(file)", "MiB", None),
    ("inactive_file_mb", "Inactive(file)", "MiB", None),
    ("majflt_s", "major fault", "/s", True),
    ("refault_s", "page cache refault", "/s", True),
    ("pgpgin_kb_s", "디스크 read", "KiB/s", True),
    ("pgpgout_kb_s", "디스크 write", "KiB/s", None),
)
SYS_KEYS = tuple(m[0] for m in SYS_METRICS)
BASELINE_WINDOW = 30


def _mean(vals) -> float | None:
    xs = [v for v in vals if v is not None]
    return sum(xs) / len(xs) if xs else None


class SysSampler:
    """/proc에서 CPU, 메모리, page cache 관련 지표를 표본으로 뜨고 기준 구간과 비교한다.

    refault는 page cache에서 밀려났다가 곧 다시 읽힌 page 수로, 줄어들면 cache가 필요한 page를
    더 잘 지킨다는 뜻이다. major fault와 디스크 read도 같은 워크로드라면 낮을수록 좋다.
    """

    _COUNTERS = {"majflt_s": "pgmajfault", "pgpgin_kb_s": "pgpgin", "pgpgout_kb_s": "pgpgout"}

    def __init__(self, ctl: "Ctl", hist: int = 60):
        self.ctl = ctl
        self.cur: dict[str, float | None] = {}
        self.hist: dict[str, deque] = {k: deque(maxlen=hist) for k in SYS_KEYS}
        self.error: str | None = None
        self.ncpu = 1
        self.total_mb = 0.0
        self.baseline: dict | None = None
        self._prev: dict[str, float] | None = None
        self._prev_t: float | None = None
        self._kd_pid: int | None = None
        try:
            self.hz = os.sysconf("SC_CLK_TCK")
        except (AttributeError, ValueError, OSError):
            self.hz = 100

    def _raw(self) -> dict[str, float]:
        raw: dict[str, float] = {}
        cpu = parse_cpu(self.ctl.read_text(self.ctl.proc, "stat") or "")
        if cpu:
            raw["cpu_busy"], raw["cpu_total"], self.ncpu = cpu
        vm = parse_kv_table(self.ctl.read_text(self.ctl.proc, "vmstat") or "")
        for key, name in self._COUNTERS.items():
            if name in vm:
                raw[key] = vm[name]
        ref = vm.get("workingset_refault_file", vm.get("workingset_refault"))
        if ref is not None:
            raw["refault_s"] = ref
        pid = self.ctl.kd_pid()
        if pid is not None:
            t = parse_pid_ticks(self.ctl.read_text(self.ctl.proc, str(pid), "stat") or "")
            if t is not None:
                raw["kd_ticks"], raw["kd_pid"] = t, pid
        return raw

    def sample(self) -> None:
        now = time.monotonic()
        mem = parse_kv_table(self.ctl.read_text(self.ctl.proc, "meminfo") or "")
        raw = self._raw()
        self.error = None if mem and "cpu_total" in raw else "/proc를 읽을 수 없다"
        cur: dict[str, float | None] = {k: None for k in SYS_KEYS}
        if "MemTotal" in mem and "MemAvailable" in mem:
            cur["mem_used_mb"] = (mem["MemTotal"] - mem["MemAvailable"]) / 1024
        for k, name in (("cached_mb", "Cached"), ("active_file_mb", "Active(file)"),
                        ("inactive_file_mb", "Inactive(file)")):
            if name in mem:
                cur[k] = mem[name] / 1024
        p, dt = self._prev, (now - self._prev_t) if self._prev_t is not None else 0
        if p is not None and dt > 0:
            if "cpu_total" in raw and "cpu_total" in p and raw["cpu_total"] > p["cpu_total"]:
                cur["cpu_pct"] = 100 * (raw["cpu_busy"] - p["cpu_busy"]) / (raw["cpu_total"] - p["cpu_total"])
            for k in (*self._COUNTERS, "refault_s"):
                if k in raw and k in p and raw[k] >= p[k]:
                    cur[k] = (raw[k] - p[k]) / dt
            if "kd_ticks" in raw and p.get("kd_pid") == raw["kd_pid"] and raw["kd_ticks"] >= p["kd_ticks"]:
                cur["kd_cpu_pct"] = 100 * (raw["kd_ticks"] - p["kd_ticks"]) / self.hz / dt
        self._prev, self._prev_t, self.cur = raw, now, cur
        self.total_mb = mem.get("MemTotal", 0) / 1024
        for k in SYS_KEYS:
            self.hist[k].append(cur[k])

    def recent(self, n: int = BASELINE_WINDOW) -> dict[str, float | None]:
        return {k: _mean(list(self.hist[k])[-n:]) for k in SYS_KEYS}

    def set_baseline(self, label: str = "") -> dict:
        self.baseline = {"time": time.time(), "label": label, "values": self.recent()}
        return self.baseline

    def clear_baseline(self) -> None:
        self.baseline = None

    def as_dict(self) -> dict:
        return {"error": self.error, "cur": self.cur, "recent": self.recent(),
                "hist": {k: list(v) for k, v in self.hist.items()},
                "baseline": self.baseline, "window": BASELINE_WINDOW,
                "ncpu": self.ncpu, "mem_total_mb": self.total_mb,
                "metrics": [{"key": k, "label": lb, "unit": u, "lower_better": lo}
                            for k, lb, u, lo in SYS_METRICS]}


# ---------------------------------------------------------------------------
# 제어
# ---------------------------------------------------------------------------
class Ctl:
    def __init__(self, root: str | None = None, conf: str | None = None):
        root = os.environ.get("SAMON_SYSROOT", "") if root is None else root
        j = (lambda p: os.path.join(root, p.lstrip("/"))) if root else (lambda p: p)
        self.kd, self.parm, self.dbg = j(KD_DEF), j(PARM_DEF), j(DBG_DEF)
        self.lrus, self.lru_gen, self.run = j(LRUS_DEF), j(LRU_GEN_DEF), j(RUN_DEF)
        self.block, self.devblk = j(BLOCK_DEF), j(DEVBLK_DEF)
        self.proc = j(PROC_DEF)
        self.conf = conf if conf is not None else j(CONF_DEF)

    # --- 저수준 읽기/쓰기 ------------------------------------------------
    @staticmethod
    def read_text(*parts: str) -> str | None:
        try:
            with open(os.path.join(*parts), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None

    def _rd(self, *parts: str) -> str | None:
        v = self.read_text(*parts)
        return v.strip() if v is not None else None

    def _wr(self, path: str, value: str) -> None:
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(f"{value}\n")
        except OSError as e:
            raise SamonError(f"쓰기 실패: {path} <- {value} ({e.strerror or e})") from None

    def _wr_check(self, path: str, value: str) -> None:
        """쓰고 다시 읽어 확인한다 (bool 파라미터는 Y/N으로 읽힌다)."""
        self._wr(path, value)
        got = self._rd(path)
        if got == value or (got, value) in (("Y", "1"), ("N", "0")):
            return
        raise SamonError(f"다시 읽은 값이 다르다: {path} = {got!r} (쓴 값 {value!r})")

    def _path(self, it: Item) -> str:
        if it.where == "param":
            return os.path.join(self.parm, it.file)
        if it.where == "attr":
            return os.path.join(self.kd, "0", ATTRS, it.file)
        return os.path.join(self.kd, it.file)

    # --- 항목 읽기 ------------------------------------------------------
    def get(self, name: str) -> object:
        """항목의 현재값. 읽을 수 없으면 None."""
        it = self._item(name)
        if it.name == "monitor":
            return self.kd_state() == "on" and self.kd_ops() == "saddr"
        if it.where == "device":
            ma, mi = self._rd(self.parm, "samon_dev_major"), self._rd(self.parm, "samon_dev_minor")
            return f"{ma}:{mi}" if ma is not None and mi is not None else None
        raw = self._rd(self._path(it))
        if raw is None:
            return None
        try:
            return parse_bool(raw) if it.kind == "toggle" else int(raw, 10)
        except (SamonError, ValueError):
            return None

    def _item(self, name: str) -> Item:
        it = ITEM.get(name)
        if it is None:
            raise SamonError(f"알 수 없는 항목: {name!r} (항목 목록은 도움말 참조)")
        return it

    def kd_nr(self) -> int:
        v = self._rd(self.kd, "nr_kdamonds")
        return int(v) if v and v.isdigit() else 0

    def kd_state(self) -> str | None:
        return self._rd(self.kd, "0", "state") if self.kd_nr() >= 1 else None

    def kd_ops(self) -> str | None:
        return self._rd(self.kd, "0", "contexts", "0", "operations") if self.kd_nr() >= 1 else None

    def kd_pid(self) -> int | None:
        """동작 중인 kdamond 0의 pid. 꺼져 있으면 None (DAMON sysfs는 -1을 보인다)."""
        v = self._rd(self.kd, "0", "pid") if self.kd_nr() >= 1 else None
        return int(v) if v and v.isdigit() and int(v) > 0 else None

    def lru_sort_on(self) -> bool:
        v = self._rd(self.lrus)
        return v is not None and v.lower() in ("y", "1")

    def status(self) -> dict:
        values = {it.name: self.get(it.name) for it in ITEMS}
        toggles = [values[p] for p in PATTERN_TOGGLES]
        return {
            "values": values,
            "kdamond": {"state": self.kd_state(), "ops": self.kd_ops(),
                        "target_regions": self.target_regions()},
            "observe_only": bool(values["monitor"]) and not any(t for t in toggles),
            "pending_restart": self.pending(),
            "has_snapshot": os.path.exists(os.path.join(self.run, "snapshot.json")),
            "lru_sort_on": self.lru_sort_on(),
            "lru_gen": self._rd(self.lru_gen),
            "saddr_loaded": os.path.isdir(self.parm),
            "kernel": os.uname().release if hasattr(os, "uname") else "",
        }

    # --- 잠금, 스냅샷, 재시작 필요 목록 ---------------------------------
    @contextmanager
    def _locked(self):
        os.makedirs(self.run, exist_ok=True)
        with open(os.path.join(self.run, "lock"), "w") as f:
            if fcntl:
                fcntl.flock(f, fcntl.LOCK_EX)
            try:
                yield
            finally:
                if fcntl:
                    fcntl.flock(f, fcntl.LOCK_UN)

    def _snapshot_if_first(self) -> None:
        """samon이 처음 값을 바꾸기 직전 상태를 저장한다. 이미 있으면 그대로 둔다."""
        path = os.path.join(self.run, "snapshot.json")
        if os.path.exists(path):
            return
        snap = {"time": time.time(), "nr_kdamonds": self.kd_nr(),
                "state": self.kd_state(), "ops": self.kd_ops(), "values": {}}
        for it in ITEMS:
            if it.name != "monitor":
                v = self.get(it.name)
                if v is not None:
                    snap["values"][it.name] = v
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snap, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)

    def pending(self) -> list[str]:
        txt = self.read_text(self.run, "pending")
        return [x for x in (txt or "").split() if x in ITEM]

    def _set_pending(self, names: list[str]) -> None:
        path = os.path.join(self.run, "pending")
        if names:
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(sorted(set(names))) + "\n")
        elif os.path.exists(path):
            os.remove(path)

    # --- 쓰기 -----------------------------------------------------------
    def set(self, name: str, value: object) -> object:
        """항목 하나를 바꾸고 다시 읽은 값을 돌려준다."""
        it = self._item(name)
        v = coerce(it, value)
        with self._locked():
            self._snapshot_if_first()
            self._set_locked(it, v)
        return self.get(name)

    def _set_locked(self, it: Item, v: object) -> None:
        if it.name == "monitor":
            self._monitor_on() if v else self._monitor_off()
            return
        if not os.path.isdir(self.parm):
            raise SamonError(f"saddr 모듈 파라미터가 없다: {self.parm} (SAMON 커널인지 확인)")
        if it.where == "device":
            major, minor = parse_device(v)
            self._wr_check(os.path.join(self.parm, "samon_dev_major"), str(major))
            self._wr_check(os.path.join(self.parm, "samon_dev_minor"), str(minor))
        elif it.where == "attr":
            if self.kd_nr() < 1:
                raise SamonError("kdamond가 없다. 감시를 한 번 켜서 kdamond를 만든 뒤 바꾼다")
            self._wr_check(self._path(it), str(v))
        else:
            self._wr_check(self._path(it), ("1" if v else "0") if it.kind == "toggle" else str(v))
        if it.apply == "restart" and self.kd_state() == "on":
            self._set_pending(self.pending() + [it.name])

    def apply_many(self, values: dict[str, object]) -> list[str]:
        """여러 항목을 차례로 바꾼다. 감시 on은 다른 항목을 다 쓴 뒤에 한다. 실패 사유 목록을 돌려준다."""
        checked = {n: coerce(self._item(n), v) for n, v in values.items()}
        errors: list[str] = []
        with self._locked():
            self._snapshot_if_first()
            order = [n for n in checked if n != "monitor"]
            if "monitor" in checked:
                order = (["monitor"] + order) if not checked["monitor"] else (order + ["monitor"])
            for n in order:
                try:
                    self._set_locked(ITEM[n], checked[n])
                except SamonError as e:
                    errors.append(str(e))
        return errors

    def preset_names(self) -> list[str]:
        return list(BUILTIN_PRESETS) + [n for n in self.user_presets() if n not in BUILTIN_PRESETS]

    def user_presets(self) -> dict[str, dict[str, str]]:
        cp = configparser.ConfigParser()
        try:
            cp.read(self.conf, encoding="utf-8")
        except configparser.Error:
            return {}
        return {s.split(":", 1)[1].strip(): dict(cp[s]) for s in cp.sections()
                if s.startswith("preset:") and s.split(":", 1)[1].strip()}

    def preset(self, name: str) -> list[str]:
        values = BUILTIN_PRESETS.get(name) or self.user_presets().get(name)
        if values is None:
            raise SamonError(f"알 수 없는 프리셋: {name!r} ({', '.join(self.preset_names())})")
        return self.apply_many(dict(values))

    def web_port(self) -> int:
        cp = configparser.ConfigParser()
        try:
            cp.read(self.conf, encoding="utf-8")
            return cp.getint("web", "port", fallback=DEFAULT_PORT)
        except (configparser.Error, ValueError):
            return DEFAULT_PORT

    # --- 감시 시작·정지 -------------------------------------------------
    def _wait_state(self, want: str, timeout: float = 10.0) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.kd_state() == want:
                return
            time.sleep(0.2)
        raise SamonError(f"kdamond 상태가 {want}로 바뀌지 않았다")

    def _monitor_off(self) -> None:
        if self.kd_state() in (None, "off"):
            return
        if self.kd_ops() != "saddr":
            raise SamonError(f"kdamond 0이 operations={self.kd_ops()}로 동작 중이다. samon은 saddr만 다룬다")
        self._wr(os.path.join(self.kd, "0", "state"), "off")
        self._wait_state("off")

    # --- DAMON target region (Region_Classifier 입력) --------------------
    def target_range(self) -> tuple[int, int] | None:
        """감시할 sector 범위 [0, 크기). 디스크 필터(device)가 있으면 그 디스크, 없으면 가장 큰 디스크.
        크기를 알 수 없으면 None."""
        ma, mi = self._rd(self.parm, "samon_dev_major"), self._rd(self.parm, "samon_dev_minor")
        size = None
        if ma and ma != "0" and mi is not None:
            v = self._rd(self.devblk, f"{ma}:{mi}", "size")
            size = int(v) if v and v.isdigit() else None
        else:
            try:
                names = sorted(os.listdir(self.block))
            except OSError:
                names = []
            for n in names:
                if n.startswith(("loop", "ram", "zram", "dm-", "md", "sr")):
                    continue
                v = self._rd(self.block, n, "size")
                if v and v.isdigit() and (size is None or int(v) > size):
                    size = int(v)
        return (0, size) if size else None

    def target_regions(self) -> int | None:
        """kdamond 0의 target region 수. 디렉터리가 없으면 None."""
        v = self._rd(self.kd, "0", REGIONS, "nr_regions")
        return int(v) if v and v.isdigit() else None

    def _setup_target_region(self) -> None:
        """target region이 비어 있으면(nr_regions = 0) 대상 디스크 전체 하나로 설정한다.
        이미 설정된 region(예: samon_kernel_monitor.py가 나눈 구간)은 건드리지 않는다.
        sysfs에 regions 디렉터리가 없거나 디스크 크기를 알 수 없으면 아무것도 하지 않는다."""
        rg = os.path.join(self.kd, "0", REGIONS)
        if not os.path.isdir(rg) or self.target_regions() != 0:
            return
        rng = self.target_range()
        if rng is None:
            return
        start, end = rng
        self._wr_check(os.path.join(rg, "nr_regions"), "1")
        self._wr_check(os.path.join(rg, "0", "start"), "0")
        self._wr_check(os.path.join(rg, "0", "end"), str(end))
        self._wr_check(os.path.join(rg, "0", "start"), str(start))

    def regions(self) -> dict:
        """debugfs regions(라벨 표)를 읽는다: {"head": {...}, "rows": [{...}, ...]}. 없으면 빈 rows."""
        return parse_regions(self.read_text(self.dbg, "regions") or "")

    def _monitor_on(self) -> None:
        if self.lru_sort_on():
            raise SamonError("DAMON_LRU_SORT가 켜져 있다. SAMON만 동작하도록 먼저 끈다 "
                             f"(echo N > {LRUS_DEF})")
        if not os.path.isdir(self.parm):
            raise SamonError(f"saddr 모듈 파라미터가 없다: {self.parm} (SAMON 커널인지 확인)")
        if not os.path.exists(os.path.join(self.kd, "nr_kdamonds")):
            raise SamonError(f"DAMON sysfs가 없다: {self.kd}")
        if self.kd_nr() < 1:
            self._wr(os.path.join(self.kd, "nr_kdamonds"), "1")
        state, ops = self.kd_state(), self.kd_ops()
        if state == "on":
            if ops != "saddr":
                raise SamonError(f"kdamond 0이 operations={ops}로 동작 중이다. 먼저 끈다")
            self._set_pending([])
            return
        ctx = os.path.join(self.kd, "0", "contexts")
        if (self._rd(ctx, "nr_contexts") or "0") == "0":
            self._wr(os.path.join(ctx, "nr_contexts"), "1")
        self._wr_check(os.path.join(ctx, "0", "operations"), "saddr")
        tg = os.path.join(ctx, "0", "targets")
        if (self._rd(tg, "nr_targets") or "0") == "0":
            self._wr(os.path.join(tg, "nr_targets"), "1")
        self._setup_target_region()
        self._wr(os.path.join(self.kd, "0", "state"), "on")
        self._wait_state("on")
        self._set_pending([])

    def monitor(self, action: str) -> None:
        """action: on | off | restart. restart는 재시작 필요 항목을 반영한다."""
        if action not in ("on", "off", "restart"):
            raise SamonError(f"알 수 없는 동작: {action!r}")
        with self._locked():
            self._snapshot_if_first()
            if action == "on":
                self._monitor_on()
            elif action == "off":
                self._monitor_off()
            else:
                self._monitor_off()
                self._monitor_on()

    # --- 복원 -----------------------------------------------------------
    def restore(self) -> list[str]:
        """스냅샷 시점으로 되돌린다. 실패 사유 목록을 돌려준다."""
        path = os.path.join(self.run, "snapshot.json")
        with self._locked():
            try:
                with open(path, encoding="utf-8") as f:
                    snap = json.load(f)
            except (OSError, ValueError):
                raise SamonError("되돌릴 스냅샷이 없다 (samon으로 아직 아무것도 바꾸지 않았다)") from None
            errors: list[str] = []
            was_on = snap.get("state") == "on" and snap.get("ops") == "saddr"
            try:
                self._monitor_off()
            except SamonError as e:
                errors.append(str(e))
            for n, v in snap.get("values", {}).items():
                it = ITEM.get(n)
                if it is None or (it.where == "attr" and self.kd_nr() < 1):
                    continue
                try:
                    self._set_locked(it, coerce(it, v))
                except SamonError as e:
                    errors.append(str(e))
            if was_on:
                try:
                    self._monitor_on()
                except SamonError as e:
                    errors.append(str(e))
            elif snap.get("nr_kdamonds") == 0 and self.kd_nr() >= 1 and self.kd_state() == "off":
                try:
                    self._wr(os.path.join(self.kd, "nr_kdamonds"), "0")  # samon이 만든 kdamond는 없앤다
                except SamonError as e:
                    errors.append(str(e))
            self._set_pending([])
            if not errors:
                os.remove(path)
            return errors


def need_root() -> str | None:
    """root가 아니면 안내 문구를 돌려준다. 가짜 sysfs(SAMON_SYSROOT)로 시험할 때는 묻지 않는다."""
    if os.environ.get("SAMON_SYSROOT"):
        return None
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        return "samon은 sysfs와 debugfs를 다루므로 root가 필요하다: sudo samon"
    return None
