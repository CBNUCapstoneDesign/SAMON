"""Tests for bench/summarize.py (judge, valid, diff_cells, summarize)."""
import os
import sys

from hypothesis import assume, given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import summarize as sm  # noqa: E402

_num = st.floats(min_value=-1e6, max_value=1e6, allow_nan=False, allow_infinity=False)
_k = st.floats(min_value=0.01, max_value=10, allow_nan=False, allow_infinity=False)
_direction = st.sampled_from([-1, 0, 1])


def _is_number(s: str) -> bool:
    try:
        float(s)
        return True
    except ValueError:
        return False


# Feature: samon-path-b-completion, Property 19: 판정할 수 없는 칸
# Validates: Requirements 12.5, 12.6
@settings(max_examples=200, deadline=None)
@given(
    xs=st.lists(_num, max_size=6),
    bs=st.lists(_num, max_size=6),
    k=_k,
    direction=_direction,
)
def test_property19_fewer_than_three_is_not_judged(xs, bs, k, direction):
    """n < 3인 쪽이 있으면 "판정하지 않음(…)"이고 그 쪽 이름과 n을 담는다."""
    v = sm.judge(xs, bs, k, direction, names=("X", "B"))
    short = [(nm, len(s)) for nm, s in (("X", xs), ("B", bs)) if len(s) < 3]
    if short:
        assert v.startswith("판정하지 않음(")
        for nm, n in short:
            assert f"{nm} n={n}" in v
        for nm, s in (("X", xs), ("B", bs)):
            if len(s) >= 3:
                assert f"{nm} n=" not in v
    else:
        assert not v.startswith("판정하지 않음")


# Feature: samon-path-b-completion, Property 19: 판정할 수 없는 칸
# Validates: Requirements 12.5, 12.6
@settings(max_examples=200, deadline=None)
@given(
    xs=st.lists(_num, max_size=6),
    bs=st.lists(_num, max_size=6),
    n_off2=st.integers(min_value=0, max_value=6),
    noise=_num,
    k=_k,
    direction=_direction,
)
def test_property19_mixed_off2_counts(xs, bs, n_off2, noise, k, direction):
    """mixed에서는 off2가 3회 미만이어도 판정하지 않고 off2 이름과 n을 담는다."""
    v = sm.judge(xs, bs, k, direction, noise=abs(noise), names=("X", "B"),
                 extra_n=(("off2", n_off2),))
    if n_off2 < 3:
        assert v.startswith("판정하지 않음(")
        assert f"off2 n={n_off2}" in v
    if len(xs) < 3:
        assert f"X n={len(xs)}" in v
    if len(bs) < 3:
        assert f"B n={len(bs)}" in v


# Feature: samon-path-b-completion, Property 19: 판정할 수 없는 칸
# Validates: Requirements 12.5, 12.6
@settings(max_examples=200, deadline=None)
@given(
    xs=st.lists(st.one_of(_num, st.none()), min_size=3, max_size=6),
    bs=st.lists(st.one_of(_num, st.none()), min_size=3, max_size=6),
    k=_k,
    direction=_direction,
)
def test_property19_na_value_gives_na(xs, bs, k, direction):
    """두 쪽 모두 3 이상이고 NA가 있으면 "NA"이다."""
    v = sm.judge(xs, bs, k, direction)
    if any(x is None for x in xs + bs):
        assert v == "NA"
    else:
        assert v != "NA" and not v.startswith("판정하지 않음")


# Feature: samon-path-b-completion, Property 19: 판정할 수 없는 칸
# Validates: Requirements 12.5, 12.6
@settings(max_examples=200, deadline=None)
@given(
    xs=st.lists(_num, min_size=1, max_size=6),
    half=st.lists(_num, min_size=1, max_size=4),
)
def test_property19_zero_baseline_percent_is_na(xs, half):
    """mean(bs) = 0이면 % 칸은 "NA", 절댓값 차 칸은 숫자이다."""
    bs = half + [-h for h in half]  # 평균이 정확히 0
    d, pct = sm.diff_cells(xs, bs)
    assert pct == "NA"
    assert _is_number(d)


# Feature: samon-path-b-completion, Property 19: 판정할 수 없는 칸
# Validates: Requirements 12.5, 12.6
@settings(max_examples=200, deadline=None)
@given(
    xs=st.lists(_num, min_size=1, max_size=6),
    bs=st.lists(_num, min_size=1, max_size=6).filter(lambda b: sum(b) != 0),
)
def test_property19_nonzero_baseline_percent_is_number(xs, bs):
    d, pct = sm.diff_cells(xs, bs)
    assert _is_number(d)
    assert pct.endswith("%") and _is_number(pct[:-1])


def test_property19_summarize_shows_undecidable_and_zero_baseline():
    """summarize 통합: off n=2 → 판정하지 않음, off 평균 0 → % NA, 값 NA → NA."""
    def row(cfg, v, rc="0"):
        return {"workload": "w", "config": cfg, "fio_rc": rc, "hot_r_iops": v}

    rows = [row("off", "0"), row("off", "0"), row("off", "0"),
            row("damon", "5"), row("damon", "6"), row("damon", "7"),
            row("samon_all", "1"), row("samon_all", "2")]
    out = sm.summarize(rows, 2.0)
    line = next(l for l in out.splitlines() if l.startswith("| damon |"))
    assert "NA" in line  # off 평균 0 → % 칸 NA
    line = next(l for l in out.splitlines() if l.startswith("| samon_all |"))
    assert "판정하지 않음(samon_all n=2)" in line
    # 무효 행(fio_rc != 0)은 n에서 빠진다
    rows2 = rows + [row("samon_all", "3", rc="1")]
    assert "samon_all n=2" in sm.summarize(rows2, 2.0)


# ---------------------------------------------------------------------------
# Property 20: 판정의 대칭성과 척도 불변성
# ---------------------------------------------------------------------------
_vals3 = st.lists(_num, min_size=3, max_size=6)
_noise = st.one_of(st.none(), st.floats(min_value=0, max_value=1e6, allow_nan=False))
# 2의 거듭제곱 배율: 부동소수 곱셈이 정확하여 경계값에서도 척도 불변성을 검증할 수 있다.
_scale = st.integers(min_value=-8, max_value=8).map(lambda e: 2.0 ** e)


def _differs(v: str) -> bool:
    return v.startswith("차이 있음")


# Feature: samon-path-b-completion, Property 20: 판정의 대칭성과 척도 불변성
# Validates: Requirements 12.3
@settings(max_examples=200, deadline=None)
@given(xs=_vals3, bs=_vals3, k=_k, direction=st.sampled_from([-1, 1]), noise=_noise)
def test_property20_symmetry(xs, bs, k, direction, noise):
    """judge(xs,bs)와 judge(bs,xs)는 차이 여부가 같고, 차이가 있으면 개선·악화가 반대이다."""
    a = sm.judge(xs, bs, k, direction, noise=noise)
    b = sm.judge(bs, xs, k, direction, noise=noise)
    assert _differs(a) == _differs(b)
    if _differs(a):
        assert {a, b} == {"차이 있음(개선)", "차이 있음(악화)"}
    else:
        assert a == b == "차이 없음"


# Feature: samon-path-b-completion, Property 20: 판정의 대칭성과 척도 불변성
# Validates: Requirements 12.3
@settings(max_examples=200, deadline=None)
@given(xs=_vals3, bs=_vals3, k=_k, direction=_direction, noise=_noise, c=_scale)
def test_property20_scale_invariance(xs, bs, k, direction, noise, c):
    """모든 값과 noise에 같은 양수 c를 곱해도 판정이 같다."""
    base = sm.judge(xs, bs, k, direction, noise=noise)
    scaled = sm.judge([x * c for x in xs], [b * c for b in bs], k, direction,
                      noise=None if noise is None else noise * c)
    assert base == scaled


# Feature: samon-path-b-completion, Property 20: 판정의 대칭성과 척도 불변성
# Validates: Requirements 12.3
@settings(max_examples=200, deadline=None)
@given(x=_num, b=_num, nx=st.integers(3, 6), nb=st.integers(3, 6), k=_k,
       direction=_direction)
def test_property20_zero_sd_differs_iff_means_differ(x, b, nx, nb, k, direction):
    """sd(xs)=sd(bs)=0이면 '차이 있음' ⇔ mean(xs) ≠ mean(bs)."""
    v = sm.judge([x] * nx, [b] * nb, k, direction)
    assert _differs(v) == (x != b)


# ---------------------------------------------------------------------------
# Property 21: 잡음 기준의 단조성
# ---------------------------------------------------------------------------
# Feature: samon-path-b-completion, Property 21: 잡음 기준의 단조성
# Validates: Requirements 12.4
@settings(max_examples=200, deadline=None)
@given(xs=_vals3, bs=_vals3, k=_k, direction=_direction,
       n1=st.floats(min_value=0, max_value=1e6, allow_nan=False),
       n2=st.floats(min_value=0, max_value=1e6, allow_nan=False))
def test_property21_noise_monotonic(xs, bs, k, direction, n1, n2):
    """Feature: samon-path-b-completion, Property 21: 잡음 기준의 단조성
    **Validates: Requirements 12.4**"""
    lo, hi = min(n1, n2), max(n1, n2)
    if _differs(sm.judge(xs, bs, k, direction, noise=hi)):
        assert _differs(sm.judge(xs, bs, k, direction, noise=lo))
    # noise = 0 equals criterion-3-only verdict (noise=None)
    assert _differs(sm.judge(xs, bs, k, direction, noise=0.0)) == \
        _differs(sm.judge(xs, bs, k, direction))


@settings(max_examples=200, deadline=None)
@given(xs=_vals3, bs=_vals3, k=_k, noise=_noise)
def test_property20_direction_zero_has_no_improve_or_worsen(xs, bs, k, noise):
    """방향 0 지표는 '차이 없음' 또는 '차이 있음(방향 미정)'만 낸다."""
    v = sm.judge(xs, bs, k, 0, noise=noise)
    assert v in ("차이 없음", "차이 있음(방향 미정)")


# ---------------------------------------------------------------------------
# Property 22: 오염 행 제외
# ---------------------------------------------------------------------------
_P22_CONFIGS = ("off", "damon", "samon_all")
_val_str = st.integers(min_value=0, max_value=10**6).map(str)


def _p22_row(cfg, v, rc="0", di="0", qw="0", li="0"):
    return {"workload": "w", "config": cfg, "fio_rc": rc, "damon_inactive": di,
            "q_warn": qw, "loop_invalid": li, "hot_r_iops": v}


@st.composite
def _contaminated_row(draw):
    cfg = draw(st.sampled_from(_P22_CONFIGS))
    rc = draw(st.sampled_from(["0", "1", "137"]))
    di, qw, li = (draw(st.sampled_from(["0", "1"])) for _ in range(3))
    assume(rc != "0" or "1" in (di, qw, li))  # 최소 한 가지 오염 사유
    return _p22_row(cfg, draw(_val_str), rc, di, qw, li)


def _p22_table_part(text):
    """첫 줄(runs: 요약)과 맨 아래 '제외한 실행 수' 줄을 뺀 표 부분."""
    lines = text.splitlines()
    return lines[1:lines.index("---")]


# Feature: samon-path-b-completion, Property 22: 오염 행 제외
# Validates: Requirements 10.5, 12.5
@settings(max_examples=200, deadline=None)
@given(valid_vals=st.lists(st.tuples(st.sampled_from(_P22_CONFIGS), _val_str),
                           min_size=1, max_size=12),
       bad=st.lists(_contaminated_row(), min_size=1, max_size=8),
       positions=st.lists(st.integers(min_value=0, max_value=12), min_size=8, max_size=8),
       k=_k)
def test_property22_contaminated_rows_do_not_change_stats(valid_vals, bad, positions, k):
    """오염 행(fio_rc≠0 또는 damon_inactive/q_warn/loop_invalid=1)을 더해도 n, mean, sd,
    판정 칸은 같고 제외 실행 수 줄만 바뀐다."""
    valid_rows = [_p22_row(c, v) for c, v in valid_vals]
    # 오염 행만 있는 (workload, config)가 새로 생기지 않도록 유효 행이 있는 구성에만 더한다.
    present = {r["config"] for r in valid_rows}
    bad = [b for b in bad if b["config"] in present]
    mixed = list(valid_rows)
    for b, pos in zip(bad, positions):
        mixed.insert(min(pos, len(mixed)), b)

    base = sm.summarize(valid_rows, k)
    with_bad = sm.summarize(mixed, k)
    assert _p22_table_part(base) == _p22_table_part(with_bad)
    # 제외 실행 수 줄만 바뀐다
    if bad:
        assert base != with_bad
        assert f"제외된 행 합계 {len(bad)}" in with_bad
    assert "제외된 행 합계 0" in base
