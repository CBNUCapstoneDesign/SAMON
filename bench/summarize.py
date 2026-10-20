#!/usr/bin/env python3
"""summarize.py — samon_bench.sh의 runs.csv를 요약한다 (design T7, R12.2~R12.6, R11.3).

사용: python3 bench/summarize.py runs.csv [--k 2] > summary.md

집계 단위는 (workload, config)이고 유효 행만 n·평균·표준편차(n-1)에 쓴다(R12.5).
지표마다 표 하나를 만들고, 구성 행마다 off 대비·damon 대비(절댓값 차, %, 판정)를 낸다.
*_classic 구성의 기준은 off_classic, damon_classic이다. 자기 자신이 기준인 칸은 "—"이다.
mixed에서는 noise = |mean(off2) − mean(off)|를 지표마다 보고하고 모든 비교에 요구한다.
보조 잡 대역폭(aux_bw_mib)은 hot 잡 지표와 합치지 않고 자기 표(별도 열)에서 같은 판정을 받는다.

이 판정은 유의성 검정이 아니라 선별 규칙이다.

판정 함수(judge)·유효 행 판정(valid)은 순수 함수이다(property test 대상).
"""
from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
from typing import Mapping, Sequence

NA = "NA"
DASH = "—"
MIN_N = 3          # R12.5: 유효 반복이 이보다 적으면 판정하지 않음
DEFAULT_K = 2.0    # 부록 A 확정값(제안 2)

DIRECTION: dict[str, int] = {  # +1: 증가가 개선, -1: 감소가 개선, 0: 방향 미정 (R12.3)
    "hot_r_iops": +1, "hot_w_iops": +1, "aux_bw_mib": +1, "loop_bw_mib": +1,
    "cachestat_hit_pct": +1,
    "hot_r_p50_us": -1, "hot_r_p99_us": -1, "hot_w_p50_us": -1, "hot_w_p99_us": -1,
    "cg_workingset_refault_file": -1, "pgpgin_kib": -1, "cg_pgscan": -1, "cg_pgsteal": -1,
    "cpu_sys_irq_softirq_s": -1, "cpu_sys_s": -1, "cpu_irq_s": -1, "cpu_softirq_s": -1,
    "kd_cpu_s": -1, "slab_kb": -1, "sunreclaim_kb": -1,
    "cg_workingset_activate_file": 0, "loop_passes": 0,
}

# 표에 나오는 구성 순서(그 밖의 구성은 뒤에 이름순)
CONFIG_ORDER = (
    "off", "off2", "damon", "samon_observe", "samon_all",
    "samon_p1", "samon_p2", "samon_p3", "samon_p4",
    "off_classic", "damon_classic", "samon_all_classic",
    "samon_p1_classic", "samon_p4_classic",
)

# 제외 사유 (R12.5). 한 행이 여러 사유에 해당하면 사유마다 센다.
REASONS = ("fio_rc", "damon_inactive", "q_warn", "loop_invalid")


# ---------------------------------------------------------------------------
# 순수 함수
# ---------------------------------------------------------------------------

def exclusion_reasons(row: Mapping[str, str]) -> list[str]:
    """행이 유효 반복에서 빠지는 사유 목록(비어 있으면 유효). 칸이 없거나 NA인 fio_rc는
    종료 코드 0을 확인할 수 없으므로 사유이다. 오염 표시 칸이 없으면 표시 없음으로 본다."""
    out = []
    if (row.get("fio_rc") or "").strip() != "0":
        out.append("fio_rc")
    for c in ("damon_inactive", "q_warn", "loop_invalid"):
        if (row.get(c) or "").strip() == "1":
            out.append(c)
    return out


def valid(row: Mapping[str, str]) -> bool:
    """R12.5: 오염 표시(damon_inactive, q_warn, loop_invalid)가 없고 fio 종료 코드가 0."""
    return not exclusion_reasons(row)


def mean(xs: Sequence[float]) -> float:
    return statistics.mean(xs)


def stdev(xs: Sequence[float]) -> float:
    return statistics.stdev(xs)


def judge(xs, bs, k, direction, noise=None, names=("X", "B"), extra_n=()):
    """xs, bs: 유효 반복 값 목록(NA는 None). extra_n: mixed의 (("off2", n_off2),).
    순서: n < 3 검사 → NA 검사 → 식 (둘 다 해당하면 "판정하지 않음")."""
    short = [(nm, len(v)) for nm, v in zip(names, (xs, bs)) if len(v) < MIN_N] + \
            [(nm, n) for nm, n in extra_n if n < MIN_N]
    if short:
        return "판정하지 않음(" + ", ".join(f"{nm} n={n}" for nm, n in short) + ")"
    if any(v is None for v in list(xs) + list(bs)) or \
            (noise is not None and math.isnan(noise)):
        return NA
    d = mean(xs) - mean(bs)
    diff = abs(d) > k * max(stdev(xs), stdev(bs)) and (noise is None or abs(d) > noise)
    if not diff:
        return "차이 없음"
    if direction == 0:
        return "차이 있음(방향 미정)"
    return "차이 있음(개선)" if (d > 0) == (direction > 0) else "차이 있음(악화)"


def baselines_for(config: str) -> tuple[str, str]:
    """(off 기준, damon 기준). *_classic 구성은 같은 lru_gen 설정의 classic 기준."""
    if config.endswith("_classic"):
        return "off_classic", "damon_classic"
    return "off", "damon"


def to_float(s: str | None) -> float | None:
    """CSV 칸 → 실수. NA·빈 칸·숫자 아님·nan·inf는 None."""
    if s is None:
        return None
    s = s.strip()
    if not s or s == NA:
        return None
    try:
        v = float(s)
    except ValueError:
        return None
    return None if math.isnan(v) or math.isinf(v) else v


def mean_or_none(xs: Sequence[float | None]) -> float | None:
    if not xs or any(v is None for v in xs):
        return None
    return mean(xs)  # type: ignore[arg-type]


def sd_or_none(xs: Sequence[float | None]) -> float | None:
    if len(xs) < 2 or any(v is None for v in xs):
        return None
    return stdev(xs)  # type: ignore[arg-type]


def noise_of(off2: Sequence[float | None], off: Sequence[float | None]) -> float:
    """|mean(off2) − mean(off)|. 어느 쪽이든 값이 없거나 NA가 있으면 nan."""
    a, b = mean_or_none(off2), mean_or_none(off)
    return math.nan if a is None or b is None else abs(a - b)


def diff_cells(xs: Sequence[float | None], bs: Sequence[float | None]
               ) -> tuple[str, str]:
    """(절댓값 차 mean(X) − mean(B), % 차). 부호 포함. 계산할 수 없는 칸은 NA.
    mean(B) = 0이면 % 칸만 NA(R12.6)."""
    mx, mb = mean_or_none(xs), mean_or_none(bs)
    if mx is None or mb is None:
        return NA, NA
    d = mx - mb
    pct = NA if mb == 0 else f"{100.0 * d / mb:+.2f}%"
    return f"{d:+.6g}", pct


def fmt_num(v: float | None) -> str:
    return NA if v is None else f"{v:.6g}"


# ---------------------------------------------------------------------------
# 집계와 출력
# ---------------------------------------------------------------------------

def config_sort_key(c: str) -> tuple[int, str]:
    return (CONFIG_ORDER.index(c), c) if c in CONFIG_ORDER else (len(CONFIG_ORDER), c)


def load_rows(path: str) -> list[dict[str, str]]:
    with open(path, encoding="utf-8", newline="") as f:
        rd = csv.DictReader(f)
        missing = [c for c in ("workload", "config", "fio_rc")
                   if c not in (rd.fieldnames or [])]
        if missing:
            raise ValueError(f"{path}: missing column(s): {', '.join(missing)}")
        return list(rd)


def summarize(rows: Sequence[Mapping[str, str]], k: float) -> str:
    """runs.csv 행 → summary.md 문자열."""
    out: list[str] = []
    excluded: dict[tuple[str, str], dict[str, int]] = {}
    excluded_rows: dict[tuple[str, str], int] = {}
    total: dict[str, int] = {r: 0 for r in REASONS}
    # (workload, config) → 유효 행 목록
    groups: dict[tuple[str, str], list[Mapping[str, str]]] = {}
    for r in rows:
        key = (r.get("workload") or NA, r.get("config") or NA)
        reasons = exclusion_reasons(r)
        if reasons:
            excluded_rows[key] = excluded_rows.get(key, 0) + 1
            per = excluded.setdefault(key, {})
            for why in reasons:
                per[why] = per.get(why, 0) + 1
                total[why] += 1
        else:
            groups.setdefault(key, []).append(r)
        groups.setdefault(key, groups.get(key, []))

    workloads = sorted({w for w, _ in groups})
    out.append(f"runs: {len(rows)} (valid {sum(len(v) for v in groups.values())}, "
               f"excluded {sum(excluded_rows.values())}); k={k:g}")
    out.append("")

    for wl in workloads:
        configs = sorted({c for w, c in groups if w == wl}, key=config_sort_key)
        out.append(f"## {wl}")
        out.append("")
        out.append("유효 반복 수 n: " + ", ".join(
            f"{c}={len(groups[(wl, c)])}" for c in configs))
        out.append("")
        is_mixed = wl == "mixed"
        for metric, direction in DIRECTION.items():
            vals = {c: [to_float(r.get(metric)) for r in groups[(wl, c)]] for c in configs}
            if all(v is None for xs in vals.values() for v in xs):
                continue  # 이 워크로드에서 의미 없는 지표(전부 NA)
            noise: float | None = None
            extra: tuple = ()
            title = f"### {wl} / {metric}"
            if metric == "aux_bw_mib":
                title += " (보조 잡 대역폭, hot 잡과 합산하지 않음)"
            out.append(title)
            if is_mixed:
                off2 = vals.get("off2", [])
                noise = noise_of(off2, vals.get("off", []))
                extra = (("off2", len(off2)),)
                out.append("")
                out.append(f"noise = |mean(off2) − mean(off)| = {fmt_num(noise if not math.isnan(noise) else None)}"
                           f" (off2 n={len(off2)})")
            out.append("")
            out.append("| config | n | mean | sd "
                       "| off 대비 Δ | off 대비 % | off 대비 판정 "
                       "| damon 대비 Δ | damon 대비 % | damon 대비 판정 |")
            out.append("|---|---|---|---|---|---|---|---|---|---|")
            for c in configs:
                xs = vals[c]
                cells = [c, str(len(xs)), fmt_num(mean_or_none(xs)),
                         fmt_num(sd_or_none(xs))]
                for base in baselines_for(c):
                    if c == base:
                        cells += [DASH, DASH, DASH]
                        continue
                    bs = vals.get(base, [])
                    d, p = diff_cells(xs, bs)
                    verdict = judge(xs, bs, k, direction, noise=noise, names=(c, base),
                                    extra_n=extra)
                    cells += [d, p, verdict]
                out.append("| " + " | ".join(cells) + " |")
            out.append("")

    out.append("---")
    out.append("")
    out.append("이 판정은 유의성 검정이 아니라 선별 규칙이다.")
    out.append("")
    out.append(f"- k = {k:g}: |mean(X) − mean(B)| > k × max(sd(X), sd(B)) 이면 \"차이 있음\" "
               "(sd 바닥값 없음). mixed는 추가로 |mean(X) − mean(B)| > noise를 요구한다.")
    out.append(f"- 유효 반복 {MIN_N}회 미만인 비교는 \"판정하지 않음\", NA가 있으면 \"NA\".")
    out.append("- 제외한 실행 수(사유별, 한 행이 여러 사유에 해당하면 사유마다 센다): "
               + ", ".join(f"{r}={total[r]}" for r in REASONS)
               + f"; 제외된 행 합계 {sum(excluded_rows.values())}")
    for key in sorted(excluded, key=lambda t: (t[0], config_sort_key(t[1]))):
        per = excluded[key]
        out.append(f"  - {key[0]} / {key[1]}: 제외 {excluded_rows[key]}행 ("
                   + ", ".join(f"{r}={per[r]}" for r in REASONS if r in per) + ")")
    out.append("")
    return "\n".join(out)


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Summarize samon_bench.sh runs.csv")
    ap.add_argument("runs_csv")
    ap.add_argument("--k", type=float, default=DEFAULT_K,
                    help="판정 배수 k (> 0, 기본 2)")
    args = ap.parse_args(argv)
    if not (args.k > 0) or math.isinf(args.k):
        print("summarize.py: --k must be a positive finite number", file=sys.stderr)
        return 2
    try:
        rows = load_rows(args.runs_csv)
    except (OSError, ValueError, csv.Error) as e:
        print(f"summarize.py: {e}", file=sys.stderr)
        return 2
    sys.stdout.write(summarize(rows, args.k))
    return 0


if __name__ == "__main__":
    sys.exit(main())
