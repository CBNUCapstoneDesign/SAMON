#!/usr/bin/env python3
"""samon_benchlib.py — S4 Bench_Harness 보조 라이브러리 (design T6, Data Models).

bash(samon_bench.sh)는 실행 순서와 sysfs 쓰기만 맡고, runs.csv의 열 정의·행 생성·
스냅샷 파싱·차분·fio JSON 해석은 이 파일이 맡는다. 열 정의가 `COLUMNS` 하나이므로
헤더와 행의 열 수가 어긋나지 않는다(R10.12). Python 3.12, 표준 라이브러리만 쓴다.

모듈 구성
  - COLUMNS, SAMON_STATS_KEYS, LRU_SORT_STATS_KEYS : 열 정의 (단일 출처)
  - parse_*                                         : 스냅샷 원문 문자열 → 값 (순수 함수)
  - diff_*                                          : pre/post 차분 (순수 함수)
  - fio_metrics, cachestat_hit_pct                  : fio JSON, cachestat 해석 (순수 함수)
  - load_snapshot, collect_values                   : 스냅샷 디렉터리 → {열: 값}
  - row_from_values, header_line, row_line          : {열: 값} → CSV (없는 값은 NA)
  - damon_inactive_mark, q_warn_mark, parse_passes_csv, loop_summary
                                                    : 실행 표시·loop 완주 계산 (순수 함수)
  - run_order (= order)                             : 반복별 구성 순서 (순수 함수, R10.13)
  - main                                            : argparse 하위 명령 (header, row, order)

표시 열의 출처 (design T6, R10.5·R10.6·R11.4·R11.7)
  fio_rc                                    하네스가 --set/--state-file로 준다 (EXTERNAL_COLS)
  damon_inactive, q_warn, loop_passes,
  loop_bw_mib, loop_invalid                 이 파일이 계산한다 (COMPUTED_COLS). 하네스는
                                            --set/--state-file로 줄 수 없다(오류, 종료 코드 2):
                                            계산값과 하네스 값이 갈릴 여지를 없애기 위해서다.
                                            collect_values(given=…)로 직접 줄 때도 계산 결과가
                                            항상 이긴다(적용 대상이 아니면 NA로 덮어씀).

스냅샷 디렉터리(snap_<run>_{pre,post}/) 안의 원문 파일 이름(없으면 해당 값은 NA):
  vmstat            /proc/vmstat
  stat              /proc/stat (전체 또는 첫 줄)
  meminfo           /proc/meminfo
  memory.stat       $CG/memory.stat
  samon_stats       /sys/kernel/debug/samon/stats  (SAMON 계열만)
  lru_sort_stats    LRU_SORT 통계 10개, 한 줄에 `이름=값` 또는 `이름 값` (damon 계열만)
  kd_stat           kdamond의 /proc/<pid>/stat 원문 (kdamond 있는 구성만)
  ts                스냅샷 시각, `date +%s.%N` 값 (cachestat 구간 선택용)
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
import random
import re
import sys
import time
from fractions import Fraction
from typing import Iterable, Mapping, NamedTuple

NA = "NA"

# ---------------------------------------------------------------------------
# 열 정의
# ---------------------------------------------------------------------------

# design K10 "SAMON_Stats 줄 목록"의 카운터 줄 순서 그대로(1~78).
# 마지막 줄 `entries=%u max_entries=%u`는 기존 형식 호환 줄이라 열로 만들지 않는다.
SAMON_STATS_KEYS: tuple[str, ...] = (
    # 1~15 기존
    "rq_seen", "seg_buffered", "skip_null", "skip_anon", "skip_nomap", "skip_pinned",
    "drop_full", "drop_nomem", "nomap_slab", "nomap_flagged", "nomap_meta",
    "nomap_other", "nomap_write", "skip_dev", "budget_cut",
    # 16 호환 별칭
    "mark_accessed",
    # 17~21
    "skip_error", "skip_passthru", "ctx_hardirq", "ctx_softirq", "ctx_task",
    # 22~27
    "det_p1", "det_p2", "det_p3", "det_p4", "det_p5", "det_p6",
    # 28~32
    "req_p1", "req_p2", "req_p3", "req_p4", "req_p5",
    # 33~37
    "exec_p1", "exec_p2", "exec_p3", "exec_p4", "exec_p5",
    # 38~62 사유마다 N = 1~5
    "drop_queue_p1", "drop_queue_p2", "drop_queue_p3", "drop_queue_p4", "drop_queue_p5",
    "drop_stale_p1", "drop_stale_p2", "drop_stale_p3", "drop_stale_p4", "drop_stale_p5",
    "drop_revalidate_p1", "drop_revalidate_p2", "drop_revalidate_p3",
    "drop_revalidate_p4", "drop_revalidate_p5",
    "drop_toggle_p1", "drop_toggle_p2", "drop_toggle_p3", "drop_toggle_p4", "drop_toggle_p5",
    "drop_shutdown_p1", "drop_shutdown_p2", "drop_shutdown_p3", "drop_shutdown_p4",
    "drop_shutdown_p5",
    # 63~66
    "q_cur", "q_max_delay_us", "q_cap", "direct_ops",
    # 67~78 Stream_Counters 12개 (enum samon_sev 순서)
    "stream_r_extend", "stream_r_prepend", "stream_r_fill", "stream_r_restart",
    "stream_r_new_slot", "stream_r_evict",
    "stream_w_extend", "stream_w_prepend", "stream_w_fill", "stream_w_restart",
    "stream_w_new_slot", "stream_w_evict",
)
# 차분이 아니라 post 값을 쓰는 키 (R4.11: 누적이 아닌 값)
SAMON_POST_VALUE_KEYS: frozenset[str] = frozenset({"q_cur", "q_max_delay_us", "q_cap"})
# 스냅샷에 있어도 열로 만들지 않고 경고도 내지 않는 키 (마지막 `entries=… max_entries=…` 줄)
SAMON_STATS_IGNORED: frozenset[str] = frozenset({"entries", "max_entries"})

# 요구사항 10 기준 5의 LRU_SORT 통계 파라미터 10개 (요구사항 순서)
LRU_SORT_STATS_KEYS: tuple[str, ...] = (
    "nr_lru_sort_tried_hot_regions", "nr_lru_sorted_hot_regions",
    "nr_lru_sort_tried_cold_regions", "nr_lru_sorted_cold_regions",
    "bytes_lru_sort_tried_hot_regions", "bytes_lru_sorted_hot_regions",
    "bytes_lru_sort_tried_cold_regions", "bytes_lru_sorted_cold_regions",
    "nr_hot_quota_exceeds", "nr_cold_quota_exceeds",
)

_IDENT_COLS = ("run", "workload", "rep", "config", "seed")
_STATE_COLS = (
    "samon_kd_state", "act_p1", "act_p2", "act_p3", "act_p4", "opt_b",
    "lrusort_enabled", "lrusort_pid", "lru_gen_enabled",
    "mon_sample_us", "mon_aggr_us", "mon_update_us", "mon_nr_min", "mon_nr_max",
)
_MARK_COLS = ("fio_rc", "damon_inactive", "q_warn", "loop_invalid")
_PERF_COLS = (
    "hot_r_iops", "hot_w_iops", "hot_r_p50_us", "hot_r_p99_us",
    "hot_w_p50_us", "hot_w_p99_us", "aux_bw_mib", "loop_passes", "loop_bw_mib",
)
_CACHE_COLS = (
    "cg_workingset_refault_file", "cg_workingset_activate_file", "cg_pgscan",
    "cg_pgsteal", "pgpgin_kib", "cachestat_hit_pct",
)
_COST_COLS = ("cpu_sys_s", "cpu_irq_s", "cpu_softirq_s", "cpu_sys_irq_softirq_s", "kd_cpu_s")
_MEM_COLS = ("slab_kb", "sunreclaim_kb")

# runs.csv 열 전체. 헤더와 모든 행은 이 튜플에서만 만든다.
COLUMNS: tuple[str, ...] = (
    _IDENT_COLS + _STATE_COLS + _MARK_COLS + _PERF_COLS + _CACHE_COLS + _COST_COLS
    + _MEM_COLS
    + tuple("s_" + k for k in SAMON_STATS_KEYS)
    + tuple("ls_" + k for k in LRU_SORT_STATS_KEYS)
)
assert len(set(COLUMNS)) == len(COLUMNS), "duplicate column name"

# 하네스(bash)가 --set/--state-file로 직접 주는 열: 식별, 확인한 상태, fio 종료 코드.
EXTERNAL_COLS: frozenset[str] = frozenset(_IDENT_COLS + _STATE_COLS + ("fio_rc",))
# 이 파일이 스냅샷 차분·passes.csv에서 계산하는 열(23.2). EXTERNAL_COLS와 겹치지 않는다.
COMPUTED_COLS: frozenset[str] = frozenset(
    ("damon_inactive", "q_warn", "loop_passes", "loop_bw_mib", "loop_invalid")
)
assert not (EXTERNAL_COLS & COMPUTED_COLS)
assert (EXTERNAL_COLS | COMPUTED_COLS) <= set(COLUMNS)

# 큐 유실 경고 기준 기본값(%): design T6 옵션 --q-warn-pct 기본 1, R10.6 "1%(제안)"
DEFAULT_Q_WARN_PCT = 1
MIB = 1024 * 1024

# fio 잡 이름 (design T6 워크로드 표)
HOT_JOB = "hot"
AUX_JOB_BY_WORKLOAD = {"mixed": "scan", "seqwrite": "writer"}
# hot 잡의 방향별 보고: reread는 read만, loop는 hot 지표 전부 NA
HOT_DIRS_BY_WORKLOAD = {
    "mixed": ("read", "write"),
    "seqwrite": ("read", "write"),
    "reread": ("read",),
    "loop": (),
}


def warn(msg: str) -> None:
    """경고만 출력한다(진행은 계속). 테스트에서 monkeypatch 가능하도록 함수로 둔다."""
    print(f"samon_benchlib: warning: {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# 값 → CSV 문자열
# ---------------------------------------------------------------------------

def fmt_value(v: object) -> str:
    """None, nan/inf, 빈 문자열은 NA. bool은 1/0, float은 최단 repr."""
    if v is None:
        return NA
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if math.isnan(v) or math.isinf(v):
            return NA
        return repr(v)
    s = " ".join(str(v).split())  # 줄바꿈·연속 공백 정리 (lru_gen 원문 등)
    return s if s else NA


def row_from_values(values: Mapping[str, object]) -> list[str]:
    """{열: 값} → COLUMNS 순서의 문자열 목록. 없는 값은 NA. 길이는 항상 len(COLUMNS)."""
    return [fmt_value(values.get(c)) for c in COLUMNS]


def _csv_line(fields: Iterable[str]) -> str:
    buf = io.StringIO()
    csv.writer(buf, lineterminator="").writerow(list(fields))
    return buf.getvalue()


def header_line() -> str:
    return _csv_line(COLUMNS)


def row_line(values: Mapping[str, object]) -> str:
    return _csv_line(row_from_values(values))


# ---------------------------------------------------------------------------
# 파서 (원문 문자열 → 값, 순수 함수)
# ---------------------------------------------------------------------------

def _to_int(s: str) -> int | None:
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def parse_kv_lines(text: str) -> dict[str, int]:
    """`이름 값` 줄 모음(/proc/vmstat, memory.stat)을 {이름: 정수}로. 정수가 아닌 줄은 건너뛴다."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            v = _to_int(parts[1])
            if v is not None:
                out[parts[0]] = v
    return out


def parse_meminfo(text: str) -> dict[str, int]:
    """/proc/meminfo: `Slab:   123 kB` → {"Slab": 123}."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        name, sep, rest = line.partition(":")
        if not sep:
            continue
        parts = rest.split()
        if parts:
            v = _to_int(parts[0])
            if v is not None:
                out[name.strip()] = v
    return out


def parse_proc_stat_cpu(text: str) -> list[int] | None:
    """/proc/stat의 "cpu " 합계 줄에서 "cpu" 다음 값 목록. 없으면 None."""
    for line in text.splitlines():
        parts = line.split()
        if parts and parts[0] == "cpu":
            vals = [_to_int(p) for p in parts[1:]]
            if any(v is None for v in vals):
                return None
            return [v for v in vals if v is not None]
    return None


def stat_sys_irq_softirq(vals: list[int] | None) -> tuple[int, int, int] | None:
    """"cpu" 다음 값을 1번째로 세어 3번째(system), 6번째(irq), 7번째(softirq) tick."""
    if vals is None or len(vals) < 7:
        return None
    return vals[2], vals[5], vals[6]


def parse_pid_stat(text: str) -> tuple[int, int] | None:
    """/proc/<pid>/stat → (utime, stime) tick.

    comm(2번째 필드)에 공백과 괄호가 들어갈 수 있으므로 마지막 `)` 뒤를 공백으로 나눈다.
    그 뒤 첫 토큰이 proc(5)의 3번째 필드(state)이므로 14번째(utime), 15번째(stime)
    필드는 토큰 번호 14-3, 15-3 (0부터)에 있다.
    """
    i = text.rfind(")")
    if i < 0:
        return None
    rest = text[i + 1:].split()
    if len(rest) < 15 - 3 + 1:
        return None
    ut, st = _to_int(rest[14 - 3]), _to_int(rest[15 - 3])
    if ut is None or st is None:
        return None
    return ut, st


def parse_samon_stats(text: str) -> dict[str, int]:
    """SAMON stats: 한 줄에 `이름=값` 하나. 마지막 줄만 `entries=N max_entries=M`이라
    공백으로 나눈 토큰마다 `이름=값`을 읽는다. 정수가 아닌 값은 건너뛴다."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        for tok in line.split():
            k, sep, v = tok.partition("=")
            if sep and k:
                iv = _to_int(v)
                if iv is not None:
                    out[k] = iv
    return out


def parse_lru_sort_stats(text: str) -> dict[str, int]:
    """LRU_SORT 통계: 줄마다 `이름=값` 또는 `이름 값`."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.replace("=", " ").split()
        if len(parts) >= 2:
            v = _to_int(parts[1])
            if v is not None:
                out[parts[0]] = v
    return out


def parse_fio_json(text: str) -> dict:
    """fio --output-format=json 출력. JSON 앞에 경고 텍스트가 섞여도 첫 `{`부터 읽는다."""
    i = text.find("{")
    if i < 0:
        raise ValueError("no JSON object in fio output")
    obj, _ = json.JSONDecoder().raw_decode(text[i:])
    return obj


# ---------------------------------------------------------------------------
# fio JSON → 성능 열
# ---------------------------------------------------------------------------

def _clat_pct_us(d: Mapping, key: str) -> float | None:
    """clat_ns 백분위(ns) ÷ 1000 = µs. 없으면 None."""
    try:
        ns = d["clat_ns"]["percentile"][key]
    except (KeyError, TypeError):
        return None
    return ns / 1000.0 if isinstance(ns, (int, float)) else None


def fio_metrics(fio: Mapping, workload: str) -> dict[str, float | None]:
    """fio JSON에서 hot 잡 방향별 IOPS·clat p50/p99(µs)와 보조 잡 대역폭(MiB/s)을 뽑는다.

    - hot 잡은 jobname == "hot" 하나(group_reporting으로 numjobs가 합쳐진 항목, R11.3).
    - 방향 목록은 워크로드가 정한다(reread는 read만, loop는 hot 지표 없음).
    - 보조 잡(mixed의 scan, seqwrite의 writer) 대역폭 = bw(KiB/s) ÷ 1024.
    """
    out: dict[str, float | None] = {}
    jobs = {j.get("jobname"): j for j in fio.get("jobs", []) if isinstance(j, dict)}
    hot = jobs.get(HOT_JOB)
    for direction, tag in (("read", "r"), ("write", "w")):
        if hot is not None and direction in HOT_DIRS_BY_WORKLOAD.get(workload, ()):
            d = hot.get(direction) or {}
            out[f"hot_{tag}_iops"] = d.get("iops")
            out[f"hot_{tag}_p50_us"] = _clat_pct_us(d, "50.000000")
            out[f"hot_{tag}_p99_us"] = _clat_pct_us(d, "99.000000")
    aux_name = AUX_JOB_BY_WORKLOAD.get(workload)
    aux = jobs.get(aux_name) if aux_name else None
    if aux is not None:
        bw = 0.0
        seen = False
        for direction in ("read", "write"):
            v = (aux.get(direction) or {}).get("bw")
            if isinstance(v, (int, float)):
                bw += v
                seen = True
        out["aux_bw_mib"] = bw / 1024.0 if seen else None
    return out


# ---------------------------------------------------------------------------
# cachestat → hit율
# ---------------------------------------------------------------------------

_HMS_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})$")


def cachestat_hit_pct(text: str, t_pre: float, t_post: float) -> float | None:
    """`cachestat-bpfcc -T 1` 원문에서 [t_pre, t_post] (epoch 초) 안의 줄만 골라
    hit율 = 100 × Σhits / (Σhits + Σmisses). 줄이 없거나 분모가 0이면 None.

    줄 형식: `HH:MM:SS HITS MISSES …` (시각은 로컬 시간대의 하루 중 초로 비교한다.
    자정을 넘기는 구간도 처리한다). 머리글·형식이 다른 줄은 건너뛴다.
    """
    def sod(t: float) -> int:
        lt = time.localtime(t)
        return lt.tm_hour * 3600 + lt.tm_min * 60 + lt.tm_sec

    lo, hi = sod(t_pre), sod(t_post)
    wrap = hi < lo
    hits = misses = 0
    n = 0
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        m = _HMS_RE.match(parts[0])
        h, ms = _to_int(parts[1]), _to_int(parts[2])
        if not m or h is None or ms is None:
            continue
        t = int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3])
        if wrap:
            inside = t >= lo or t <= hi
        else:
            inside = lo <= t <= hi
        if inside:
            hits += max(h, 0)
            misses += max(ms, 0)
            n += 1
    if n == 0 or hits + misses == 0:
        return None
    return 100.0 * hits / (hits + misses)


# ---------------------------------------------------------------------------
# 실행 표시 계산 (R10.5, R10.6, R11.4, R11.7)
# ---------------------------------------------------------------------------

def damon_inactive_mark(hot_delta: int | None, cold_delta: int | None) -> bool | None:
    """R10.5: nr_lru_sorted_hot_regions 차분 + nr_lru_sorted_cold_regions 차분 = 0 이면 True.
    둘 중 하나라도 없으면(damon 계열이 아님) None(NA)."""
    if hot_delta is None or cold_delta is None:
        return None
    return hot_delta + cold_delta == 0


def q_warn_mark(req_sum: int | None, drop_queue_sum: int | None,
                pct: float | int | str = DEFAULT_Q_WARN_PCT) -> bool | None:
    """R10.6: Σreq 차분 > 0 이고 Σdrop_queue 차분 > Σreq 차분 × pct / 100 이면 True.
    Σreq = 0 이면 경고를 내지 않는다(False). 합을 알 수 없으면(SAMON 계열이 아님) None.
    경계(정확히 pct%)는 경고가 아니다. 부동소수 오차를 피하려고 Fraction으로 비교한다."""
    if req_sum is None or drop_queue_sum is None:
        return None
    if req_sum <= 0:
        return False
    p = Fraction(str(pct))
    return Fraction(drop_queue_sum) * 100 > Fraction(req_sum) * p


def sum_deltas(values: Mapping[str, object], names: Iterable[str]) -> int | None:
    """values[name]의 정수 합. 하나라도 없거나 정수가 아니면 None."""
    total = 0
    for n in names:
        v = values.get(n)
        if isinstance(v, bool) or not isinstance(v, int):
            return None
        total += v
    return total


class PassRec(NamedTuple):
    idx: int
    start_ns: int
    end_ns: int
    rc: int
    io_bytes: int


def parse_passes_csv(text: str) -> tuple[list[PassRec], int]:
    """passes.csv(`idx,start_ns,end_ns,rc,io_bytes`, design T6) → (pass 목록, 건너뛴 줄 수).
    머리글 줄(첫 칸이 정수 아님)·빈 줄은 건너뛰되 세지 않는다. 칸 수가 5가 아니거나 정수가
    아니거나 end_ns < start_ns 인 줄은 건너뛰고 센다(그 pass는 완주로 세지 않는다)."""
    recs: list[PassRec] = []
    bad = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        f = [x.strip() for x in line.split(",")]
        if _to_int(f[0]) is None and len(f) == 5 and f[0] == "idx":
            continue
        nums = [_to_int(x) for x in f]
        if len(f) != 5 or any(n is None for n in nums):
            bad += 1
            continue
        idx, st, en, rc, io = (n for n in nums if n is not None)
        if en < st or io < 0:
            bad += 1
            continue
        recs.append(PassRec(idx, st, en, rc, io))
    return recs, bad


def loop_summary(passes: Iterable[PassRec], ramp_end_ns: int, file_size: int
                 ) -> dict[str, float | int | bool | None]:
    """R11.7·R11.4: 완주 pass = start_ns ≥ ramp_end_ns, rc = 0, io_bytes = file_size.
    loop_passes = 완주 수, loop_bw_mib = Σio_bytes / Σ(end−start) / MiB (완주 pass만, 초 단위
    경과 시간 합이 0이면 None), loop_invalid = 완주 수 < 2."""
    done = [p for p in passes
            if p.start_ns >= ramp_end_ns and p.rc == 0 and p.io_bytes == file_size]
    n = len(done)
    elapsed_ns = sum(p.end_ns - p.start_ns for p in done)
    bw = None
    if n > 0 and elapsed_ns > 0:
        bw = (sum(p.io_bytes for p in done) / MIB) / (elapsed_ns / 1e9)
    return {"loop_passes": n, "loop_bw_mib": bw, "loop_invalid": n < 2}


def compute_marks(values: Mapping[str, object], *, workload: str,
                  q_warn_pct: float | int | str = DEFAULT_Q_WARN_PCT,
                  passes_text: str | None = None,
                  ramp_end_ns: int | None = None,
                  loop_size_bytes: int | None = None) -> dict[str, object]:
    """차분이 채워진 `values`(diff_samon·diff_lru_sort 결과 포함)에서 COMPUTED_COLS 다섯 열을
    만든다. 적용 대상이 아니면 None(NA):
      damon_inactive : ls_* 차분이 있는 실행(damon 계열)
      q_warn         : s_req_p1..5, s_drop_queue_p1..5 차분이 있는 실행(SAMON 계열)
      loop_*         : workload == "loop" 일 때만. passes.csv 내용·ramp 끝(ns)·파일 크기(바이트)가
                       모두 있어야 계산한다. loop인데 하나라도 없으면 경고하고 loop_invalid = 1
                       (완주 pass를 확인할 수 없는 실행은 유효 반복에서 뺀다), 나머지는 NA."""
    out: dict[str, object] = {c: None for c in COMPUTED_COLS}
    out["damon_inactive"] = damon_inactive_mark(
        values.get("ls_nr_lru_sorted_hot_regions"),  # type: ignore[arg-type]
        values.get("ls_nr_lru_sorted_cold_regions"))  # type: ignore[arg-type]
    pn = range(1, 6)
    out["q_warn"] = q_warn_mark(
        sum_deltas(values, [f"s_req_p{i}" for i in pn]),
        sum_deltas(values, [f"s_drop_queue_p{i}" for i in pn]), q_warn_pct)
    if workload == "loop":
        if passes_text is None or ramp_end_ns is None or loop_size_bytes is None:
            warn("loop workload without passes.csv/--ramp-end-ns/--loop-size-bytes: "
                 "loop_invalid=1")
            out["loop_invalid"] = True
        else:
            recs, bad = parse_passes_csv(passes_text)
            if bad:
                warn(f"passes.csv: {bad} malformed line(s) skipped")
            out.update(loop_summary(recs, ramp_end_ns, loop_size_bytes))
    return out


# ---------------------------------------------------------------------------
# 스냅샷과 차분
# ---------------------------------------------------------------------------

class Snapshot:
    """스냅샷 디렉터리 하나를 읽은 결과. 없는 파일은 None."""

    __slots__ = ("vmstat", "stat_cpu", "meminfo", "memory_stat", "samon", "lru_sort",
                 "kd_ticks", "ts", "where")

    def __init__(self) -> None:
        self.vmstat: dict[str, int] | None = None
        self.stat_cpu: list[int] | None = None
        self.meminfo: dict[str, int] | None = None
        self.memory_stat: dict[str, int] | None = None
        self.samon: dict[str, int] | None = None
        self.lru_sort: dict[str, int] | None = None
        self.kd_ticks: tuple[int, int] | None = None
        self.ts: float | None = None
        self.where: str = ""


def _read_path(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _read_opt(d: str, name: str) -> str | None:
    return _read_path(os.path.join(d, name))


def load_snapshot(d: str) -> Snapshot:
    s = Snapshot()
    s.where = d
    t = _read_opt(d, "vmstat")
    s.vmstat = parse_kv_lines(t) if t is not None else None
    t = _read_opt(d, "stat")
    s.stat_cpu = parse_proc_stat_cpu(t) if t is not None else None
    t = _read_opt(d, "meminfo")
    s.meminfo = parse_meminfo(t) if t is not None else None
    t = _read_opt(d, "memory.stat")
    s.memory_stat = parse_kv_lines(t) if t is not None else None
    t = _read_opt(d, "samon_stats")
    s.samon = parse_samon_stats(t) if t is not None else None
    t = _read_opt(d, "lru_sort_stats")
    s.lru_sort = parse_lru_sort_stats(t) if t is not None else None
    t = _read_opt(d, "kd_stat")
    s.kd_ticks = parse_pid_stat(t) if t is not None else None
    t = _read_opt(d, "ts")
    if t is not None:
        try:
            s.ts = float(t.strip())
        except ValueError:
            s.ts = None
    return s


def _delta(pre: Mapping[str, int] | None, post: Mapping[str, int] | None,
           key: str) -> int | None:
    if pre is None or post is None or key not in pre or key not in post:
        return None
    return post[key] - pre[key]


def diff_samon(pre: Mapping[str, int] | None, post: Mapping[str, int] | None,
               where: str = "") -> dict[str, int | None]:
    """SAMON stats 차분 → {`s_<이름>`: 값}. 누적 카운터는 post − pre, q_cur·q_max_delay_us·
    q_cap은 post 값. 스냅샷에 없는 키는 None(NA). 스냅샷에는 있지만 SAMON_STATS_KEYS에
    없는 키는 경고만 출력한다. 스냅샷이 하나라도 없으면(SAMON 계열 아님) 전부 None."""
    out: dict[str, int | None] = {"s_" + k: None for k in SAMON_STATS_KEYS}
    if pre is None or post is None:
        return out
    known = set(SAMON_STATS_KEYS)
    unknown = sorted((set(pre) | set(post)) - known - SAMON_STATS_IGNORED)
    for k in unknown:
        warn(f"unknown SAMON stats key '{k}' ignored{' (' + where + ')' if where else ''}")
    for k in SAMON_STATS_KEYS:
        if k in SAMON_POST_VALUE_KEYS:
            out["s_" + k] = post.get(k)
        else:
            out["s_" + k] = _delta(pre, post, k)
    return out


def diff_lru_sort(pre: Mapping[str, int] | None,
                  post: Mapping[str, int] | None) -> dict[str, int | None]:
    """LRU_SORT 통계 10개 차분(post − pre) → {`ls_<이름>`: 값}. 없으면 None."""
    out: dict[str, int | None] = {}
    for k in LRU_SORT_STATS_KEYS:
        out["ls_" + k] = _delta(pre, post, k)
    return out


def diff_cost(pre: Snapshot, post: Snapshot, clk_tck: int) -> dict[str, float | None]:
    """/proc/stat 첫 줄의 system·irq·softirq 차분(초)과 kdamond utime+stime 차분(초)."""
    out: dict[str, float | None] = {
        "cpu_sys_s": None, "cpu_irq_s": None, "cpu_softirq_s": None,
        "cpu_sys_irq_softirq_s": None, "kd_cpu_s": None,
    }
    a, b = stat_sys_irq_softirq(pre.stat_cpu), stat_sys_irq_softirq(post.stat_cpu)
    if a is not None and b is not None and clk_tck > 0:
        d = [y - x for x, y in zip(a, b)]
        out["cpu_sys_s"] = round(d[0] / clk_tck, 6)
        out["cpu_irq_s"] = round(d[1] / clk_tck, 6)
        out["cpu_softirq_s"] = round(d[2] / clk_tck, 6)
        out["cpu_sys_irq_softirq_s"] = round(sum(d) / clk_tck, 6)
    if pre.kd_ticks is not None and post.kd_ticks is not None and clk_tck > 0:
        d = (post.kd_ticks[0] + post.kd_ticks[1]) - (pre.kd_ticks[0] + pre.kd_ticks[1])
        out["kd_cpu_s"] = round(d / clk_tck, 6)
    return out


def diff_cache_mem(pre: Snapshot, post: Snapshot) -> dict[str, int | None]:
    """cgroup memory.stat, /proc/vmstat pgpgin, /proc/meminfo Slab·SUnreclaim 차분(post − pre)."""
    return {
        "cg_workingset_refault_file":
            _delta(pre.memory_stat, post.memory_stat, "workingset_refault_file"),
        "cg_workingset_activate_file":
            _delta(pre.memory_stat, post.memory_stat, "workingset_activate_file"),
        "cg_pgscan": _delta(pre.memory_stat, post.memory_stat, "pgscan"),
        "cg_pgsteal": _delta(pre.memory_stat, post.memory_stat, "pgsteal"),
        "pgpgin_kib": _delta(pre.vmstat, post.vmstat, "pgpgin"),
        "slab_kb": _delta(pre.meminfo, post.meminfo, "Slab"),
        "sunreclaim_kb": _delta(pre.meminfo, post.meminfo, "SUnreclaim"),
    }


def default_clk_tck() -> int:
    try:
        return int(os.sysconf("SC_CLK_TCK"))
    except (ValueError, OSError, AttributeError):
        return 100


def collect_values(pre_dir: str, post_dir: str, *, workload: str = "",
                   fio_json: str | None = None, cachestat: str | None = None,
                   clk_tck: int | None = None,
                   passes_csv: str | None = None, ramp_end_ns: int | None = None,
                   loop_size_bytes: int | None = None,
                   q_warn_pct: float | int | str = DEFAULT_Q_WARN_PCT,
                   given: Mapping[str, object] | None = None) -> dict[str, object]:
    """스냅샷 두 개(+ fio JSON, cachestat 원문)에서 {열: 값}을 만든다.

    `given`은 하네스가 직접 주는 값(식별, 확인한 상태, fio_rc 등 EXTERNAL_COLS)이며 먼저
    놓인다. 표시 열(COMPUTED_COLS: damon_inactive, q_warn, loop_*)은 항상 계산값이 이긴다:
    `given`에 같은 열이 있어도 덮어쓴다(적용 대상이 아니면 NA).
    """
    tck = clk_tck if clk_tck else default_clk_tck()
    pre, post = load_snapshot(pre_dir), load_snapshot(post_dir)
    vals: dict[str, object] = dict(given or {})
    if workload and "workload" not in vals:
        vals["workload"] = workload
    vals.update(diff_cache_mem(pre, post))
    vals.update(diff_cost(pre, post, tck))
    vals.update(diff_samon(pre.samon, post.samon, where=post_dir))
    vals.update(diff_lru_sort(pre.lru_sort, post.lru_sort))
    wl = str(vals.get("workload") or workload)
    if fio_json:
        text = _read_path(fio_json)
        if text is not None:
            try:
                vals.update(fio_metrics(parse_fio_json(text), wl))
            except ValueError as e:  # json.JSONDecodeError는 ValueError의 하위 클래스
                warn(f"cannot parse fio JSON {fio_json}: {e}")
    if cachestat and pre.ts is not None and post.ts is not None:
        text = _read_path(cachestat)
        if text is not None:
            vals["cachestat_hit_pct"] = cachestat_hit_pct(text, pre.ts, post.ts)
    passes_text = None
    if passes_csv:
        passes_text = _read_path(passes_csv)
        if passes_text is None:
            warn(f"cannot read passes CSV {passes_csv}")
    vals.update(compute_marks(vals, workload=wl, q_warn_pct=q_warn_pct,
                              passes_text=passes_text, ramp_end_ns=ramp_end_ns,
                              loop_size_bytes=loop_size_bytes))
    return vals


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_set(items: Iterable[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for it in items:
        k, sep, v = it.partition("=")
        if not sep or k not in EXTERNAL_COLS:
            hint = " (computed by samon_benchlib; not settable)" if k in COMPUTED_COLS else ""
            raise ValueError(
                f"--set: '{it}' is not <column>=<value> with a harness-supplied column{hint}")
        out[k] = v
    return out


def _read_state_file(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            k, sep, v = line.partition("=")
            if sep and k in EXTERNAL_COLS:
                out[k.strip()] = v
            else:
                raise ValueError(f"{path}: bad line '{line}'")
    return out


def cmd_header(args: argparse.Namespace) -> int:
    print(header_line())
    return 0


def cmd_row(args: argparse.Namespace) -> int:
    try:
        given: dict[str, object] = {}
        if args.state_file:
            given.update(_read_state_file(args.state_file))
        given.update(_parse_set(args.set or []))
        if args.workload:
            given["workload"] = args.workload
        vals = collect_values(args.pre, args.post, workload=given.get("workload", ""),
                              fio_json=args.fio_json, cachestat=args.cachestat,
                              clk_tck=args.clk_tck, passes_csv=args.passes_csv,
                              ramp_end_ns=args.ramp_end_ns,
                              loop_size_bytes=args.loop_size_bytes,
                              q_warn_pct=args.q_warn_pct, given=given)
    except (OSError, ValueError) as e:
        print(f"samon_benchlib: row: {e}", file=sys.stderr)
        return 2
    if args.header:
        print(header_line())
    print(row_line(vals))
    return 0


def run_order(seed: int, reps: int, configs: Iterable[str]) -> list[tuple[int, str]]:
    """반복별 구성 실행 순서 (design T6, R10.13): [(rep, config), …].

    rep는 1부터 reps까지(samon_bench.sh의 `seq 1 $REPS`와 같다). 반복마다 configs를
    `random.Random(seed)` 하나로 이어서 섞으므로 같은 (seed, reps, configs)면 결과가 항상
    같고, 각 rep는 configs의 순열(모든 구성을 정확히 한 번)이다. 입력은 바꾸지 않는다.
    잘못된 입력(seed가 int 아님, reps < 1, 빈 configs, 빈 이름·공백 포함 이름·중복)은
    ValueError.
    """
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise ValueError(f"seed must be an integer: {seed!r}")
    if isinstance(reps, bool) or not isinstance(reps, int) or reps < 1:
        raise ValueError(f"reps must be an integer >= 1: {reps!r}")
    names = list(configs)
    if not names:
        raise ValueError("configs is empty")
    for c in names:
        if not isinstance(c, str) or not c or c != "".join(c.split()):
            raise ValueError(f"bad config name: {c!r}")
    dup = sorted({c for c in names if names.count(c) > 1})
    if dup:
        raise ValueError(f"duplicate config(s): {','.join(dup)}")
    rng = random.Random(seed)
    out: list[tuple[int, str]] = []
    for rep in range(1, reps + 1):
        perm = list(names)
        rng.shuffle(perm)
        out.extend((rep, c) for c in perm)
    return out


order = run_order  # design Property 16의 이름: order(seed, reps, configs)


def _int_arg(s: str) -> int:
    try:
        return int(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an integer: '{s}'") from None


def cmd_order(args: argparse.Namespace) -> int:
    try:
        lines = run_order(args.seed, args.reps, args.configs.split(","))
    except ValueError as e:
        print(f"samon_benchlib: order: {e}", file=sys.stderr)
        return 2
    for rep, cfg in lines:
        print(f"{rep} {cfg}")
    return 0


def _pct_arg(s: str) -> str:
    try:
        v = Fraction(s)
    except (ValueError, ZeroDivisionError):
        raise argparse.ArgumentTypeError(f"not a number: '{s}'") from None
    if v < 0:
        raise argparse.ArgumentTypeError("must be >= 0")
    return s


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="samon_benchlib.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    h = sub.add_parser("header", help="print the runs.csv header line")
    h.set_defaults(func=cmd_header)

    r = sub.add_parser("row", help="snapshot directories -> one runs.csv row")
    r.add_argument("--pre", required=True, help="pre snapshot directory (snap_<N>_pre)")
    r.add_argument("--post", required=True, help="post snapshot directory (snap_<N>_post)")
    r.add_argument("--workload", default="", help="mixed|reread|loop|seqwrite")
    r.add_argument("--fio-json", help="fio --output-format=json output (run<N>.json)")
    r.add_argument("--cachestat", help="cachestat_<N>.txt (optional)")
    r.add_argument("--clk-tck", type=int, help="override getconf CLK_TCK")
    r.add_argument("--passes-csv",
                   help="loop passes_<N>.csv (idx,start_ns,end_ns,rc,io_bytes) -> "
                        "loop_passes, loop_bw_mib, loop_invalid")
    r.add_argument("--ramp-end-ns", type=int,
                   help="T0 + RAMP in ns (completed pass: start_ns >= this); required for loop")
    r.add_argument("--loop-size-bytes", type=int,
                   help="loop file size in bytes (completed pass: io_bytes == this); required for loop")
    r.add_argument("--q-warn-pct", type=_pct_arg, default=DEFAULT_Q_WARN_PCT,
                   help="queue-drop warning threshold in percent of sum(req) (default 1)")
    r.add_argument("--state-file", help="file of <column>=<value> lines for harness-supplied columns")
    r.add_argument("--set", action="append", metavar="COL=VAL",
                   help="harness-supplied column (run, rep, config, seed, act_p1, fio_rc, ...)")
    r.add_argument("--header", action="store_true", help="print the header line first")
    r.set_defaults(func=cmd_row)

    o = sub.add_parser("order", help="shuffled per-rep config order: one `rep config` per line")
    o.add_argument("--seed", required=True, type=_int_arg, help="integer random seed")
    o.add_argument("--reps", required=True, type=_int_arg, help="repetitions (>= 1)")
    o.add_argument("--configs", required=True, help="comma-separated config names (no duplicates)")
    o.set_defaults(func=cmd_order)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
