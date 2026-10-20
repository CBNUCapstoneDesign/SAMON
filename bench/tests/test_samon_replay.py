"""Tests for bench/samon_replay.py (S0 Replay_Script)."""

import os
import sys

from hypothesis import given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from samon_replay import Record, format_record, parse_line  # noqa: E402

# ---------------------------------------------------------------------------
# 생성기
# ---------------------------------------------------------------------------

# 0 이상 정수 필드. 실제 범위(u64 ts, u32 cpu, 12/20비트 major/minor, u64 sector,
# u32 nr_sector)보다 넓게 잡아 파서가 크기에 의존하지 않는지도 본다.
_u64 = st.integers(min_value=0, max_value=2**64 - 1)
_u32 = st.integers(min_value=0, max_value=2**32 - 1)

# rwbs: 커널 blk_fill_rwbs가 쓰는 글자(R W D N F S M A E 등) + FUA, 공백 없음, 비어 있지 않음
_RWBS_CHARS = "RWDNFSMAEU"
_rwbs = st.one_of(
    st.sampled_from(["R", "RA", "RS", "RM", "W", "WS", "WM", "WFS", "FWS",
                     "WFUA", "FWFUA", "D", "DS", "N", "F", "RSM"]),
    st.text(alphabet=_RWBS_CHARS, min_size=1, max_size=8),
)

records = st.builds(
    Record,
    kind=st.sampled_from(["I", "C"]),
    ts_ns=_u64,
    cpu=_u32,
    major=st.integers(min_value=0, max_value=4095),
    minor=st.integers(min_value=0, max_value=2**20 - 1),
    sector=_u64,
    nr_sector=_u32,
    rwbs=_rwbs,
)

# 유효 레코드 줄: 필드 사이 구분을 공백·탭 1~3개로 바꾸고 앞뒤 공백·줄바꿈을 섞는다
_sep = st.text(alphabet=" \t", min_size=1, max_size=3)


@st.composite
def record_lines(draw):
    r = draw(records)
    fields = format_record(r).split(" ")
    seps = [draw(_sep) for _ in range(len(fields) - 1)]
    body = fields[0] + "".join(s + f for s, f in zip(seps, fields[1:]))
    lead = draw(st.text(alphabet=" \t", max_size=2))
    tail = draw(st.sampled_from(["", "\n", " \n", "\t"]))
    return lead + body + tail


# ---------------------------------------------------------------------------
# Property 1
# ---------------------------------------------------------------------------

# Feature: samon-path-b-completion, Property 1: trace 레코드 round-trip
# **Validates: Requirements 5.7**
@settings(max_examples=200, deadline=None)
@given(r=records)
def test_property1_record_roundtrip(r):
    line = format_record(r)
    assert "\n" not in line
    assert len(line.split(" ")) == 7
    assert parse_line(line) == r


# Feature: samon-path-b-completion, Property 1: trace 레코드 round-trip
# **Validates: Requirements 5.7**
@settings(max_examples=200, deadline=None)
@given(s=record_lines())
def test_property1_line_parse_format_parse(s):
    p1 = parse_line(s)
    assert p1 is not None
    p2 = parse_line(format_record(p1))
    assert p2 == p1
    # 7개 필드 모두 같음(dataclass 동등성과 별도로 명시)
    for name in ("kind", "ts_ns", "cpu", "major", "minor",
                 "sector", "nr_sector", "rwbs"):
        assert getattr(p2, name) == getattr(p1, name)


# ---------------------------------------------------------------------------
# 4.1 Engine: Stream_Table 갱신 단위 테스트
# ---------------------------------------------------------------------------
from samon_replay import Engine, Params, Slot, sorted_complete  # noqa: E402

DEV = (8 << 20) | 0


def _eng(**kw):
    return Engine(Params(**kw), log=True)


def _kinds(eng):
    return [ev.kind for ev in eng.events]


def test_extend_prepend_and_one_counter_only():
    eng = _eng()
    eng.stream_update("R", DEV, 1000, 128, 1)       # new_slot (64KiB = 128 sector)
    eng.stream_update("R", DEV, 1128, 128, 2)       # extend
    eng.stream_update("R", DEV, 872, 128, 3)        # prepend (e = 1000 = start)
    s = eng.streams["R"][0]
    assert (s.start, s.end, s.count, s.t_last) == (872, 1256, 3, 3)
    assert eng.counters["R"].as_dict() == dict(
        extend=1, prepend=1, fill=0, restart=0, new_slot=1, evict=0)
    assert _kinds(eng) == ["new_slot", "extend", "prepend"]


def test_fill_keeps_shape_restart_leaves_slot():
    eng = _eng()
    eng.stream_update("R", DEV, 0, 1024, 10)        # slot [0, 1024)
    s = eng.streams["R"][0]
    before = (s.start, s.end, s.t_start, s.loop, s.loop_len, s.period)
    # fill: s + gap >= end  (gap = 2 * 8 = 16), s = 1008, e = 1016 <= end
    eng.stream_update("R", DEV, 1008, 8, 11)
    assert (s.start, s.end, s.t_start, s.loop, s.loop_len, s.period) == before
    assert (s.count, s.t_last) == (2, 11)
    # restart: 안쪽 4KB, s + gap < end, n < new_kb*2 -> 표 불변, 흐름 없음
    snap = (s.start, s.end, s.count, s.t_last)
    f = eng.stream_update("R", DEV, 100, 8, 12)
    assert f.kind == "NONE"
    assert (s.start, s.end, s.count, s.t_last) == snap
    c = eng.counters["R"]
    assert (c.fill, c.restart, c.new_slot, c.evict) == (1, 1, 1, 0)
    assert _kinds(eng)[-1] == "restart"


def test_restart_counts_once_then_new_slot_for_large_request():
    eng = _eng()
    eng.stream_update("R", DEV, 0, 1024, 1)
    eng.stream_update("R", DEV, 100000, 1024, 2)    # 두 번째 칸 [100000, 101024)
    # 두 칸 모두에 restart가 아닌 request: [0, 256) 은 칸 0 안쪽 -> restart 1회, new_slot
    eng.streams["R"][1].start, eng.streams["R"][1].end = 0, 1024  # 두 칸이 모두 restart 칸이 되게 함
    eng.stream_update("R", DEV, 0, 256, 3)
    c = eng.counters["R"]
    assert c.restart == 1 and c.new_slot == 3
    assert [ev.kind for ev in eng.events][-2:] == ["restart", "new_slot"]
    assert eng.events[-2].info == 2


def test_kind_priority_and_tiebreak():
    eng = _eng(samon_stream_slots=3)
    T = eng.streams["R"]
    # 0: fill 후보, 1: extend 후보, 2: extend 후보 (count/t_last 동률 -> 작은 index)
    T[0] = Slot(True, DEV, 0, 1008, 9, 0, 5)
    T[1] = Slot(True, DEV, 5000, 1000, 2, 0, 5)
    T[2] = Slot(True, DEV, 6000, 1000, 2, 0, 5)
    T[1].start, T[1].end = 500, 1000
    T[2].start, T[2].end = 600, 1000
    eng.stream_update("R", DEV, 1000, 8, 20)        # extend: 1, 2 / fill: 0
    assert eng.counters["R"].extend == 1 and eng.counters["R"].fill == 0
    assert T[1].count == 3 and T[2].count == 2 and T[0].count == 9
    # t_last가 더 최근인 칸 우선
    T[1].t_last, T[2].t_last = 5, 7
    T[1].end = T[2].end = 1000
    T[1].count = T[2].count = 4
    eng.stream_update("R", DEV, 1000, 8, 21)
    assert T[2].count == 5 and T[1].count == 4


def test_other_direction_and_dev_ignored_and_evict_choice():
    eng = _eng(samon_stream_slots=2)
    eng.stream_update("W", DEV, 0, 128, 1)
    eng.stream_update("R", DEV + 1, 128, 128, 1)
    eng.stream_update("R", DEV, 128, 128, 2)        # W 칸, 다른 dev 칸에 붙지 않는다
    assert eng.counters["R"].extend == 0 and eng.counters["R"].new_slot == 2
    eng.stream_update("R", DEV, 5000, 128, 3)       # 가득 참 -> count 같음, t_last 오래된 칸 교체
    assert eng.counters["R"].evict == 1
    assert eng.streams["R"][0].start == 5000 and eng.streams["R"][0].dev == DEV
    assert eng.streams["R"][1].start == 128 and eng.streams["R"][1].dev == DEV


def test_stream_request_exclusions_and_sort():
    eng = Engine()
    recs = [
        Record("C", 5_000_000, 0, 8, 0, 0, 128, "R"),
        Record("I", 1_000_000, 0, 8, 0, 0, 128, "R"),
        Record("C", 1_000_000, 0, 8, 0, 128, 128, "RA"),
        Record("C", 5_000_000, 0, 8, 0, 256, 128, "R"),
    ]
    out = sorted_complete(recs)
    assert [r.sector for r in out] == [128, 0, 256]      # ts 순, 같은 ts는 파일 순서
    for r in out + [Record("C", 9, 0, 8, 0, 0, 0, "R"), Record("C", 9, 0, 8, 0, 0, 8, "FWS")]:
        eng.stream_request(r)
    assert eng.n_excluded_zero == 1 and eng.n_excluded_rwbs == 1 and eng.n_requests == 3
    sc = eng.stream_counters()
    assert (sc["stream_r_prepend"], sc["stream_r_extend"], sc["stream_r_new_slot"]) == (1, 1, 1)


# ---------------------------------------------------------------------------
# 4.2 Loop_History, idle 정리, trace 끝 비우기 단위 테스트
# ---------------------------------------------------------------------------

# loop_min_kb = 8 KiB -> 16 sector 이상이 "긴" 흐름. 테스트에서는 작은 값으로 줄인다.
def _leng(**kw):
    kw.setdefault("samon_loop_min_kb", 8)
    return Engine(Params(**kw), log=True)


def _put(eng, i, start, end, t_start=0, t_last=0, count=1, d="R", dev=DEV):
    eng.streams[d][i] = Slot(True, dev, start, end, count, t_start, t_last)
    return eng.streams[d][i]


def test_loop_retire_records_only_long_flows_and_clears_slot():
    eng = _leng()
    short = _put(eng, 0, 0, 15)                     # 15 sector < 16
    eng.loop_retire("R", short, 5, "evict")
    assert not short.used and not eng.loops[0].used and eng.loop_next == 0
    long_ = _put(eng, 1, 100, 116, t_start=7)       # 정확히 16 sector
    eng.loop_retire("R", long_, 9, "evict")
    assert not long_.used
    h = eng.loops[0]
    assert (h.used, h.dev, h.start, h.end, h.t_start) == (True, DEV, 100, 116, 7)
    assert eng.loop_next == 1
    assert _kinds(eng) == ["clear", "loop_record", "clear"]
    # 비워진 칸은 두 번 기록되지 않는다: 같은 흐름은 used=False이므로 tick도 건드리지 않는다
    eng.tick(10**9)
    assert eng.loops[1].used is False


def test_loop_history_cursor_wraps_and_overwrites_oldest():
    eng = _leng(samon_loop_slots=2)
    for i, st in enumerate((0, 1000, 2000)):
        x = _put(eng, 0, st, st + 16, t_start=i)
        eng.loop_retire("R", x, i, "evict")
    assert [h.start for h in eng.loops] == [2000, 1000]   # 가장 먼저 기록된 칸이 덮어써짐
    assert eng.loop_next == 1


def test_loop_match_live_preferred_over_history_and_retires_old_slot():
    eng = _leng()
    eng.loops[0] = type(eng.loops[0])(True, DEV, 500, 500 + 64, 1)   # (a) L = 64
    eng.loop_next = 1                                                 # 커서는 기록 다음 칸
    old = _put(eng, 0, 500, 500 + 32, t_start=100, t_last=150)       # (b) L = 32
    new = _put(eng, 1, 500, 500 + 20, t_start=400, t_last=400)
    eng.loop_match(new, 400)
    assert new.loop and new.loop_len == 32 and new.period == 300
    assert not old.used
    assert eng.loops[0].end == 564                  # (a) 기록은 그대로
    assert eng.loops[1].used and eng.loops[1].end == 532   # 옛 칸이 기록됨
    assert (eng.n_loop_mark_b, eng.n_loop_mark_a) == (1, 0)
    assert eng.clear_by_reason["R"]["live"] == 1
    assert [e.note for e in eng.events if e.kind == "loop_mark"] == ["b"]


def test_loop_match_history_keeps_record_and_picks_latest_t_start():
    eng = _leng()
    L = type(eng.loops[0])
    eng.loops[0] = L(True, DEV, 500, 532, 10)
    eng.loops[1] = L(True, DEV, 500, 580, 30)       # t_start 최신
    eng.loops[2] = L(True, DEV + 1, 500, 900, 99)   # 다른 dev
    eng.loops[3] = L(True, DEV, 501, 900, 99)       # 다른 시작 sector
    new = _put(eng, 0, 500, 520, t_start=50)
    eng.loop_match(new, 50)
    assert new.loop and new.loop_len == 80 and new.period == 20
    assert all(eng.loops[i].used for i in range(4))  # 지우지 않음
    assert (eng.n_loop_mark_a, eng.n_loop_mark_b) == (1, 0)


def test_loop_match_live_requires_min_len_and_latest_t_start():
    eng = _leng()
    _put(eng, 0, 500, 508, t_start=1)               # 짧은 칸: 대상 아님
    a = _put(eng, 1, 500, 540, t_start=10)
    b = _put(eng, 2, 500, 560, t_start=20)          # 더 최근
    _put(eng, 3, 500, 560, t_start=99, d="W")       # write 칸: 대상 아님
    new = _put(eng, 4, 500, 520, t_start=30)
    eng.loop_match(new, 30)
    assert new.loop and new.loop_len == 60 and new.period == 10
    assert a.used and not b.used                    # 고른 칸만 비워짐
    nomatch = _put(eng, 5, 9000, 9020, t_start=31)
    eng.loop_match(nomatch, 31)
    assert not nomatch.loop


def test_new_read_slot_evict_retires_then_matches_via_history():
    eng = _leng(samon_stream_slots=1, samon_stream_new_kb=8)
    eng.stream_update("R", DEV, 1000, 64, 1)        # 길이 64 >= 16
    eng.stream_update("R", DEV, 50000, 16, 2)       # 교체: 이전 칸이 Loop_History로
    assert eng.loops[0].used and (eng.loops[0].start, eng.loops[0].end) == (1000, 1064)
    f = eng.stream_update("R", DEV, 1000, 16, 3)    # 같은 시작 sector -> (a)
    assert f.kind == "P3" and f.start == 1000 and f.loop_len == 64
    ks = _kinds(eng)
    assert ks.index("loop_record") < ks.index("loop_mark")
    # write 교체는 Loop_History에 기록하지 않는다
    w = _leng(samon_stream_slots=1, samon_stream_new_kb=8)
    w.stream_update("W", DEV, 0, 64, 1)
    w.stream_update("W", DEV, 9000, 16, 2)
    assert not any(h.used for h in w.loops) and w.clear_by_reason["W"]["evict"] == 1


def test_tick_idle_sweep_only_long_idle_read_slots():
    eng = _leng(samon_stream_idle_ms=1000)
    idle_long = _put(eng, 0, 0, 64, t_last=100)
    idle_short = _put(eng, 1, 100, 108, t_last=100)         # 짧음: 대상 아님
    fresh = _put(eng, 2, 200, 264, t_last=500)
    w = _put(eng, 3, 300, 364, t_last=0, d="W")             # write: 대상 아님
    eng.tick(1099)
    assert idle_long.used                                    # 1099 < 100 + 1000
    eng.tick(1100)                                           # 경계 포함 (>=)
    assert not idle_long.used and idle_short.used and fresh.used and w.used
    assert eng.loops[0].used and eng.loops[0].end == 64
    assert eng.n_idle_clears == 1 and eng.clear_by_reason["R"]["idle"] == 1
    assert [e.kind for e in eng.events] == ["idle", "loop_record", "clear"]
    assert eng.events[-1].note == "idle"


def test_advance_processes_every_boundary_before_complete():
    eng = _leng(samon_stream_idle_ms=1000)
    eng.t0_ns = 0
    x = _put(eng, 0, 0, 64, t_last=0)
    # 경계는 5 ms 간격. 정리 가능 시각 1000 ms -> 경계 k=200(1000 ms)에서 비워진다.
    eng.advance(999_999_999)
    assert x.used
    eng.advance(1_000_000_000)
    assert not x.used and eng.events[0].kind == "idle" and eng.events[0].now_j == 1000
    # 경계 사이에서 갱신되면 그 뒤 경계 기준으로 다시 판단한다
    y = _put(eng, 1, 0, 64, t_last=1000)
    eng.advance(1_004_000_000)
    assert y.used
    eng.advance(2_000_000_000)
    assert not y.used and eng.events[-1].now_j == 2000
    # 여러 칸이 서로 다른 경계에 걸리면 각 경계에서 따로 처리된다
    a = _put(eng, 0, 0, 64, t_last=2100)
    b = _put(eng, 1, 100, 164, t_last=2200)
    eng.advance(4_000_000_000)
    assert [e.now_j for e in eng.events if e.kind == "idle"][-2:] == [3100, 3200]
    assert not a.used and not b.used


def test_advance_uses_first_timestamp_as_origin_when_unset():
    eng = _leng()
    eng.advance(7_000_000)
    assert eng.t0_ns == 7_000_000


def test_finish_clears_all_slots_and_reports_counts_without_recording():
    eng = _leng()
    _put(eng, 0, 0, 64, count=5)
    _put(eng, 1, 100, 108, count=2)
    _put(eng, 0, 0, 64, count=7, d="W")
    eng.finish(42)
    assert all(not s.used for d in DIRS_ for s in eng.streams[d])
    assert sorted(eng.clear_counts["R"]) == [2, 5] and eng.clear_counts["W"] == [7]
    assert eng.clear_by_reason["R"]["trace_end"] == 2
    assert eng.clear_by_reason["W"]["trace_end"] == 1
    assert not any(h.used for h in eng.loops)        # trace 끝은 기록하지 않는다
    assert [e.kind for e in eng.events] == ["clear"] * 3
    assert all(e.note == "trace_end" and e.now_j == 42 for e in eng.events)


def test_clear_counts_cover_evict_idle_live_and_trace_end_without_log():
    eng = Engine(Params(samon_loop_min_kb=8, samon_stream_slots=1,
                        samon_stream_new_kb=8), log=False)
    eng.stream_update("R", DEV, 1000, 64, 1)
    eng.stream_update("R", DEV, 1000, 16, 2)         # restart(칸 안쪽) -> 새 칸, 칸 하나라 교체
    assert eng.events == []                           # log=False면 이벤트 없음
    eng.finish()
    r = eng.clear_by_reason["R"]
    assert r["evict"] == 1 and r["trace_end"] == 1
    assert eng.clear_counts["R"] == [1, 1]


DIRS_ = ("R", "W")


# ---------------------------------------------------------------------------
# 4.3 Reread_Table, classify_seg, complete(), replay() 단위 테스트
# ---------------------------------------------------------------------------
from samon_replay import GOLDEN_RATIO_64, SegResult, replay  # noqa: E402

MS = 1_000_000


def _c(ms, sector, nr, rwbs="R", cpu=0, dev=DEV):
    return Record("C", ms * MS, cpu, dev >> 20, dev & 0xFFFFF, sector, nr, rwbs)


def _pats(segs):
    return [s.pat for s in segs]


def test_reread_index_matches_hash64_and_reciprocal_scale():
    assert GOLDEN_RATIO_64 == 0x61C8864680B583EB
    # dev_t = 0, lba4k = 1: hash_64(1, 32) = GOLDEN >> 32 = 0x61C88646
    assert Engine.reread_index(0, 1, 65536) == (0x61C88646 * 65536) >> 32 == 0x61C8
    # key = lba4k ^ (dev_t << 40): 같은 값이 되는 (dev_t, lba4k) 쌍은 같은 칸
    k = (5 ^ (DEV << 40)) & ((1 << 64) - 1)
    h = ((k * GOLDEN_RATIO_64) & ((1 << 64) - 1)) >> 32
    assert Engine.reread_index(DEV, 5, 1000) == (h * 1000) >> 32
    for lba4k in (0, 1, 12345, 2**40):
        assert 0 <= Engine.reread_index(DEV, lba4k, 17) < 17


def test_reread_hit_window_overwrite_and_32bit_wrap():
    eng = _eng(samon_reread_ms=10000)
    assert not eng.reread_hit(DEV, 100, 1000)           # 첫 조회: miss, 기록
    assert eng.reread_hit(DEV, 100, 1000 + 10000)       # 경계 포함 (<=)
    assert eng.reread_hit(DEV, 100, 1000 + 10000 + 10000)  # hit여도 시각을 덮어씀
    assert not eng.reread_hit(DEV, 100, 1000 + 20000 + 10001)
    assert not eng.reread_hit(DEV + 1, 100, 1000 + 20000 + 10002)   # 다른 dev는 다른 키
    # 32비트 시각 감김
    e2 = _eng()
    e2.reread_hit(DEV, 7, 2**32 - 5)
    assert e2.reread_hit(DEV, 7, 2**32 + 3)             # now32 = 3, 차분 8


def test_reread_slot_collision_overwrites():
    eng = _eng(samon_reread_slots=1)                     # 모든 키가 한 칸
    eng.reread_hit(DEV, 1, 10)
    assert not eng.reread_hit(DEV, 2, 11)                # 덮어씀
    assert not eng.reread_hit(DEV, 1, 12)                # 이미 밀려났음
    assert [e.note for e in eng.events if e.kind == "reread"] == ["miss"] * 3


def test_segments_count_start_sector_and_rejected_records():
    eng = Engine()
    segs = eng.complete(_c(1, 5, 17))                    # ⌈17/8⌉ = 3
    assert [s.sector for s in segs] == [5, 13, 21]
    assert [s.lba4k for s in segs] == [0, 1, 2]
    assert all(isinstance(s, SegResult) and s.dev_t == DEV and s.ts_ns == MS for s in segs)
    assert len(eng.complete(_c(2, 800, 8))) == 1
    assert eng.complete(_c(3, 0, 0)) == [] and eng.complete(_c(3, 0, 8, "FWS")) == []
    assert eng.complete(_c(3, 0, 8, dev=0)) == []
    assert (eng.n_excluded_zero, eng.n_excluded_rwbs, eng.n_excluded_dev0) == (1, 1, 1)
    assert eng.n_requests == 2
    assert eng.det == {"P1": 0, "P2": 0, "P3": 0, "P4": 0, "P6": 4}


def test_p1_after_seq_min_requests_and_p6_before():
    eng = _eng()
    out = [eng.complete(_c(i, 128 * i, 128)) for i in range(6)]
    assert [set(_pats(s)) for s in out] == [{"P6"}] * 3 + [{"P1"}] * 3   # count 4부터 P1
    assert all(s.act == "demote" for s in out[3])
    assert all(s.act == "none" for s in out[0])
    assert eng.det["P1"] == 48 and eng.det["P6"] == 48
    # P1 segment는 Reread_Table을 읽지도 갱신하지도 않는다
    rr = [e for e in eng.events if e.kind == "reread"]
    assert len(rr) == 48


def test_p2_same_lba_twice_and_window_boundary():
    eng = Engine(Params(samon_reread_ms=10000))
    assert _pats(eng.complete(_c(0, 800, 8))) == ["P6"]
    s = eng.complete(_c(1000, 800, 8))
    assert (s[0].pat, s[0].act) == ("P2", "promote")
    assert _pats(eng.complete(_c(1000 + 10001, 800, 8))) == ["P6"]       # 창 밖
    assert _pats(eng.complete(_c(1000 + 10001 + 10000, 800, 8))) == ["P2"]  # 경계 포함
    assert eng.n_reread_hit == 2


def test_small_random_read_inside_scanned_range_is_not_p1():
    eng = _eng()
    eng.complete(_c(0, 0, 1024))                         # 큰 read -> 새 칸 [0, 1024)
    s = eng.complete(_c(1, 100, 8))                      # 칸 안쪽 4KB, s + gap < end
    # P1이 아니다. 큰 read가 같은 4KB를 이미 읽었으므로 segment 판정은 P2이다
    assert _pats(s) == ["P2"]
    assert _pats(eng.complete(_c(2, 900_000, 8))) == ["P6"]   # 처음 보는 LBA는 P6
    c = eng.counters["R"]
    assert (c.restart, c.new_slot, c.fill, c.extend) == (1, 1, 0, 0)
    assert (eng.streams["R"][0].start, eng.streams["R"][0].end,
            eng.streams["R"][0].count) == (0, 1024, 1)


def test_write_p4_after_seq_min_else_rest_and_reads_ignore_write_slots():
    eng = Engine()
    out = [eng.complete(_c(i, 128 * i, 128, "W")) for i in range(5)]
    assert [set(_pats(s)) for s in out] == [{"P6"}] * 3 + [{"P4"}] * 2
    assert all(s.act == "demote" for s in out[3]) and all(s.act == "none" for s in out[0])
    assert eng.reread == {}                              # write는 Reread_Table을 건드리지 않음
    # 같은 LBA read는 write 칸/표와 무관 -> 첫 read는 P6
    assert _pats(eng.complete(_c(10, 0, 8, "R"))) == ["P6"]


def test_two_pass_loop_with_zero_gap_pass2_is_p3_with_promote_demote_boundary():
    eng = _leng(samon_loop_min_kb=256)                   # 512 sector 이상이 loop 후보
    t = 0
    for i in range(8):                                   # pass 1: [0, 1024)
        t += 1
        eng.complete(_c(t, 128 * i, 128))
    pass2 = []
    for i in range(8):                                   # pass 2: 간격 0 ms 이어붙임
        pass2.append(eng.complete(_c(t, 128 * i, 128)))
    assert all(set(_pats(s)) == {"P3"} for s in pass2)
    c = eng.counters["R"]
    assert c.restart == 1 and eng.n_loop_mark_b == 1 and eng.n_loop_mark_a == 0
    assert eng.clear_by_reason["R"]["live"] == 1
    # L = 1024, pct 50 -> d < 512 promote, d >= 512 demote (segment 시작 sector 기준)
    for seg in (s for ss in pass2 for s in ss):
        assert seg.act == ("promote" if seg.sector < 512 else "demote")
    assert [s.sector for s in pass2[3]][-1] == 504 and pass2[3][-1].act == "promote"
    assert pass2[4][0].sector == 512 and pass2[4][0].act == "demote"
    # P3 segment는 Reread_Table을 건드리지 않음
    assert sum(1 for e in eng.events if e.kind == "reread") == 3 * 16   # pass 1의 P6 request 3개뿐


def test_two_pass_with_small_first_read_has_no_p3():
    eng = Engine(Params(samon_loop_min_kb=256))
    for rep in range(2):
        for i in range(8):
            segs = eng.complete(_c(rep * 100 + i, 128 * i, 8))   # 4KB < new_kb
            assert "P3" not in _pats(segs)
    assert eng.counters["R"].new_slot == 0 and eng.det["P3"] == 0
    assert eng.det["P2"] == 8                            # pass 2는 재읽기(P2)


def test_loop_from_history_after_idle_clear_via_complete_advance():
    eng = _leng(samon_loop_min_kb=256, samon_stream_idle_ms=1000)
    eng.t0_ns = 0
    for i in range(8):
        eng.complete(_c(i + 1, 128 * i, 128))
    # 1.5 s 뒤 같은 시작 sector 큰 read: advance가 먼저 idle 정리(기록) -> (a)로 loop
    segs = eng.complete(_c(1500, 0, 128))
    assert eng.n_idle_clears == 1 and eng.n_loop_mark_a == 1
    assert set(_pats(segs)) == {"P3"}
    kinds = _kinds(eng)
    assert kinds.index("idle") < kinds.index("new_slot", kinds.index("idle"))


def test_excluded_record_still_advances_time():
    eng = _leng(samon_loop_min_kb=8, samon_stream_idle_ms=1000)
    eng.t0_ns = 0
    eng.complete(_c(1, 0, 128))
    assert eng.streams["R"][0].used
    assert eng.complete(_c(2000, 0, 8, "FWS")) == []     # 제외 레코드도 시각은 진행
    assert not eng.streams["R"][0].used and eng.n_idle_clears == 1


def test_replay_sorts_ignores_issue_sets_t0_and_is_deterministic():
    recs = [
        _c(30, 128, 128), _c(20, 0, 128),
        Record("I", 10 * MS, 0, 8, 0, 0, 128, "R"),     # issue: 규칙에 쓰지 않음, t0 후보
        _c(20, 5000, 8, "W"),
    ]
    a = replay(recs, Params(samon_loop_min_kb=8), log=True)
    b = replay(list(recs), Params(samon_loop_min_kb=8), log=True)
    assert a.engine.t0_ns == 10 * MS                     # 입력 전체의 가장 이른 시각
    assert a.n_complete == 3
    # 같은 ts(20 ms)는 입력 순서: R sector 0(16 segment) 다음 W 5000, 그 뒤 ts 30
    assert [(s.sector, s.dir) for s in (a.results[0], a.results[16], a.results[17])] == [
        (0, "R"), (5000, "W"), (128, "R")]
    assert len(a.results) == 16 + 1 + 16
    assert a.results == b.results and a.engine.events == b.engine.events
    assert a.engine.stream_counters() == b.engine.stream_counters()
    assert all(not x.used for d in DIRS_ for x in a.engine.streams[d])   # finish 호출됨
    assert replay(recs, t0_ns=0).engine.t0_ns == 0
    n = replay(recs, keep_results=False)
    assert n.results == [] and n.engine.det == a.engine.det
    e = replay([])
    assert e.results == [] and e.n_complete == 0

# ---------------------------------------------------------------------------
# 5.1 QueueModel 단위 테스트
# ---------------------------------------------------------------------------
import pytest  # noqa: E402
from samon_replay import Folio, QueueModel  # noqa: E402


def _qm(**kw):
    kw.setdefault("toggles", {1: True, 2: True, 3: True, 4: True, 5: True})
    return QueueModel(**kw)


def test_queue_toggle_off_counts_nothing_and_default_toggles():
    q = QueueModel(ncpu=1, q_len=4)
    assert q.toggle == {1: False, 2: False, 3: False, 4: False, 5: True}
    f = Folio()
    assert q.enqueue(0, 1, f) == "disabled"
    assert q.stats()["req_p1"] == 0 and f.refs == 0 and q.refs_got == 0
    assert q.enqueue(0, 5) == "queued"  # samon_opt_b 기본 1
    assert q.stats()["req_p5"] == 1 and q.q_cur == 1


def test_queue_full_drops_without_reference_and_stays_per_cpu():
    q = _qm(ncpu=2, q_len=2)
    f_drop = Folio()
    assert [q.enqueue(0, 1), q.enqueue(0, 1)] == ["queued", "queued"]
    assert q.enqueue(0, 1, f_drop) == "drop_queue"
    assert f_drop.refs == 0 and q.refs_got == 2
    assert q.enqueue(1, 1) == "queued"  # 다른 CPU 큐는 따로 센다
    s = q.stats()
    assert (s["req_p1"], s["drop_queue_p1"], s["q_cur"]) == (4, 1, 3)
    assert q.balance(1) == 0


def test_queue_process_order_toggle_stale_revalidate_exec():
    q = _qm(q_len=16, q_max_ms=100)
    f = {n: Folio() for n in "abcdefg"}
    f["c"].lru = False
    f["d"].dirty = True  # P4에서만 revalidate
    f["e"].dirty = True  # P1이면 dirty는 무관 -> exec
    f["f"].unevictable = True
    f["g"].mapping = False
    q.enqueue(0, 1, f["a"])  # a: stale
    q.enqueue(0, 2, f["b"])  # b: toggle
    q.advance_time(101)
    q.enqueue(0, 1, f["c"])  # c: !lru -> revalidate
    q.enqueue(0, 4, f["d"])  # d: dirty P4 -> revalidate
    q.enqueue(0, 1, f["e"])  # e: exec
    q.enqueue(0, 3, f["f"])  # f: unevictable -> revalidate
    q.enqueue(0, 5, f["g"])  # g: mapping NULL -> revalidate
    q.set_toggle(2, False)
    assert q.drain() == 7
    s = q.stats()
    assert s["drop_stale_p1"] == 1 and s["drop_toggle_p2"] == 1
    assert (s["drop_revalidate_p1"], s["drop_revalidate_p3"],
            s["drop_revalidate_p4"], s["drop_revalidate_p5"]) == (1, 1, 1, 1)
    assert s["exec_p1"] == 1 and q.prim_calls == [("demote", 1, f["e"])]
    assert all(x.refs == 0 for x in f.values())
    assert q.refs_got == q.refs_put == 7 and s["q_cur"] == 0
    assert all(q.balance(p) == 0 for p in range(1, 6))


def test_queue_stale_boundary_is_strictly_greater_and_tracks_max_delay():
    q = _qm(q_max_ms=100)
    q.enqueue(0, 1)
    q.advance_time(100)  # 경과 == 상한 -> stale 아님
    q.drain()
    assert q.stats()["exec_p1"] == 1 and q.stats()["q_max_delay_us"] == 100_000
    q.enqueue(0, 1)
    q.advance_time(101)
    q.drain()
    s = q.stats()
    assert s["drop_stale_p1"] == 1 and s["q_max_delay_us"] == 101_000


def test_queue_resolve_overrides_state_and_acts_follow_pattern():
    q = _qm()
    for p in (1, 2, 4, 5):
        q.enqueue(0, p)
    q.enqueue(0, 3, act="demote")
    q.drain(resolve=lambda it: Folio())
    assert [(a, p) for a, p, _ in q.prim_calls] == [
        ("demote", 1), ("promote", 2), ("demote", 4), ("mark", 5), ("demote", 3)]
    assert q.direct_ops == 0
    bad = _qm()
    bad.enqueue(0, 2)
    bad.drain(resolve=lambda it: Folio(lru=False))
    assert bad.stats()["drop_revalidate_p2"] == 1 and bad.prim_calls == []


def test_queue_shutdown_drops_remaining_releases_refs_and_accumulates():
    q = _qm(ncpu=2, q_len=4)
    fs = [Folio() for _ in range(3)]
    q.enqueue(0, 1, fs[0])
    q.enqueue(1, 5, fs[1])
    q.enqueue(1, 5, fs[2])
    q.drain()
    q.enqueue(0, 1, fs[0])
    q.enqueue(1, 3, fs[1])
    q.shutdown()
    s = q.stats()
    assert (s["drop_shutdown_p1"], s["drop_shutdown_p3"]) == (1, 1)
    assert s["q_cur"] == 0 and q.totals().inflight == 0
    assert all(q.balance(p) == 0 for p in range(1, 6))
    assert q.refs_got == q.refs_put == 5 and all(x.refs == 0 for x in fs)
    # 정지 뒤에는 probe가 없다: enqueue는 세지 않는다. 누적값은 다음 실행에도 유지된다.
    assert q.enqueue(0, 1) == "inactive" and q.stats()["req_p1"] == s["req_p1"]
    q.shutdown()  # 두 번 불러도 안전
    assert q.stats() == s
    q.start(q_len=2)
    assert q.stats()["q_max_delay_us"] == 0 and q.stats()["req_p1"] == s["req_p1"]
    assert q.enqueue(0, 1) == "queued" and q.balance(1) == 0


def test_queue_toggle_change_after_enqueue_drops_with_toggle_reason():
    q = _qm()
    q.enqueue(0, 4)
    q.set_toggle(4, False)
    q.drain()
    s = q.stats()
    assert s["drop_toggle_p4"] == 1 and s["exec_p4"] == 0 and q.balance(4) == 0
    assert q.enqueue(0, 4) == "disabled" and q.stats()["req_p4"] == 1


def test_queue_rejects_bad_arguments():
    with pytest.raises(ValueError):
        QueueModel(ncpu=0)
    with pytest.raises(ValueError):
        QueueModel(q_len=0)
    q = _qm()
    with pytest.raises(ValueError):
        q.enqueue(0, 6)
    with pytest.raises(ValueError):
        q.set_toggle(6, True)
    with pytest.raises(ValueError):
        q.enqueue(0, 1, act="evict")
    with pytest.raises(ValueError):
        q.advance_time(-1)
