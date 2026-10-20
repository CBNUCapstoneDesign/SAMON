#!/usr/bin/env python3
"""samon_replay.py — S0 Replay_Script.

bench/samon_trace.bt 출력(block_rq_issue/complete 기록)에 SAMON 패턴 규칙을
오프라인으로 적용해 보고서를 만든다. 측정·검증 도구이며 커널 구현의 기반이 아니다.

Python 3.12, 표준 라이브러리만 쓴다(테스트만 hypothesis, pytest).

모듈 구성(design T2):
  - Record, parse_line, format_record      : 7필드 레코드 파서와 출력기 (R5.7, R5.11)
  - TraceFile, load_trace                   : trace 파일 읽기와 유효성 판정 (R5.10, R5.11)
  - Params, Slot, LoopRec, Flow, Event, StreamCounters, Engine : 규칙 엔진(커널 참조 모델)
    (4.1: Stream_Table 갱신, 4.2: Loop_History와 idle 정리(tick/advance/finish).
     4.3: Reread_Table, classify_seg, complete(), replay())
  - QueueModel, Folio, QItem, QAcct         : Deferred_Queue 회계 모델(테스트 전용, replay에 쓰지 않음)
  - (이후 작업) pair_records, reorder_stats,
    load_ranges, in_ranges, first_read_report, dist, 보고 (h), build_report,
    render_markdown, main
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable, Iterable

# ---------------------------------------------------------------------------
# 레코드 줄 형식
#   <kind> <ts_ns> <cpu> <major>:<minor> <sector> <nr_sector> <rwbs>
#   kind ∈ {I, C}, 숫자는 10진 정수(0 이상), rwbs는 공백 없는 비어 있지 않은 문자열
# ---------------------------------------------------------------------------

RECORD_KINDS = ("I", "C")
NFIELDS = 7

# ASCII 10진 숫자만 허용한다. int()는 "+1", "1_0", 전각/아랍 숫자도 받아들이므로 쓰지 않는다.
_DEC_RE = re.compile(r"[0-9]+")
_DEV_RE = re.compile(r"([0-9]+):([0-9]+)")
# bpftrace가 perf 버퍼 넘침 때 출력하는 유실 표시
LOST_RE = re.compile(r"Lost (\d+) events")
# samon_trace.bt BEGIN 머리 줄: "# samon_trace v1 dev=<major>:<minor>"
_HEADER_RE = re.compile(r"^#\s*samon_trace\s+v\d+\s+dev=(-?[0-9]+):(-?[0-9]+)\s*$")


@dataclass(frozen=True)
class Record:
    """trace 레코드 한 줄."""

    kind: str  # "I" (block_rq_issue) | "C" (block_rq_complete)
    ts_ns: int
    cpu: int
    major: int
    minor: int
    sector: int
    nr_sector: int
    rwbs: str

    @property
    def dev(self) -> tuple[int, int]:
        return (self.major, self.minor)

    @property
    def dev_t(self) -> int:
        """커널 내부 dev_t = MKDEV(major, minor) = (major << 20) | minor."""
        return (self.major << 20) | self.minor


def _dec(s: str) -> int | None:
    return int(s) if _DEC_RE.fullmatch(s) else None


def parse_line(line: str) -> Record | None:
    """레코드 줄 하나를 Record로 바꾼다. 레코드 형식이 아니면 None.

    비레코드: 빈 줄, '#'로 시작하는 줄, 필드 수가 7이 아닌 줄, kind가 I/C가 아닌 줄,
    숫자 필드 변환 실패, dev가 <major>:<minor> 형식이 아닌 줄.
    """
    s = line.strip()
    if not s or s.startswith("#"):
        return None
    f = s.split()
    if len(f) != NFIELDS:
        return None
    kind, ts, cpu, dev, sector, nr, rwbs = f
    if kind not in RECORD_KINDS:
        return None
    m = _DEV_RE.fullmatch(dev)
    if m is None:
        return None
    nums = [_dec(x) for x in (ts, cpu, sector, nr)]
    if any(v is None for v in nums):
        return None
    ts_v, cpu_v, sec_v, nr_v = nums
    return Record(kind, ts_v, cpu_v, int(m.group(1)), int(m.group(2)),
                  sec_v, nr_v, rwbs)


def format_record(r: Record) -> str:
    """Record를 Trace_Script와 같은 형식(한 칸 공백)의 줄로 만든다(줄바꿈 없음)."""
    return (f"{r.kind} {r.ts_ns} {r.cpu} {r.major}:{r.minor} "
            f"{r.sector} {r.nr_sector} {r.rwbs}")


# ---------------------------------------------------------------------------
# trace 파일 읽기
# ---------------------------------------------------------------------------

@dataclass
class TraceFile:
    """load_trace 결과.

    records    : 파일 순서 그대로의 유효 레코드 전부(대상 디스크가 아닌 것 포함).
                 정렬은 규칙 엔진이 (ts_ns, 파일 내 순서)로 한다.
    n_dropped  : 레코드 형식이 아니어서 뺀 줄 수(빈 줄 제외, '#' 줄·Lost 줄 포함) (R5.11)
    lost_events: stdout·stderr에서 찾은 'Lost <N> events'의 N 합
    lost_lines : 그 표시 줄 수(N이 0이어도 표시가 있으면 무효로 본다)
    target     : 대상 디스크 (major, minor). 인자 > 머리 줄 순으로 정하고, 둘 다 없으면 None
                 (None이면 모든 레코드를 대상 디스크 레코드로 센다)
    n_target / n_target_issue / n_target_complete : 대상 디스크 레코드 수
    invalid_reasons : 무효 사유 목록. 비어 있으면 유효 (R5.10)
    """

    path: str
    stderr_path: str | None
    records: list[Record] = field(default_factory=list)
    n_lines: int = 0
    n_dropped: int = 0
    lost_events: int = 0
    lost_lines: int = 0
    target: tuple[int, int] | None = None
    target_source: str = "none"  # "arg" | "header" | "none"
    n_target: int = 0
    n_target_issue: int = 0
    n_target_complete: int = 0
    invalid_reasons: list[str] = field(default_factory=list)

    @property
    def valid(self) -> bool:
        return not self.invalid_reasons

    def is_target(self, r: Record) -> bool:
        return self.target is None or r.dev == self.target


def _scan_lost(line: str) -> tuple[int, int]:
    """(유실 이벤트 수 합, 표시 개수)."""
    ms = LOST_RE.findall(line)
    return sum(int(x) for x in ms), len(ms)


def load_trace(path: str, stderr_path: str | None = None,
               target: tuple[int, int] | None = None) -> TraceFile:
    """Trace_Script stdout 파일(과 선택적으로 stderr 파일)을 읽는다.

    - 레코드 형식이 아닌 줄은 빼고 수를 센다(빈 줄은 세지 않음).
    - stdout·stderr 두 파일에서 'Lost <N> events'를 찾는다.
    - 대상 디스크는 target 인자, 없으면 머리 줄 '# samon_trace v1 dev=M:m'으로 정한다.
    - 무효(R5.10): 유실 표시가 있거나 대상 디스크 레코드가 0개.
    """
    tf = TraceFile(path=path, stderr_path=stderr_path)
    header_dev: tuple[int, int] | None = None

    with open(path, "r", encoding="utf-8", errors="replace") as fp:
        for line in fp:
            tf.n_lines += 1
            ev, nl = _scan_lost(line)
            tf.lost_events += ev
            tf.lost_lines += nl
            r = parse_line(line)
            if r is None:
                if line.strip():
                    tf.n_dropped += 1
                if header_dev is None:
                    m = _HEADER_RE.match(line.strip())
                    if m:
                        header_dev = (int(m.group(1)), int(m.group(2)))
                continue
            tf.records.append(r)

    if stderr_path is not None:
        with open(stderr_path, "r", encoding="utf-8", errors="replace") as fp:
            for line in fp:
                ev, nl = _scan_lost(line)
                tf.lost_events += ev
                tf.lost_lines += nl

    if target is not None:
        tf.target, tf.target_source = tuple(target), "arg"
    elif header_dev is not None:
        tf.target, tf.target_source = header_dev, "header"

    for r in tf.records:
        if tf.is_target(r):
            tf.n_target += 1
            if r.kind == "I":
                tf.n_target_issue += 1
            else:
                tf.n_target_complete += 1

    if tf.lost_lines:
        tf.invalid_reasons.append(f"lost_events={tf.lost_events}")
    if tf.n_target == 0:
        dev = (f"{tf.target[0]}:{tf.target[1]}" if tf.target else "any")
        tf.invalid_reasons.append(f"no_target_records dev={dev}")
    return tf


# ---------------------------------------------------------------------------
# 규칙 엔진 (커널 K2~K4, K6의 참조 모델, design T2 Engine 규칙)
# ---------------------------------------------------------------------------

@dataclass
class Params:
    """커널 파라미터와 같은 이름. 기본값 = 부록 A 제안 값.

    sample_us는 부록 A의 sample_us 확정값 5000(2026-10-18 확정, design T2)이다.
    samon_q_len, samon_seq_min, samon_stream_new_kb, samon_stream_gap_req,
    samon_stream_idle_ms는 "S0 후 확정" 항목이라 아직 제안 값이다.
    """

    samon_stream_slots: int = 16
    samon_stream_gap_req: int = 2
    samon_stream_new_kb: int = 64
    samon_seq_min: int = 4
    samon_stream_idle_ms: int = 1000
    samon_loop_slots: int = 16
    samon_loop_min_kb: int = 8192
    samon_loop_protect_pct: int = 50
    samon_reread_slots: int = 65536
    samon_reread_ms: int = 10000
    samon_q_len: int = 1024
    sample_us: int = 5000


DIRS = ("R", "W")
# 패턴 이름. Replay_Script는 P5를 재현하지 않으므로 P4가 아닌 write segment는 P6("rest")이다.
PATTERNS = ("P1", "P2", "P3", "P4", "P6")
ACTIONS = ("promote", "demote", "none")
# hash_64 (include/linux/hash.h, x86_64 generic): (val * GOLDEN_RATIO_64) >> (64 - bits)
GOLDEN_RATIO_64 = 0x61C8864680B583EB
_M64 = (1 << 64) - 1
_M32 = (1 << 32) - 1
CLEAR_REASONS = ("evict", "idle", "live", "trace_end")
SEVENTS = ("extend", "prepend", "fill", "restart", "new_slot", "evict")


@dataclass
class Slot:
    """Stream_Table 칸. 필드는 커널 struct samon_stream과 같다(시각 단위 jiffies = ms)."""

    used: bool = False
    dev: int = 0
    start: int = 0
    end: int = 0
    count: int = 0
    t_start: int = 0
    t_last: int = 0
    loop: bool = False
    loop_len: int = 0
    period: int = 0


@dataclass
class LoopRec:
    """Loop_History 칸 (4.2에서 채운다)."""

    used: bool = False
    dev: int = 0
    start: int = 0
    end: int = 0
    t_start: int = 0


@dataclass(frozen=True)
class Flow:
    """samon_flow_of 결과. kind: "NONE" | "P1" | "P3" | "P4"."""

    kind: str = "NONE"
    start: int = 0
    loop_len: int = 0


@dataclass(frozen=True)
class Event:
    """Engine(log=True)가 남기는 이벤트.

    kind  : SEVENTS 중 하나(칸 갱신 이벤트), 또는 4.2의 다음 종류
            - "loop_record": Loop_History에 기록(idx = 기록한 history 칸 번호, 값 = 기록한 흐름)
            - "loop_mark"  : 새 read 칸을 loop로 표시(note "a" = Loop_History, "b" = live 칸,
                             info = L(sector), 값 = 새 칸)
            - "idle"       : idle 정리 대상이 된 read 칸(값 = 비워지기 전 칸)
            - "clear"      : 칸이 비워짐(note = "evict" | "idle" | "live" | "trace_end",
                             값 = 비워지기 전 칸, count = 그때의 연속 횟수)
    idx   : 칸 번호(restart는 -1)
    start, end, count : 이벤트 직후의 칸 값(evict는 교체되기 전 값)
    info  : restart는 restart 칸 수
    note  : 이벤트 부가 설명(위 참조)
    """

    kind: str
    dir: str
    now_j: int
    idx: int = -1
    start: int = 0
    end: int = 0
    count: int = 0
    info: int = 0
    note: str = ""


@dataclass(frozen=True, slots=True)
class SegResult:
    """segment 하나의 판정 결과 (R8.2: 패턴 정확히 하나, 동작 하나).

    pat    : "P1" | "P2" | "P3" | "P4" | "P6"   (write의 P4 아님 = "P6", 방향은 dir로 구분)
    act    : "promote" | "demote" | "none"      (P6은 "none")
    dir    : "R" | "W"
    dev_t  : 커널 dev_t
    sector : segment 시작 sector = request sector + 8·i
    lba4k  : sector // 8 (보고 (h)의 키 (dev_t, lba4k))
    ts_ns, cpu : 그 request의 complete 시각과 CPU (보고 (g), (h))
    """

    pat: str
    act: str
    dir: str
    dev_t: int
    sector: int
    lba4k: int
    ts_ns: int
    cpu: int


@dataclass
class StreamCounters:
    """방향 하나의 Stream_Counters 6종(커널 samon_st_stream[X][SAMON_SEV_*])."""

    extend: int = 0
    prepend: int = 0
    fill: int = 0
    restart: int = 0
    new_slot: int = 0
    evict: int = 0

    def as_dict(self) -> dict[str, int]:
        return {k: getattr(self, k) for k in SEVENTS}


def sorted_complete(records: Iterable[Record]) -> list[Record]:
    """complete 레코드만 (ts_ns, 파일 내 순서)로 안정 정렬해 돌려준다(R5.4)."""
    return sorted((r for r in records if r.kind == "C"), key=lambda r: r.ts_ns)


class Engine:
    """커널 규칙 참조 모델. Stream_Table 갱신(4.1)과 Loop_History, idle 정리(4.2).

    사용: 정렬된 complete 레코드마다 advance(rec.ts_ns)로 그 시각 이하의 sample interval
    경계를 모두 처리한 뒤 stream_request(rec)를 부르고, trace가 끝나면 finish()를 부른다.
    complete(rec)(segment 판정 포함)는 4.3에서 이 순서로 묶는다.

    sample interval 경계: t0_ns + k × sample_us × 1000 ns (k = 1, 2, …). t0_ns는 호출자가
    정하지 않으면 advance가 처음 받은 시각이다(trace 첫 레코드 시각으로 쓰려면 먼저 대입).
    """

    def __init__(self, params: Params | None = None, log: bool = False):
        self.p = params if params is not None else Params()
        self.log = log
        self.events: list[Event] = []
        self.streams: dict[str, list[Slot]] = {
            d: [Slot() for _ in range(self.p.samon_stream_slots)] for d in DIRS}
        self.loops: list[LoopRec] = [LoopRec() for _ in range(self.p.samon_loop_slots)]
        self.loop_next = 0
        self.counters: dict[str, StreamCounters] = {d: StreamCounters() for d in DIRS}
        # 규칙에서 뺀 레코드 수(R5.5): rwbs 첫 글자가 R/W가 아닌 것, nr_sector = 0인 것
        self.n_excluded_rwbs = 0
        self.n_excluded_zero = 0
        self.n_requests = 0
        # (e) 방향별로 칸이 비워질 때의 연속 횟수와 사유별 횟수(log와 무관하게 센다)
        self.clear_counts: dict[str, list[int]] = {d: [] for d in DIRS}
        self.clear_by_reason: dict[str, dict[str, int]] = {
            d: {r: 0 for r in CLEAR_REASONS} for d in DIRS}
        # (f) idle 정리로 비워진 칸 수, loop 표시 횟수 (a) Loop_History / (b) live 칸
        self.n_idle_clears = 0
        self.n_loop_mark_a = 0
        self.n_loop_mark_b = 0
        # Reread_Table (K4): 직접 사상 표. 빈 칸은 dict에 없는 index이다(커널의 dev = 0).
        # 값 = (dev_t 하위 32비트, lba4k, 32비트 시각)
        self.reread: dict[int, tuple[int, int, int]] = {}
        # 4.3: segment 판정 결과 수. det[패턴] (P5는 재현하지 않으므로 P6에 합쳐진다)
        self.det: dict[str, int] = {p: 0 for p in PATTERNS}
        self.n_reread_hit = 0
        self.n_excluded_dev0 = 0  # dev_t = 0 레코드: 커널은 Pattern_Detector를 건너뛴다(K1)
        # sample interval 경계 진행 상태
        self.t0_ns: int | None = None
        self._next_k = 1
        self.now_j = 0

    # -- 보조 ---------------------------------------------------------------

    def _emit(self, kind: str, d: str, now_j: int, idx: int = -1,
              slot: Slot | LoopRec | None = None, info: int = 0,
              note: str = "") -> None:
        if not self.log:
            return
        if slot is None:
            self.events.append(Event(kind, d, now_j, idx, info=info, note=note))
        else:
            self.events.append(Event(kind, d, now_j, idx, slot.start, slot.end,
                                     getattr(slot, "count", 0), info, note))

    @staticmethod
    def now_of(ts_ns: int) -> int:
        """jiffies(HZ = 1000) 근사."""
        return ts_ns // 1_000_000

    @staticmethod
    def better(a: int | None, b: int, T: list[Slot]) -> int:
        """samon_better: count 큰 칸 → t_last 최근 칸 → 작은 index.

        a는 지금까지 고른 후보 index(없으면 None), b는 새 후보 index. 호출부가
        index 오름차순으로 훑으므로 a < b이고, 완전 동률이면 a를 남긴다.
        """
        if a is None:
            return b
        x, y = T[a], T[b]
        if y.count != x.count:
            return b if y.count > x.count else a
        return b if y.t_last > x.t_last else a

    @staticmethod
    def pick_slot(T: list[Slot]) -> int:
        """samon_pick_slot: 빈 칸(작은 index 우선), 없으면 count 최소 → t_last 가장 오래됨 → 작은 index."""
        for i, y in enumerate(T):
            if not y.used:
                return i
        best = 0
        for i in range(1, len(T)):
            y, x = T[i], T[best]
            if y.count != x.count:
                if y.count < x.count:
                    best = i
            elif y.t_last < x.t_last:
                best = i
        return best

    def flow_of(self, d: str, x: Slot | None) -> Flow:
        """samon_flow_of. x가 None이면 흐름 없음(R8.8, R8.25)."""
        if x is None:
            return Flow()
        if d == "R" and x.loop:
            return Flow("P3", x.start, x.loop_len)  # count와 무관 (R8.16)
        if x.count >= self.p.samon_seq_min:
            return Flow("P1" if d == "R" else "P4")
        return Flow()

    # -- Loop_History와 idle 정리 (K3 samon_loop_*, K6 samon_idle_sweep) -------

    def _loop_min(self) -> int:
        """samon_loop_min_kb를 sector로 바꾼 값(KiB × 2)."""
        return self.p.samon_loop_min_kb * 2

    def _clear(self, d: str, x: Slot, reason: str, now_j: int) -> None:
        """칸 x를 비운다. 비워지는 순간의 연속 횟수를 (e)용으로 남긴다."""
        self.clear_counts[d].append(x.count)
        self.clear_by_reason[d][reason] += 1
        self._emit("clear", d, now_j, slot=x, note=reason)
        x.used = False

    def loop_retire(self, d: str, x: Slot, now_j: int, reason: str) -> None:
        """samon_loop_retire: read 칸 x를 비우거나 교체하기 직전에 호출한다(R8.13).

        길이(끝 − 시작) ≥ samon_loop_min_kb × 2 sector일 때만 (dev, 시작, 끝, 시작 시각)을
        원형 커서 자리에 기록하고, 기록 여부와 관계없이 x를 비운다. 기록과 비우기는
        한 번에 일어나므로 한 흐름은 최대 한 번만 기록된다(비워진 칸은 used = False).
        """
        if self.loops and x.end - x.start >= self._loop_min():
            i = self.loop_next
            self.loops[i] = LoopRec(True, x.dev, x.start, x.end, x.t_start)
            self.loop_next = (i + 1) % len(self.loops)
            self._emit("loop_record", d, now_j, i, self.loops[i])
        self._clear(d, x, reason, now_j)

    def loop_match(self, x: Slot, now_j: int) -> None:
        """samon_loop_match: 새 read 칸 x의 (dev, 시작 sector)를 (b) live 칸, (a) Loop_History 순으로 대조한다(R8.15).

        (b) = x를 뺀 사용 중인 read 칸 중 같은 dev·시작 sector이고 길이 ≥ samon_loop_min_kb × 2.
        (a) = Loop_History의 같은 dev·시작 sector 기록. 둘 다 맞으면 (b)를 쓴다.
        같은 쪽에서 여러 개가 맞으면 t_start가 가장 최근인 것(동률이면 작은 index)을 쓴다.
        (b)를 쓰면 옛 칸을 loop_retire로 기록하고 비운다. (a) 기록은 지우지 않는다.
        """
        min_len = self._loop_min()
        live: Slot | None = None
        for y in self.streams["R"]:
            if (y is x or not y.used or y.dev != x.dev or y.start != x.start
                    or y.end - y.start < min_len):
                continue
            if live is None or y.t_start > live.t_start:
                live = y
        hist: LoopRec | None = None
        for h in self.loops:
            if not h.used or h.dev != x.dev or h.start != x.start:
                continue
            if hist is None or h.t_start > hist.t_start:
                hist = h
        if live is not None:
            x.loop = True
            x.loop_len = live.end - live.start
            x.period = now_j - live.t_start
            self.n_loop_mark_b += 1
            self._emit("loop_mark", "R", now_j, slot=x, info=x.loop_len, note="b")
            self.loop_retire("R", live, now_j, "live")
        elif hist is not None:
            x.loop = True
            x.loop_len = hist.end - hist.start
            x.period = now_j - hist.t_start
            self.n_loop_mark_a += 1
            self._emit("loop_mark", "R", now_j, slot=x, info=x.loop_len, note="a")

    def tick(self, now_j: int) -> None:
        """samon_idle_sweep: sample interval 경계 하나(시각 now_j, ms)의 idle 정리(R8.14).

        사용 중인 read 칸 중 now_j ≥ t_last + samon_stream_idle_ms 이고 길이 ≥
        samon_loop_min_kb × 2 인 칸을 loop_retire로 기록하고 비운다. 그 밖의 read 칸과
        모든 write 칸은 바꾸지 않는다.
        """
        self.now_j = now_j
        idle = self.p.samon_stream_idle_ms
        min_len = self._loop_min()
        for x in self.streams["R"]:
            if x.used and now_j >= x.t_last + idle and x.end - x.start >= min_len:
                self.n_idle_clears += 1
                self._emit("idle", "R", now_j, slot=x)
                self.loop_retire("R", x, now_j, "idle")

    def advance(self, ts_ns: int) -> None:
        """ts_ns 이하의 sample interval 경계를 모두 처리한다(다음 complete를 처리하기 전에 호출).

        경계 시각은 t0_ns + k × sample_us × 1000 (k ≥ 1)이고 tick에는 ms로 내림해 넘긴다.
        칸 상태는 경계 사이에 변하지 않으므로, 정리 대상이 될 수 있는 가장 이른 시각 전의
        경계는 아무것도 바꾸지 않는다. 그런 경계는 건너뛰어도 결과가 같다.
        """
        if self.t0_ns is None:
            self.t0_ns = ts_ns
        step = self.p.sample_us * 1000
        if step <= 0:
            return
        t0 = self.t0_ns
        idle = self.p.samon_stream_idle_ms
        min_len = self._loop_min()
        while True:
            due = [x.t_last + idle for x in self.streams["R"]
                   if x.used and x.end - x.start >= min_len]
            last_k = (ts_ns - t0) // step  # ts_ns 이하의 마지막 경계 번호
            if not due:
                self._next_k = max(self._next_k, last_k + 1)
                return
            k = max(self._next_k, -(-(min(due) * 1_000_000 - t0) // step))
            if k > last_k:
                self._next_k = max(self._next_k, last_k + 1)
                return
            self.tick((t0 + k * step) // 1_000_000)
            self._next_k = k + 1

    def finish(self, now_j: int | None = None) -> None:
        """trace 끝: 사용 중인 칸을 방향 구분 없이 전부 비운다(사유 "trace_end").

        Loop_History에는 기록하지 않는다(이후 request가 없다). 연속 횟수는 (e)에 남는다.
        """
        if now_j is None:
            now_j = self.now_j
        for d in DIRS:
            for x in self.streams[d]:
                if x.used:
                    self._clear(d, x, "trace_end", now_j)

    # -- Stream_Table 갱신 (K3) -----------------------------------------------

    def stream_update(self, d: str, dev: int, s: int, n: int, now_j: int) -> Flow:
        """request(방향 d, dev_t, 시작 sector s, 완료 sector 수 n)로 Stream_Table을 한 번 갱신한다.

        n > 0을 전제로 한다. 비교는 뺄셈 없이 K3의 형태로 한다.
        """
        T = self.streams[d]
        C = self.counters[d]
        self.now_j = now_j
        e = s + n
        gap = self.p.samon_stream_gap_req * n
        ext = pre = fil = None
        n_rst = 0
        for i, y in enumerate(T):  # index 오름차순
            if not y.used or y.dev != dev:
                continue
            if y.end <= s <= y.end + gap:
                ext = self.better(ext, i, T)
            elif e <= y.start <= e + gap:
                pre = self.better(pre, i, T)
            elif y.start <= s and e <= y.end:
                if s + gap >= y.end:
                    fil = self.better(fil, i, T)
                else:
                    n_rst += 1  # restart 칸: 바꾸지 않는다
        xi: int | None = None
        if ext is not None:
            xi = ext
            x = T[xi]
            x.end = e
            self._bump(x, now_j)
            C.extend += 1
            self._emit("extend", d, now_j, xi, x)
        elif pre is not None:
            xi = pre
            x = T[xi]
            x.start = s
            self._bump(x, now_j)
            C.prepend += 1
            self._emit("prepend", d, now_j, xi, x)
        elif fil is not None:
            xi = fil
            x = T[xi]
            self._bump(x, now_j)  # 경계, t_start, loop, L, 주기 불변
            C.fill += 1
            self._emit("fill", d, now_j, xi, x)
        else:
            # 맞는 칸 없음. restart 칸 수와 관계없이 request당 1회만 센다 (R8.25)
            if n_rst:
                C.restart += 1
                self._emit("restart", d, now_j, info=n_rst)
            if n >= self.p.samon_stream_new_kb * 2:
                xi = self.pick_slot(T)
                old = T[xi]
                if old.used:
                    C.evict += 1
                    self._emit("evict", d, now_j, xi, old)
                    if d == "R":
                        self.loop_retire(d, old, now_j, "evict")  # R8.13, 덮어쓰기 전
                    else:
                        self._clear(d, old, "evict", now_j)
                T[xi] = Slot(used=True, dev=dev, start=s, end=e, count=1,
                             t_start=now_j, t_last=now_j)
                C.new_slot += 1
                self._emit("new_slot", d, now_j, xi, T[xi])
                if d == "R":
                    self.loop_match(T[xi], now_j)  # R8.15
        return self.flow_of(d, T[xi] if xi is not None else None)

    @staticmethod
    def _bump(x: Slot, now_j: int) -> None:
        x.count += 1
        x.t_last = now_j

    # -- request 입력 ---------------------------------------------------------

    def stream_request(self, rec: Record) -> Flow | None:
        """complete 레코드 하나로 Stream_Table을 갱신한다. 규칙에서 뺀 레코드는 None.

        rwbs 첫 글자가 R/W가 아니거나 nr_sector = 0이면 표를 바꾸지 않고 수만 센다(R5.5).
        """
        d = rec.rwbs[:1]
        if d not in DIRS:
            self.n_excluded_rwbs += 1
            return None
        if rec.nr_sector == 0:
            self.n_excluded_zero += 1
            return None
        self.n_requests += 1
        return self.stream_update(d, rec.dev_t, rec.sector, rec.nr_sector,
                                  self.now_of(rec.ts_ns))

    def stream_counters(self) -> dict[str, int]:
        """Stream_Counters 12개를 커널 이름(stream_r_extend, …)으로 돌려준다."""
        return {f"stream_{d.lower()}_{k}": v
                for d in DIRS for k, v in self.counters[d].as_dict().items()}

    # -- Reread_Table (K4) ----------------------------------------------------

    @staticmethod
    def reread_index(dev_t: int, lba4k: int, nslots: int) -> int:
        """칸 번호: key = lba4k ^ (dev_t << 40), idx = reciprocal_scale(hash_64(key, 32), nslots)."""
        key = (lba4k ^ (dev_t << 40)) & _M64
        h32 = ((key * GOLDEN_RATIO_64) & _M64) >> 32      # hash_64(key, 32)
        return (h32 * nslots) >> 32                        # reciprocal_scale

    def reread_hit(self, dev_t: int, lba4k: int, now_j: int) -> bool:
        """samon_reread_hit: 조회와 덮어쓰기를 한 번에 한다(R8.18).

        칸의 키 원본(dev 하위 32비트, lba4k)이 같고 (now32 − 칸 시각) mod 2^32 ≤
        samon_reread_ms이면 hit. hit 여부와 관계없이 칸을 현재 키·시각으로 덮어쓴다.
        """
        idx = self.reread_index(dev_t, lba4k, self.p.samon_reread_slots)
        now32 = now_j & _M32
        old = self.reread.get(idx)
        hit = (old is not None and old[0] == (dev_t & _M32) and old[1] == lba4k
               and ((now32 - old[2]) & _M32) <= self.p.samon_reread_ms)
        self.reread[idx] = (dev_t & _M32, lba4k, now32)
        if hit:
            self.n_reread_hit += 1
        if self.log:
            self.events.append(Event("reread", "R", now_j, idx, lba4k, lba4k, 0, 0,
                                     "hit" if hit else "miss"))
        return hit

    # -- segment 판정 (K2 samon_classify_seg) ---------------------------------

    def classify_seg(self, d: str, dev_t: int, lba: int, flow: Flow,
                     now_j: int) -> tuple[str, str]:
        """segment 하나의 (패턴, 동작). read는 P3 > P1 > P2 > P6, write는 P4 또는 rest(P6).

        P3의 거리 d = lba − flow.start(음수면 0)이고 `100·d < L·pct`이면 promote, 아니면
        demote. P1·P3·P4가 아닌 read segment만 Reread_Table을 조회·갱신한다.
        """
        if d == "R":
            if flow.kind == "P3":
                dist_ = lba - flow.start if lba > flow.start else 0
                if 100 * dist_ < flow.loop_len * self.p.samon_loop_protect_pct:
                    return "P3", "promote"
                return "P3", "demote"
            if flow.kind == "P1":
                return "P1", "demote"
            if self.reread_hit(dev_t, lba >> 3, now_j):
                return "P2", "promote"
            return "P6", "none"
        if flow.kind == "P4":
            return "P4", "demote"
        return "P6", "none"

    # -- complete 레코드 하나 -------------------------------------------------

    def complete(self, rec: Record) -> list[SegResult]:
        """정렬된 complete 레코드 하나를 처리하고 segment별 결과를 돌려준다.

        순서: advance(rec.ts_ns) → 제외 검사 → stream_update(request당 1회) →
        segment마다 classify_seg. 흐름 판정은 request의 모든 segment에 같이 적용된다(R8.1).
        제외된 레코드(rwbs 첫 글자가 R/W 아님, nr_sector = 0, dev_t = 0)는 빈 목록이다.
        segment 수 k = ⌈nr_sector / 8⌉ (trace에 SAMON_Filter가 없어 모두 통과로 본다).
        """
        self.advance(rec.ts_ns)
        d = rec.rwbs[:1]
        if d not in DIRS:
            self.n_excluded_rwbs += 1
            return []
        if rec.nr_sector == 0:
            self.n_excluded_zero += 1
            return []
        dev_t = rec.dev_t
        if dev_t == 0:
            self.n_excluded_dev0 += 1
            return []
        self.n_requests += 1
        now_j = self.now_of(rec.ts_ns)
        flow = self.stream_update(d, dev_t, rec.sector, rec.nr_sector, now_j)
        out: list[SegResult] = []
        for i in range((rec.nr_sector + 7) // 8):
            lba = rec.sector + 8 * i
            pat, act = self.classify_seg(d, dev_t, lba, flow, now_j)
            self.det[pat] += 1
            out.append(SegResult(pat, act, d, dev_t, lba, lba >> 3, rec.ts_ns, rec.cpu))
        return out


# ---------------------------------------------------------------------------
# 재현 실행 helper
# ---------------------------------------------------------------------------

@dataclass
class ReplayResult:
    """replay 결과. results = 모든 segment 판정(complete 처리 순서)."""

    engine: Engine
    results: list[SegResult]
    n_complete: int  # 정렬해 엔진에 넣은 complete 레코드 수(제외된 것 포함)


def replay(records: Iterable[Record], params: Params | None = None, log: bool = False,
           t0_ns: int | None = None, keep_results: bool = True) -> ReplayResult:
    """records를 규칙 엔진에 재현한다(R5.4).

    complete 레코드만 (ts_ns, 입력 순서)로 안정 정렬해 complete()에 넣고, 끝에 finish()를
    부른다. sample interval 경계의 원점 t0_ns는 인자가 없으면 입력 레코드(issue 포함)
    전체의 가장 이른 시각이다. 같은 입력과 옵션이면 결과가 같다.
    keep_results=False면 SegResult를 모으지 않고 엔진 카운터만 남긴다(메모리 절약).
    """
    recs = list(records)
    eng = Engine(params, log=log)
    if recs:
        eng.t0_ns = t0_ns if t0_ns is not None else min(r.ts_ns for r in recs)
    elif t0_ns is not None:
        eng.t0_ns = t0_ns
    comp = sorted_complete(recs)
    results: list[SegResult] = []
    for r in comp:
        segs = eng.complete(r)
        if keep_results:
            results.extend(segs)
    eng.finish(eng.now_j)
    return ReplayResult(eng, results, len(comp))


# ---------------------------------------------------------------------------
# QueueModel: Deferred_Queue와 Actuator 회계 모델 (테스트 전용, design K5/K6/T2)
#
# trace 재현(replay)에는 쓰지 않는다. 커널 samon_enqueue / samon_actuate /
# samon_process / damon_sa_cleanup(samon_q_shutdown)의 회계를 같은 순서로 옮겨
# 요구사항 4 기준 3~5, 요구사항 7 기준 2, 4, 6, 11의 등식을 시험하기 위한 모델이다.
# ---------------------------------------------------------------------------

QPATS = (1, 2, 3, 4, 5)  # 큐에 들어가는 패턴 번호 N (P1~P5)
DROP_REASONS = ("queue", "stale", "revalidate", "toggle", "shutdown")  # enum samon_drop 순서
# 패턴별 기본 동작. P3는 범위 앞부분이면 promote, 나머지는 demote라 호출자가 act를 줄 수 있다.
DEFAULT_ACT = {1: "demote", 2: "promote", 3: "promote", 4: "demote", 5: "mark"}
QACTS = ("promote", "demote", "mark")


@dataclass
class Folio:
    """처리 시점 folio 상태. refs = 모델이 잡은 참조 수(get - put)."""

    lru: bool = True
    mapping: bool = True
    unevictable: bool = False
    dirty: bool = False
    writeback: bool = False
    refs: int = 0


@dataclass(frozen=True)
class QItem:
    """Deferred_Queue 항목 (folio, 동작, 패턴 번호, 요청 시각 jiffies = ms)."""

    folio: Folio
    act: str
    pat: int
    t_req: int


class QAcct:
    """큐 회계 (커널 struct samon_qacct). 패턴 N = 1~5."""

    def __init__(self) -> None:
        self.req = {p: 0 for p in QPATS}
        self.exec = {p: 0 for p in QPATS}
        self.drop = {r: {p: 0 for p in QPATS} for r in DROP_REASONS}
        self.inflight = 0

    def add(self, o: "QAcct") -> None:
        """samon_qacct_add: o를 더한다(inflight 포함)."""
        for p in QPATS:
            self.req[p] += o.req[p]
            self.exec[p] += o.exec[p]
            for r in DROP_REASONS:
                self.drop[r][p] += o.drop[r][p]
        self.inflight += o.inflight

    def drops(self, p: int) -> int:
        return sum(self.drop[r][p] for r in DROP_REASONS)


class QueueModel:
    """Deferred_Queue + Actuator 회계 모델.

    - CPU마다 길이 q_len 링(ring)과 회계(acct)를 가진다(커널의 큐 lock 아래 값).
    - enqueue(cpu, pat, ...)는 자기 CPU 큐에만 넣고, 토글이 0이면 아무것도 세지 않는다.
    - drain()은 CPU마다 ring 전부를 드레인 배열로 옮겨(inflight 유지) 항목마다
      (a) toggle -> (b) stale -> (c) revalidate -> (d) exec 중 정확히 하나를 세고
      folio 참조를 정확히 1회 놓은 뒤 결과를 합산하고 inflight를 줄인다.
    - shutdown()은 잔여 항목을 LRU 조작 없이 drop_shutdown으로 세고 참조를 놓은 뒤
      acct를 total에 합치고 큐를 비운다. 그 뒤 enqueue는 세지 않고 "inactive"를 돌려준다
      (probe 해제 상태). start()로 새 실행을 시작한다.
    - 시간은 jiffies = ms(HZ = 1000). now는 advance_time으로만 늘어난다.
    """

    def __init__(self, ncpu: int = 1, q_len: int = 1024, q_max_ms: int = 100,
                 toggles: dict[int, bool] | None = None) -> None:
        if ncpu < 1:
            raise ValueError("ncpu must be >= 1")
        self.ncpu = ncpu
        self.q_max_ms = q_max_ms
        # P1~P4는 samon_act_pN(기본 0), P5는 samon_opt_b(기본 1)
        self.toggle = {1: False, 2: False, 3: False, 4: False, 5: True}
        if toggles:
            for p, on in toggles.items():
                self.set_toggle(p, on)
        self.now = 0
        self.total = QAcct()  # 끝난 실행들의 누적(samon_qacct_total)
        self.max_delay_us = 0
        self.direct_ops = 0  # 항상 0: 조작은 drain(kdamond) 안에서만 일어난다
        self.prim_calls: list[tuple[str, int, Folio]] = []  # (d)에서만 쌓인다
        self.refs_got = 0
        self.refs_put = 0
        self.running = False
        self.start(q_len)

    # -- 시작/정지 ---------------------------------------------------------
    def start(self, q_len: int | None = None) -> None:
        """kdamond 시작(damon_sa_init): ring 할당, 최대 지연 0으로 초기화."""
        if self.running:
            raise RuntimeError("already running")
        if q_len is not None:
            if q_len < 1:
                raise ValueError("q_len must be >= 1")
            self.q_len = q_len
        self.ring: list[list[QItem]] = [[] for _ in range(self.ncpu)]
        self.acct: list[QAcct] = [QAcct() for _ in range(self.ncpu)]
        self.max_delay_us = 0
        self.running = True

    def shutdown(self) -> None:
        """damon_sa_cleanup: 잔여 항목마다 drop_shutdown, folio_put 1회, 합산 후 해제."""
        if not self.running:
            return
        self.running = False
        for cpu in range(self.ncpu):
            items, self.ring[cpu] = self.ring[cpu], []
            a = self.acct[cpu]
            for it in items:
                a.drop["shutdown"][it.pat] += 1
                self._put(it.folio)
            a.inflight -= len(items)
            self.total.add(a)
        self.acct = [QAcct() for _ in range(self.ncpu)]

    # -- 파라미터 ----------------------------------------------------------
    def set_toggle(self, pat: int, on: bool) -> None:
        if pat not in QPATS:
            raise ValueError(f"pattern {pat} has no toggle")
        self.toggle[pat] = bool(on)

    def advance_time(self, ms: int) -> int:
        if ms < 0:
            raise ValueError("time cannot go back")
        self.now += ms
        return self.now

    # -- 참조 --------------------------------------------------------------
    def _get(self, f: Folio) -> None:
        f.refs += 1
        self.refs_got += 1

    def _put(self, f: Folio) -> None:
        f.refs -= 1
        self.refs_put += 1

    # -- 생산자 ------------------------------------------------------------
    def enqueue(self, cpu: int, pat: int, folio: Folio | None = None,
                act: str | None = None) -> str:
        """samon_enqueue. 반환: "inactive" | "disabled" | "queued" | "drop_queue"."""
        if pat not in QPATS:
            raise ValueError(f"pattern {pat} cannot be queued")
        if not self.running:
            return "inactive"
        if not self.toggle[pat]:
            return "disabled"  # 토글 0: req_pN을 올리지 않는다(R4.5)
        act = act or DEFAULT_ACT[pat]
        if act not in QACTS:
            raise ValueError(f"unknown act {act!r}")
        a = self.acct[cpu]
        a.req[pat] += 1
        if len(self.ring[cpu]) >= self.q_len:
            a.drop["queue"][pat] += 1  # folio_get 하지 않음(R7.11)
            return "drop_queue"
        f = folio if folio is not None else Folio()
        self._get(f)
        self.ring[cpu].append(QItem(f, act, pat, self.now))
        a.inflight += 1
        return "queued"

    # -- 소비자 ------------------------------------------------------------
    def drain(self, resolve: Callable[[QItem], Folio] | None = None) -> int:
        """samon_actuate: CPU마다 ring 전부를 꺼내 처리한다. 처리한 항목 수를 돌려준다.

        resolve(item)이 있으면 처리 시점의 folio 상태를 그 반환값으로 쓰고,
        없으면 item.folio를 그대로 쓴다(생성기가 상태를 미리 정해 둘 수 있다).
        """
        if not self.running:
            return 0
        total = 0
        for cpu in range(self.ncpu):
            batch, self.ring[cpu] = self.ring[cpu], []
            b = QAcct()
            for it in batch:
                self._process(it, b, resolve(it) if resolve else it.folio)
            a = self.acct[cpu]
            a.add(b)  # exec, drop 합산 (b.inflight = 0)
            a.inflight -= len(batch)
            total += len(batch)
        return total

    def _process(self, it: QItem, b: QAcct, state: Folio) -> None:
        """samon_process: (a)~(d) 중 정확히 하나, folio_put 정확히 1회."""
        k = it.pat
        if not self.toggle[k]:  # (a)
            b.drop["toggle"][k] += 1
        elif self.now - it.t_req > self.q_max_ms:  # (b) time_after(now, t_req + max)
            b.drop["stale"][k] += 1
        elif (not state.lru or not state.mapping or state.unevictable
              or (k == 4 and (state.dirty or state.writeback))):  # (c) dirty/writeback은 P4만
            b.drop["revalidate"][k] += 1
        else:  # (d)
            self.prim_calls.append((it.act, k, it.folio))
            b.exec[k] += 1
        self.max_delay_us = max(self.max_delay_us, (self.now - it.t_req) * 1000)
        self._put(it.folio)

    # -- 관찰 --------------------------------------------------------------
    @property
    def q_cur(self) -> int:
        """읽는 시점의 전 CPU 큐 항목 수(드레인은 한 번에 끝나므로 미집계 항목은 없다)."""
        return sum(len(r) for r in self.ring) if self.running else 0

    def totals(self) -> QAcct:
        """samon_stats_show 합산: total + CPU별 acct."""
        t = QAcct()
        t.add(self.total)
        if self.running:
            for a in self.acct:
                t.add(a)
        return t

    def balance(self, pat: int) -> int:
        """req - (exec + 모든 drop + inflight). 항상 0이어야 한다."""
        t = self.totals()
        return t.req[pat] - (t.exec[pat] + t.drops(pat) + t.inflight)

    def stats(self) -> dict[str, int]:
        """SAMON_Stats 이름(req_pN, exec_pN, drop_<사유>_pN, q_cur, ...)으로 내보낸다."""
        t = self.totals()
        out: dict[str, int] = {}
        for p in QPATS:
            out[f"req_p{p}"] = t.req[p]
            out[f"exec_p{p}"] = t.exec[p]
            for r in DROP_REASONS:
                out[f"drop_{r}_p{p}"] = t.drop[r][p]
        out["q_cur"] = self.q_cur
        out["q_max_delay_us"] = self.max_delay_us
        out["direct_ops"] = self.direct_ops
        return out
