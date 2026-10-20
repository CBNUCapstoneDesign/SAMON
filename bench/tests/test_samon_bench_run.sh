#!/bin/bash
# samon_bench.sh 구성 표, order.txt, run_one 시험 (tasks 24.4). 가짜 sysfs·cgroup 트리만 쓴다.
# root도 sudo도 fio도 필요 없다.
#   usage: bash bench/tests/test_samon_bench_run.sh
# 각 시나리오는 samon_bench.sh를 source한 driver를 별도 프로세스로 돌려, 실패 경로에서도
# 실제 EXIT trap(restore)을 거치게 한다. driver의 rwrite는 "가짜 커널"이다: LRU_SORT enabled를
# 쓰면 kdamond_pid를 갱신하고, 지정한 파일 쓰기를 버리거나 실패시킬 수 있다(FAULT_*).
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BDIR=$(cd "$HERE/.." && pwd)
BENCH=$BDIR/samon_bench.sh
WLSH=$BDIR/samon_workloads.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || echo "     $2"; }
check() { # name, condition result (0 = pass), detail
	if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# ---------------------------------------------------------------------------
# 1. 구성 표와 워크로드별 구성 목록 (in-process)
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$BENCH"
WITH_PN=0

list() { configs_for_workload "$1" "$2"; }

check "mixed list" "$([ "$(list mixed 0)" = "off off2 damon samon_observe samon_all off_classic damon_classic samon_all_classic" ]; echo $?)" "$(list mixed 0)"
check "reread list" "$([ "$(list reread 0)" = "off damon samon_observe samon_all" ]; echo $?)" "$(list reread 0)"
check "loop list" "$([ "$(list loop 0)" = "off damon samon_observe samon_all" ]; echo $?)" "$(list loop 0)"
check "seqwrite list" "$([ "$(list seqwrite 0)" = "off damon samon_observe samon_all off_classic damon_classic samon_all_classic" ]; echo $?)" "$(list seqwrite 0)"
check "off2 only in mixed" "$([ "$(for w in mixed reread loop seqwrite; do list $w 1; done | tr ' ' '\n' | grep -c '^off2$')" = 1 ]; echo $?)"
check "classic only in mixed and seqwrite" "$([ "$(list reread 1 | grep -c classic)" = 0 ] && [ "$(list loop 1 | grep -c classic)" = 0 ]; echo $?)"

# 1차 실행 수 합계 115 = 5 x (8 + 4 + 4 + 7), 2차 215 = 5 x (14 + 8 + 8 + 13)
n1=0; n2=0
for w in mixed reread loop seqwrite; do
	n1=$((n1 + $(list $w 0 | wc -w))); n2=$((n2 + $(list $w 1 | wc -w)))
done
check "run counts x5: 115 without --with-pn, 215 with" "$([ $((n1 * 5)) = 115 ] && [ $((n2 * 5)) = 215 ]; echo $?)" "n1=$n1 n2=$n2"
check "mixed --with-pn adds p1..p4 and p1/p4 classic" "$([ "$(list mixed 1)" = "off off2 damon samon_observe samon_all samon_p1 samon_p2 samon_p3 samon_p4 off_classic damon_classic samon_all_classic samon_p1_classic samon_p4_classic" ]; echo $?)" "$(list mixed 1)"
check "reread --with-pn adds p1..p4 only" "$([ "$(list reread 1)" = "off damon samon_observe samon_all samon_p1 samon_p2 samon_p3 samon_p4" ]; echo $?)"
check "seqwrite --with-pn adds classic p1/p4" "$([ "$(list seqwrite 1 | tr ' ' '\n' | grep -c '^samon_p[14]_classic$')" = 2 ]; echo $?)"

allin=0
for w in mixed reread loop seqwrite; do
	for c in $(list $w 1); do [ "${CFG[$c]+set}" = set ] || { allin=1; echo "missing $c"; }; done
done
check "every listed config is in CFG" "$allin"

# 표 값(요구사항 10 기준 1): kd lrusort lrugen act
exp_ok=0
expect_cfg() { [ "${CFG[$1]}" = "$2" ] || { exp_ok=1; echo "CFG[$1]='${CFG[$1]}' want '$2'"; }; }
expect_cfg off "off N start 00000";            expect_cfg off2 "off N start 00000"
expect_cfg damon "off Y start 00000";          expect_cfg samon_observe "on N start 00000"
expect_cfg samon_all "on N start 11110";       expect_cfg samon_p1 "on N start 10000"
expect_cfg samon_p2 "on N start 01000";        expect_cfg samon_p3 "on N start 00100"
expect_cfg samon_p4 "on N start 00010";        expect_cfg off_classic "off N 0 00000"
expect_cfg damon_classic "off Y 0 00000";      expect_cfg samon_all_classic "on N 0 11110"
expect_cfg samon_p1_classic "on N 0 10000";    expect_cfg samon_p4_classic "on N 0 00010"
check "CFG table values" "$exp_ok"
check "CFG has exactly 14 entries" "$([ "${#CFG[@]}" = 14 ]; echo $?)" "${#CFG[@]}"

# ---------------------------------------------------------------------------
# 2. order.txt와 실행 순서 (run_one은 기록만 하는 가짜)
# ---------------------------------------------------------------------------
cat > "$TMP/order_driver.sh" <<'EOF'
. "$BENCH"; . "$WLSH"
WL=$WLN; WITH_PN=${PN:-0}; REPS=${REPSN:-3}; SEED=${SEEDV:-42}; OUT=$T/out; mkdir -p "$OUT"
# 가짜 run_one: 호출을 기록하고 24.5의 hook_run_finish처럼 행 하나를 runs.csv에 덧붙인다
run_one() {
	echo "$1 $2 $3" >> "$T/calls"
	[ "$1" = "${FAILAT:-0}" ] && return 1
	[ -s "$OUT/runs.csv" ] || echo header > "$OUT/runs.csv"
	echo "row $1" >> "$OUT/runs.csv"; CSV_ROWS=$((CSV_ROWS + 1))
	return 0
}
run_all; echo $? > "$T/rc"
EOF
run_order() { # tree workload [seed] [reps] [pn] [failat]
	rm -rf "$1"; mkdir -p "$1"
	T=$1 BENCH=$BENCH WLSH=$WLSH WLN=$2 SEEDV=${3:-42} REPSN=${4:-3} PN=${5:-0} FAILAT=${6:-0} \
		bash "$TMP/order_driver.sh" 2> "$1/err"
}

t=$TMP/o1; run_order "$t" mixed 42 3
want=$(python3 "$BDIR/samon_benchlib.py" order --seed 42 --reps 3 --configs "$(list mixed 0 | tr ' ' ,)")
check "order.txt equals samon_benchlib.py order output" "$([ "$(cat "$t/out/order.txt")" = "$want" ]; echo $?)"
check "order.txt has reps x configs lines (24)" "$([ "$(wc -l < "$t/out/order.txt")" = 24 ]; echo $?)"
perm_ok=0
for r in 1 2 3; do
	[ "$(awk -v r=$r '$1==r{print $2}' "$t/out/order.txt" | sort | tr '\n' ' ')" = "$(list mixed 0 | tr ' ' '\n' | sort | tr '\n' ' ')" ] || perm_ok=1
done
check "each rep runs every config exactly once" "$perm_ok"
check "run_one called in order.txt order with run numbers 1..24" "$([ "$(awk '{print $2, $3}' "$t/calls")" = "$(cat "$t/out/order.txt")" ] && [ "$(awk '{print $1}' "$t/calls" | tr '\n' ' ')" = "$(seq 1 24 | tr '\n' ' ')" ]; echo $?)"
check "run_all returns 0 after the loop when every run recorded a row" "$([ "$(cat "$t/rc")" = 0 ]; echo $?)" "rc=$(cat "$t/rc")"
check "run_all: runs.csv has header + 24 rows" "$([ "$(wc -l < "$t/out/runs.csv")" = 25 ]; echo $?)"

t=$TMP/o2; run_order "$t" mixed 42 3
check "same seed gives the same order.txt" "$(cmp -s "$TMP/o1/out/order.txt" "$t/out/order.txt"; echo $?)"
t=$TMP/o3; run_order "$t" mixed 43 3
check "different seed gives a different order.txt" "$(! cmp -s "$TMP/o1/out/order.txt" "$t/out/order.txt"; echo $?)"

t=$TMP/o4; run_order "$t" reread 7 2 1
check "reread --with-pn: 8 configs x 2 reps = 16 runs" "$([ "$(wc -l < "$t/out/order.txt")" = 16 ]; echo $?)"
t=$TMP/o5; run_order "$t" loop 7 2 0
check "loop: 4 configs x 2 reps = 8 runs" "$([ "$(wc -l < "$t/out/order.txt")" = 8 ]; echo $?)"

t=$TMP/o6; run_order "$t" seqwrite 5 2 0 3
check "run_one failure stops the loop (rc 1, 3 calls)" "$([ "$(cat "$t/rc")" = 1 ] && [ "$(wc -l < "$t/calls")" = 3 ]; echo $?)" "rc=$(cat "$t/rc") calls=$(wc -l < "$t/calls")"

# ---------------------------------------------------------------------------
# 3. run_one: 가짜 트리
# ---------------------------------------------------------------------------
mk_tree() { # dir
	local t=$1 f a
	mkdir -p "$t/kd/0/contexts/0/targets" "$t/kd/0/contexts/0/monitoring_attrs/intervals" \
		"$t/kd/0/contexts/0/monitoring_attrs/nr_regions" "$t/parm" "$t/lrup" "$t/cg" "$t/dbg" "$t/out" "$t/w"
	echo 1 > "$t/kd/nr_kdamonds"
	echo off > "$t/kd/0/state"
	echo 1 > "$t/kd/0/contexts/nr_contexts"
	echo paddr > "$t/kd/0/contexts/0/operations"
	echo 0 > "$t/kd/0/contexts/0/targets/nr_targets"
	a=$t/kd/0/contexts/0/monitoring_attrs
	echo 1 > "$a/intervals/sample_us"; echo 2 > "$a/intervals/aggr_us"; echo 3 > "$a/intervals/update_us"
	echo 10 > "$a/nr_regions/min"; echo 1000 > "$a/nr_regions/max"
	for f in samon_act_p1 samon_act_p2 samon_act_p3 samon_act_p4 samon_dev_major samon_dev_minor; do
		echo 0 > "$t/parm/$f"
	done
	echo 1 > "$t/parm/samon_dbg_lba"
	echo Y > "$t/parm/samon_opt_b"
	echo N > "$t/lrup/enabled"
	echo 500 > "$t/lrup/wmarks_high"; echo 400 > "$t/lrup/wmarks_mid"; echo 10 > "$t/lrup/wmarks_low"
	echo 120000000 > "$t/lrup/cold_min_age"
	echo N > "$t/lrup/commit_inputs"
	echo "-1" > "$t/lrup/kdamond_pid"; chmod 444 "$t/lrup/kdamond_pid"
	echo 0x0007 > "$t/lrugen"
	echo "q_cap=1024" > "$t/dbg/stats"
}

put_pid() { chmod 644 "$1/lrup/kdamond_pid"; printf '%s\n' "$2" > "$1/lrup/kdamond_pid"; chmod 444 "$1/lrup/kdamond_pid"; }

cat > "$TMP/run_driver.sh" <<'EOF'
#!/bin/bash
# env: T 트리, BENCH, WLSH, CFGNAME, 선택: DRYMODE, WLN, NR_MINV, NR_MAXV, FAULT_SUFFIX, FAULT_VALUE,
#      FAULT_MODE(drop|fail), FAULT_RMDIR, FAKE_NO_PID, WL_RC, SB_DROP
export SB_KD=$T/kd SB_PARM=$T/parm SB_LRUP=$T/lrup SB_LRUGEN=$T/lrugen SB_DBG=$T/dbg SB_CGROOT=$T/cg
export SB_DROP=${SB_DROP:-$T/drop} SB_STATE_WAIT=1 SB_RESTORE_WAIT=1
# shellcheck disable=SC1090
. "$BENCH"; . "$WLSH"
DRY=${DRYMODE:-0}; WL=${WLN:-mixed}; DIR=$T/w; OUT=$T/out
MEM=768M; MEM_BYTES=$((768 << 20)); SECS=1; RAMP=0; SEED=123
SAMPLE_US=5000; AGGR_US=100000; UPDATE_US=1000000; NR_MIN=${NR_MINV:-}; NR_MAX=${NR_MAXV:-}
COLD_MIN_AGE=10000000; PID_WAIT=1; DMAJ=8; DMIN=0
LOG=$T/log; : > "$LOG"
ACTIVE=0

setpid() { printf '%s\n' "$1" > "$T/lrup/kdamond_pid.new"; mv -f "$T/lrup/kdamond_pid.new" "$T/lrup/kdamond_pid"; chmod 444 "$T/lrup/kdamond_pid"; }
rwrite() { # 가짜 커널
	if [ "$ACTIVE" = 1 ]; then
		echo "W ${1#"$T"/} $2" >> "$LOG"
		if [ -n "${FAULT_SUFFIX:-}" ] && [[ $1 == *"$FAULT_SUFFIX" ]] && { [ -z "${FAULT_VALUE-}" ] || [ "$2" = "$FAULT_VALUE" ]; }; then
			[ "${FAULT_MODE:-drop}" = fail ] && return 1
			return 0
		fi
	fi
	case $1 in
	*/lrup/enabled) if [ -z "${FAKE_NO_PID:-}" ]; then if [ "$2" = Y ]; then setpid $$; else setpid -1; fi; fi ;;
	*/kd/0/state) [ "$2" = on ] && echo "ON_WRITE KD_STARTED=$SAMON_KD_STARTED" >> "$LOG" ;;
	esac
	{ printf '%s\n' "$2" > "$1"; } 2>/dev/null
}
# cgroupfs 흉내: mkdir하면 제어 파일이 생기고, rmdir은 제어 파일이 있어도 지운다(FAULT_RMDIR이면 실패)
mkdir() {
	command mkdir "$@" || return $?
	local d
	for d in "$@"; do
		case $d in */samon_bench) : > "$d/cgroup.kill"; : > "$d/cgroup.procs" ;; esac
	done
}
rmdir() { [ -z "${FAULT_RMDIR:-}" ] || [ "$ACTIVE" != 1 ] || return 1; rm -rf -- "$@"; }
swl_exec_in_cgroup() { echo "WORKLOAD $1 memory.max=$(cat "$1/memory.max" 2>&1)" >> "$LOG"; return "${WL_RC:-0}"; }
swl_run_r11() { echo "WORKLOAD_DRY $*" >> "$LOG"; return "${WL_RC:-0}"; }
hook_before_workload() { echo "HOOK before_workload" >> "$LOG"; }
hook_pre_snapshot() { echo "HOOK pre_snapshot" >> "$LOG"; }
hook_post_snapshot() { echo "HOOK post_snapshot" >> "$LOG"; }
hook_run_finish() { echo "HOOK run_finish" >> "$LOG"; }

if [ "$DRY" = 0 ]; then read_saved_state || { echo "save failed: $SAVE_ERR" >&2; exit 99; }; fi
install_traps
ACTIVE=1
run_one 1 2 "$CFGNAME"
rc=$?
ACTIVE=0
echo "$rc" > "$T/rc"
{
	echo "RUN_LRU_GEN=$RUN_LRU_GEN"
	echo "RUN_FIO_RC=$RUN_FIO_RC"
	echo "SAMON_KD_STARTED=$SAMON_KD_STARTED"
	for k in "${!RUN_STATE[@]}"; do echo "S $k=${RUN_STATE[$k]}"; done | sort
} > "$T/dump"
exit "$rc"
EOF

# 실행: tree cfg [VAR=val ...] -> RC(driver 종료 코드), $t/err
drive() {
	local t=$1 cfgname=$2
	shift 2
	env T="$t" BENCH="$BENCH" WLSH="$WLSH" CFGNAME="$cfgname" "$@" bash "$TMP/run_driver.sh" 2> "$t/err"
	RC=$?
}
logline() { grep -n -m1 -- "$2" "$1/log" | cut -d: -f1; }
before() { # tree, patternA, patternB: A가 B보다 먼저 나온다
	local a b
	a=$(logline "$1" "$2"); b=$(logline "$1" "$3")
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
has() { grep -q -- "$2" "$1/log"; }
errhas() { grep -q -- "$2" "$1/err"; }
val() { cat "$1"; }

# 복원이 끝났는지(성공 경로와 실패 경로 공통)
restored_ok() { # tree
	local t=$1
	[ "$(val "$t/lrugen")" = 0x0007 ] && [ "$(val "$t/kd/0/state")" = off ] && [ "$(val "$t/lrup/enabled")" = N ] &&
		[ "$(val "$t/parm/samon_opt_b")" = Y ] && [ "$(val "$t/parm/samon_dbg_lba")" = 1 ] &&
		[ "$(val "$t/parm/samon_act_p1")" = 0 ] && [ "$(val "$t/lrup/wmarks_mid")" = 400 ] &&
		[ ! -d "$t/cg/samon_bench" ] &&
		[ "$(tail -1 "$t/err")" = "bench: restore verified: no mismatch" ]
}

# --- 성공 경로 ---
for c in off off2 damon samon_observe samon_all samon_all_classic samon_p1_classic; do
	t=$TMP/s_$c; mk_tree "$t"
	drive "$t" $c
	check "$c: run_one ok, workload started in the cgroup" "$([ "$RC" = 0 ] && has "$t" '^WORKLOAD .*/samon_bench memory.max=768M$'; echo $?)" "rc=$RC $(cat "$t/err")"
	check "$c: restored afterwards" "$(restored_ok "$t"; echo $?)" "$(tail -3 "$t/err")"
done

t=$TMP/s_off; wr() { grep -c '^W ' "$t/log"; }
check "off: lru_gen written with the start value (0x0007) and read back" "$([ "$(grep '^RUN_LRU_GEN=' "$t/dump")" = "RUN_LRU_GEN=0x0007" ]; echo $?)"
check "off: step order lru_gen < memory.max < swap.max < drop_caches < workload" "$(before "$t" 'W lrugen' 'memory.max' && before "$t" 'memory.max' 'memory.swap.max 0' && before "$t" 'memory.swap.max' 'W drop 3' && before "$t" 'W drop 3' '^WORKLOAD'; echo $?)" "$(cat "$t/log")"
check "off: hooks run around the workload in order" "$(before "$t" 'HOOK before_workload' '^WORKLOAD' && before "$t" '^WORKLOAD' 'HOOK post_snapshot' && before "$t" 'HOOK post_snapshot' 'HOOK run_finish'; echo $?)"
check "off: no SAMON/LRU_SORT writes" "$(! grep -q 'W kd/\|W lrup/\|W parm/' "$t/log"; echo $?)"
check "off: state file has config, rep, seed, states" "$(grep -qx 'config=off' "$t/out/run1.state" && grep -qx 'rep=2' "$t/out/run1.state" && grep -qx 'seed=123' "$t/out/run1.state" && grep -qx 'samon_kd_state=off' "$t/out/run1.state" && grep -qx 'lrusort_enabled=N' "$t/out/run1.state" && grep -qx 'lrusort_pid=-1' "$t/out/run1.state" && grep -qx 'lru_gen_enabled=0x0007' "$t/out/run1.state"; echo $?)" "$(cat "$t/out/run1.state")"

t=$TMP/s_damon
check "damon: wmarks 1000/999/0 and cold_min_age written, then enabled=Y" "$(before "$t" 'W lrup/wmarks_high 1000' 'W lrup/wmarks_mid 999' && before "$t" 'W lrup/wmarks_mid 999' 'W lrup/wmarks_low 0' && before "$t" 'W lrup/wmarks_low 0' 'W lrup/cold_min_age 10000000' && before "$t" 'W lrup/cold_min_age' 'W lrup/enabled Y'; echo $?)" "$(cat "$t/log")"
check "damon: commit_inputs never written" "$(! has "$t" commit_inputs; echo $?)"
check "damon: state recorded Y and live pid" "$(grep -qx 'S lrusort_enabled=Y' "$t/dump" && grep -q '^S lrusort_pid=[1-9]' "$t/dump" && grep -qx 'S samon_kd_state=off' "$t/dump"; echo $?)" "$(cat "$t/dump")"
check "damon: no SAMON writes" "$(! grep -q 'W kd/\|W parm/' "$t/log"; echo $?)"
check "damon: LRU_SORT turned back to N afterwards" "$(has "$t" 'W lrup/enabled N'; echo $?)"

t=$TMP/s_samon_all
check "samon_all: kdamond structure written (operations=saddr, nr_targets=1)" "$(has "$t" 'W kd/0/contexts/0/operations saddr' && has "$t" 'W kd/0/contexts/0/targets/nr_targets 1'; echo $?)"
check "samon_all: nr_kdamonds and nr_contexts not rewritten when already 1" "$(! has "$t" 'W kd/nr_kdamonds' && ! has "$t" 'W kd/0/contexts/nr_contexts'; echo $?)"
check "samon_all: monitoring_attrs written (sample/aggr/update) before kdamond on" "$(before "$t" 'intervals/sample_us 5000' 'ON_WRITE' && before "$t" 'intervals/aggr_us 100000' 'ON_WRITE' && before "$t" 'intervals/update_us 1000000' 'ON_WRITE'; echo $?)" "$(cat "$t/log")"
check "samon_all: nr_regions untouched without --nr-min/--nr-max, sysfs values recorded" "$(! has "$t" 'nr_regions' && grep -qx 'S mon_nr_min=10' "$t/dump" && grep -qx 'S mon_nr_max=1000' "$t/dump"; echo $?)"
check "samon_all: toggles p1..p4=1, opt_b=0, dbg_lba=0, dev 8:0 written before on" "$(for w in 'samon_act_p1 1' 'samon_act_p2 1' 'samon_act_p3 1' 'samon_act_p4 1' 'samon_opt_b 0' 'samon_dbg_lba 0' 'samon_dev_major 8' 'samon_dev_minor 0'; do before "$t" "W parm/$w" ON_WRITE || exit 1; done; echo 0)" "$(cat "$t/log")"
check "samon_all: SAMON_KD_STARTED was already 1 when 'on' was written" "$(has "$t" '^ON_WRITE KD_STARTED=1$'; echo $?)"
check "samon_all: on written before workload" "$(before "$t" ON_WRITE '^WORKLOAD'; echo $?)"
check "samon_all: confirmed state recorded" "$(for l in 'S samon_kd_state=on' 'S act_p1=1' 'S act_p2=1' 'S act_p3=1' 'S act_p4=1' 'S opt_b=0' 'S mon_sample_us=5000' 'S mon_aggr_us=100000' 'S mon_update_us=1000000' 'S lrusort_enabled=N' 'S lrusort_pid=-1' 'S lru_gen_enabled=0x0007'; do grep -qx "$l" "$t/dump" || { echo "missing: $l"; exit 1; }; done; echo 0)" "$(cat "$t/dump")"
check "samon_all: default hook_teardown turned the kdamond off and removed the cgroup (before restore)" "$(before "$t" '^HOOK run_finish' 'W kd/0/state off' && before "$t" '^HOOK run_finish' 'W cg/samon_bench/cgroup.kill 1'; echo $?)" "$(cat "$t/log")"

t=$TMP/s_samon_observe
check "samon_observe: all toggles 0" "$(grep -qx 'S act_p1=0' "$t/dump" && grep -qx 'S act_p4=0' "$t/dump" && grep -qx 'S opt_b=0' "$t/dump"; echo $?)"
t=$TMP/s_samon_all_classic
check "samon_all_classic: lru_gen written 0 and recorded" "$(has "$t" 'W lrugen 0$' && grep -q '^RUN_LRU_GEN=0' "$t/dump" && grep -qx 'lru_gen_enabled=0' "$t/out/run1.state"; echo $?)" "$(cat "$t/log") $(cat "$t/dump")"

# 시작 때 SAMON이 이미 켜져 있었다면 먼저 끈다
t=$TMP/s_on_first; mk_tree "$t"; echo on > "$t/kd/0/state"
drive "$t" samon_all
check "samon already on: stopped first, then restarted" "$([ "$RC" = 0 ] && before "$t" 'W kd/0/state off' 'W kd/0/state on'; echo $?)" "rc=$RC $(cat "$t/log")"
# --nr-min / --nr-max를 주면 쓰고 확인한다
t=$TMP/s_nr; mk_tree "$t"
drive "$t" samon_all NR_MINV=20 NR_MAXV=2000
check "--nr-min/--nr-max written and recorded" "$([ "$RC" = 0 ] && has "$t" 'nr_regions/min 20' && has "$t" 'nr_regions/max 2000' && grep -qx 'S mon_nr_min=20' "$t/dump"; echo $?)" "rc=$RC"
# 남은 cgroup(빈 디렉터리)은 지우고 새로 만든다
t=$TMP/s_cgleft; mk_tree "$t"; mkdir "$t/cg/samon_bench"
drive "$t" off
check "leftover empty cgroup is replaced" "$([ "$RC" = 0 ] && has "$t" 'W cg/samon_bench/memory.max 768M'; echo $?)" "rc=$RC"
# 워크로드가 0이 아닌 코드로 끝나도 실행 실패가 아니다(fio_rc에 남는다)
t=$TMP/s_fiorc; mk_tree "$t"
drive "$t" off WL_RC=3
check "workload rc 3 is recorded in RUN_FIO_RC, run_one ok" "$([ "$RC" = 0 ] && grep -qx 'RUN_FIO_RC=3' "$t/dump"; echo $?)" "rc=$RC $(cat "$t/dump")"

# --- 실패 경로: 항목과 값 출력, 0이 아닌 종료, 워크로드 없음, restore는 실행 ---
fail_case() { # name tree cfg item pattern-in-message [VAR=val ...]
	local name=$1 t=$2 cfgname=$3 item=$4 pat=$5
	shift 5
	drive "$t" "$cfgname" "$@"
	check "$name: exit code 1" "$([ "$RC" = 1 ]; echo $?)" "rc=$RC"
	check "$name: prints 'BENCH RUN FAIL $item:'" "$(errhas "$t" "BENCH RUN FAIL $item:"; echo $?)" "$(cat "$t/err")"
	check "$name: message has the value ($pat)" "$(errhas "$t" "BENCH RUN FAIL $item:.*$pat"; echo $?)" "$(grep 'BENCH RUN FAIL' "$t/err")"
	check "$name: message names the run and config" "$(errhas "$t" "run=1 rep=2 config=$cfgname"; echo $?)"
	check "$name: workload not started" "$(! has "$t" WORKLOAD; echo $?)"
	check "$name: no hook after the failure point ran" "$(! has "$t" 'HOOK before_workload'; echo $?)"
	check "$name: restore ran and verified" "$(restored_ok "$t"; echo $?)" "$(tail -3 "$t/err")"
}

t=$TMP/f_lrugen; mk_tree "$t"
fail_case "lru_gen mismatch" "$t" off_classic lru_gen "read back '0x0007'" FAULT_SUFFIX=/lrugen FAULT_VALUE=0
t=$TMP/f_lrugen_w; mk_tree "$t"
fail_case "lru_gen write error" "$t" off_classic lru_gen "cannot write '0'" FAULT_SUFFIX=/lrugen FAULT_VALUE=0 FAULT_MODE=fail
t=$TMP/f_memmax; mk_tree "$t"
fail_case "memory.max not applied" "$t" off cgroup_memory_max "cannot read it back" FAULT_SUFFIX=/memory.max
t=$TMP/f_swap; mk_tree "$t"
fail_case "memory.swap.max not applied" "$t" off cgroup_memory_swap_max "cannot read it back" FAULT_SUFFIX=/memory.swap.max
t=$TMP/f_drop; mk_tree "$t"; mkdir "$t/dropdir"
fail_case "drop_caches write error" "$t" off drop_caches "cannot write 3" SB_DROP="$t/dropdir"
t=$TMP/f_cgname; mk_tree "$t"
fail_case "unknown config name" "$t" nosuch config_name "'nosuch'"
t=$TMP/f_cgstuck; mk_tree "$t"; mkdir "$t/cg/samon_bench"; : > "$t/cg/samon_bench/cgroup.kill"
fail_case "leftover cgroup cannot be removed" "$t" off cgroup "cannot remove" FAULT_RMDIR=1

t=$TMP/f_off_pid; mk_tree "$t"; put_pid "$t" 4242
fail_case "off: kdamond_pid not -1" "$t" off lrusort_kdamond_pid "read '4242'" FAKE_NO_PID=1
t=$TMP/f_damon_mid; mk_tree "$t"
fail_case "damon: wmarks_mid not applied" "$t" damon lrusort_wmarks_mid "read back '400'" FAULT_SUFFIX=/wmarks_mid
t=$TMP/f_damon_pid; mk_tree "$t"
fail_case "damon: kdamond_pid never > 0" "$t" damon lrusort_kdamond_pid "read '-1'" FAKE_NO_PID=1
t=$TMP/f_damon_en; mk_tree "$t"
fail_case "damon: enabled=Y write error" "$t" damon lrusort_enabled "cannot write 'Y'" FAULT_SUFFIX=/enabled FAULT_VALUE=Y FAULT_MODE=fail

t=$TMP/f_s_lru_on; mk_tree "$t"; echo Y > "$t/lrup/enabled"; put_pid "$t" 99
fail_case "samon: LRU_SORT stays Y" "$t" samon_all lrusort_enabled "read 'Y'" FAULT_SUFFIX=/lrup/enabled FAULT_VALUE=N
t=$TMP/f_s_attr; mk_tree "$t"
fail_case "samon: sample_us not applied" "$t" samon_all mon_sample_us "read back '1'" FAULT_SUFFIX=intervals/sample_us
t=$TMP/f_s_aggr; mk_tree "$t"
fail_case "samon: aggr_us not applied" "$t" samon_all mon_aggr_us "read back '2'" FAULT_SUFFIX=intervals/aggr_us
t=$TMP/f_s_act; mk_tree "$t"
fail_case "samon: act_p2 not applied" "$t" samon_all samon_act_p2 "read back '0'" FAULT_SUFFIX=/samon_act_p2
t=$TMP/f_s_optb; mk_tree "$t"
fail_case "samon: opt_b not applied" "$t" samon_all samon_opt_b "read back 'Y'" FAULT_SUFFIX=/samon_opt_b
t=$TMP/f_s_dbg; mk_tree "$t"
fail_case "samon: samon_dbg_lba not 0" "$t" samon_observe samon_dbg_lba "read back '1'" FAULT_SUFFIX=/samon_dbg_lba
t=$TMP/f_s_ops; mk_tree "$t"
fail_case "samon: operations not saddr" "$t" samon_all samon_operations "read back 'paddr'" FAULT_SUFFIX=/operations
t=$TMP/f_s_state; mk_tree "$t"
fail_case "samon: kdamond does not turn on" "$t" samon_all samon_kdamond_state "read 'off'" FAULT_SUFFIX=/state FAULT_VALUE=on
check "samon: SAMON_KD_STARTED was set before the failed 'on' write" "$(grep -qx 'SAMON_KD_STARTED=1' "$t/dump"; echo $?)" "$(cat "$t/dump")"
t=$TMP/f_s_qcap; mk_tree "$t"; echo "q_cap=0" > "$t/dbg/stats"
fail_case "samon: q_cap = 0" "$t" samon_all samon_q_cap "read '0'"
check "samon q_cap=0: kdamond was on, restore turned it off" "$(has "$t" 'ON_WRITE KD_STARTED=1' && [ "$(val "$t/kd/0/state")" = off ]; echo $?)"
t=$TMP/f_s_qcap2; mk_tree "$t"; echo "rq_seen=5" > "$t/dbg/stats"
fail_case "samon: stats has no q_cap" "$t" samon_all samon_q_cap "read '<none>'"

# 워크로드가 cgroup에 못 들어간 경우(125)는 하네스 실패
t=$TMP/f_join; mk_tree "$t"
drive "$t" off WL_RC=125
check "workload rc 125 (cannot join cgroup): run fails with item workload_cgroup" "$([ "$RC" = 1 ] && errhas "$t" 'BENCH RUN FAIL workload_cgroup:'; echo $?)" "rc=$RC $(cat "$t/err")"
check "workload rc 125: restore verified" "$(restored_ok "$t"; echo $?)"

# --- 드라이런: sysfs·cgroup 조작 없음 ---
t=$TMP/dry; mk_tree "$t"
before_snap=$(cd "$t" && find kd parm lrup cg -type f -print0 | sort -z | xargs -0 cat | md5sum)
drive "$t" samon_all DRYMODE=1
after_snap=$(cd "$t" && find kd parm lrup cg -type f -print0 | sort -z | xargs -0 cat | md5sum)
check "dry run: run_one rc 0" "$([ "$RC" = 0 ]; echo $?)" "rc=$RC $(cat "$t/err")"
check "dry run: no sysfs/cgroup writes and nothing changed" "$([ ! -d "$t/cg/samon_bench" ] && ! grep -q '^W ' "$t/log" && [ "$before_snap" = "$after_snap" ]; echo $?)" "$(cat "$t/log")"
check "dry run: workload run directly (no cgroup), hooks run" "$(has "$t" '^WORKLOAD_DRY mixed ' && ! has "$t" '^WORKLOAD /' && has "$t" 'HOOK run_finish'; echo $?)" "$(cat "$t/log")"
check "dry run: state file written without sysfs states" "$(grep -qx 'config=samon_all' "$t/out/run1.state" && ! grep -q '^act_p1=' "$t/out/run1.state"; echo $?)"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
