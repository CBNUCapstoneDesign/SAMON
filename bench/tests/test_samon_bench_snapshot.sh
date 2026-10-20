#!/bin/bash
# samon_bench.sh 스냅샷, cachestat, CSV 행, 경고 시험 (tasks 24.5). 가짜 sysfs·cgroup·/proc 트리와
# 가짜 워크로드, 가짜 cachestat만 쓴다. root도 sudo도 fio도 필요 없다.
#   usage: bash bench/tests/test_samon_bench_snapshot.sh
# driver는 samon_bench.sh를 source해 run_one을 실제 hook(스냅샷, cachestat, row)으로 돌린다.
# 가짜 워크로드는 pre 스냅샷이 끝나길 기다린 뒤 가짜 커널 값을 바꾼다. 그래서 차분이 0이 아니면
# post 스냅샷이 측정 구간 뒤에 읽혔다는 뜻이다. 구간 안에서 `cat`으로 읽은 파일은 window_reads에 남는다.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BDIR=$(cd "$HERE/.." && pwd)
BENCH=$BDIR/samon_bench.sh
WLSH=$BDIR/samon_workloads.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
CLK=$(getconf CLK_TCK)

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || echo "     $2"; }
check() { # name, result (0 = pass), detail
	if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# runs.csv의 데이터 행 R(1부터)의 열 C 값
csvval() {
	python3 - "$1" "$2" "$3" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
print(rows[int(sys.argv[2]) - 1][sys.argv[3]])
PY
}
# 숫자 같음(부동소수 오차 허용): feq A B
feq() { python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 1e-6 else 1)' "$1" "$2" 2>/dev/null; }
csveq() { feq "$(csvval "$1" "$2" "$3")" "$4"; } # file row col want

# 열 정의 대조: bash의 LRU_SORT 통계 이름 10개 = samon_benchlib.py의 LRU_SORT_STATS_KEYS
lru_bash=$(bash -c ". '$BENCH'; echo \$LRU_STATS_NAMES")
lru_py=$(python3 -c "import sys; sys.path.insert(0, '$BDIR'); import samon_benchlib as b; print(' '.join(b.LRU_SORT_STATS_KEYS))")
check "LRU_STATS_NAMES equals samon_benchlib.LRU_SORT_STATS_KEYS" "$([ "$lru_bash" = "$lru_py" ]; echo $?)" "$lru_bash"

# ---------------------------------------------------------------------------
# 가짜 트리
# ---------------------------------------------------------------------------
LRU_NAMES=$lru_py

mk_tree() { # dir
	local t=$1 f a n
	mkdir -p "$t/kd/0/contexts/0/targets" "$t/kd/0/contexts/0/monitoring_attrs/intervals" \
		"$t/kd/0/contexts/0/monitoring_attrs/nr_regions" "$t/parm" "$t/lrup" "$t/cg" "$t/dbg" "$t/out" "$t/w" "$t/proc"
	echo 1 > "$t/kd/nr_kdamonds"; echo off > "$t/kd/0/state"; echo 1 > "$t/kd/0/contexts/nr_contexts"
	echo paddr > "$t/kd/0/contexts/0/operations"; echo 0 > "$t/kd/0/contexts/0/targets/nr_targets"
	a=$t/kd/0/contexts/0/monitoring_attrs
	echo 1 > "$a/intervals/sample_us"; echo 2 > "$a/intervals/aggr_us"; echo 3 > "$a/intervals/update_us"
	echo 10 > "$a/nr_regions/min"; echo 1000 > "$a/nr_regions/max"
	for f in samon_act_p1 samon_act_p2 samon_act_p3 samon_act_p4 samon_dev_major samon_dev_minor; do echo 0 > "$t/parm/$f"; done
	echo 1 > "$t/parm/samon_dbg_lba"; echo Y > "$t/parm/samon_opt_b"
	echo N > "$t/lrup/enabled"; echo 500 > "$t/lrup/wmarks_high"; echo 400 > "$t/lrup/wmarks_mid"
	echo 10 > "$t/lrup/wmarks_low"; echo 120000000 > "$t/lrup/cold_min_age"; echo N > "$t/lrup/commit_inputs"
	echo "-1" > "$t/lrup/kdamond_pid"; chmod 444 "$t/lrup/kdamond_pid"
	for n in $LRU_NAMES; do echo 0 > "$t/lrup/$n"; chmod 444 "$t/lrup/$n"; done
	echo 0x0007 > "$t/lrugen"
	echo "q_cap=1024" > "$t/dbg/stats"
}

cat > "$TMP/snap_driver.sh" <<'EOF'
#!/bin/bash
# env: T BENCH WLSH CFGS(공백 구분 구성 이름 목록) 선택: DRYMODE WLN RAMPV QWARN WL_RC WL_SLEEP
#      ZERO_LRU(damon 통계를 안 바꿈) FAIL_PRE BAD_STATE SB_CACHESTAT CS_PIDFILE LOOP_PASSES
export SB_KD=$T/kd SB_PARM=$T/parm SB_LRUP=$T/lrup SB_LRUGEN=$T/lrugen SB_DBG=$T/dbg SB_CGROOT=$T/cg
export SB_DROP=$T/drop SB_STATE_WAIT=1 SB_RESTORE_WAIT=1 SB_PROC=$T/proc SB_CACHESTAT_WAIT=3
# shellcheck disable=SC1090
. "$BENCH"; . "$WLSH"
DRY=${DRYMODE:-0}; WL=${WLN:-mixed}; DIR=$T/w; OUT=$T/out
MEM=768M; MEM_BYTES=$((768 << 20)); SECS=1; RAMP=${RAMPV:-1}; SEED=123
SAMPLE_US=5000; AGGR_US=100000; UPDATE_US=1000000; NR_MIN=""; NR_MAX=""
COLD_MIN_AGE=10000000; PID_WAIT=1; DMAJ=8; DMIN=0; Q_WARN_PCT=${QWARN:-1}
CSV=$OUT/runs.csv
INWIN=0

setpid() { printf '%s\n' "$1" > "$T/lrup/kdamond_pid.new"; mv -f "$T/lrup/kdamond_pid.new" "$T/lrup/kdamond_pid"; chmod 444 "$T/lrup/kdamond_pid"; }
setro() { printf '%s\n' "$2" > "$1.new"; mv -f "$1.new" "$1"; chmod 444 "$1"; }
rwrite() { # 가짜 커널
	case $1 in
	*/lrup/enabled) if [ "$2" = Y ]; then setpid $$; else setpid -1; fi ;;
	esac
	{ printf '%s\n' "$2" > "$1"; } 2>/dev/null
}
mkdir() {
	command mkdir "$@" || return $?
	local d
	for d in "$@"; do case $d in */samon_bench) : > "$d/cgroup.kill"; : > "$d/cgroup.procs" ;; esac; done
}
rmdir() { rm -rf -- "$@"; }

# 가짜 /proc. 이 driver의 pid가 kdamond pid로 쓰인다(start_damon이 진짜 /proc/$pid를 확인한다).
mkdir -p "$T/proc/$$"
[ "$DRY" = 1 ] || echo $$ > "$T/kd/0/pid"
fake_proc() { # 단계 A|B
	if [ "$1" = A ]; then
		printf 'pgpgin 1000\npgpgout 5\n' > "$T/proc/vmstat"
		printf 'cpu  10 0 100 500 0 10 20 0 0 0\ncpu0 1 2 3\n' > "$T/proc/stat"
		printf 'MemTotal: 1000 kB\nSlab: 1000 kB\nSUnreclaim: 500 kB\n' > "$T/proc/meminfo"
		printf '%s (kdamond.0) S 2 0 0 0 -1 0 0 0 0 0 100 20 0 0 20 0 1 0\n' $$ > "$T/proc/$$/stat"
	else
		printf 'pgpgin 9192\npgpgout 5\n' > "$T/proc/vmstat"
		printf 'cpu  10 0 200 500 0 15 50 0 0 0\ncpu0 1 2 3\n' > "$T/proc/stat"
		printf 'MemTotal: 1000 kB\nSlab: 1300 kB\nSUnreclaim: 450 kB\n' > "$T/proc/meminfo"
		printf '%s (kdamond.0) S 2 0 0 0 -1 0 0 0 0 0 150 30 0 0 20 0 1 0\n' $$ > "$T/proc/$$/stat"
	fi
}
fake_stats() { # req drop: SAMON stats 원문(알려진 키만, 마지막은 entries 줄)
	local i
	{
		echo "q_cap=1024"; echo "rq_seen=$(( $1 / 10 ))"
		for i in 1 2 3 4 5; do echo "req_p$i=$([ "$i" = 1 ] && echo "$1" || echo 0)"; done
		for i in 1 2 3 4 5; do echo "drop_queue_p$i=$([ "$i" = 1 ] && echo "$2" || echo 0)"; done
		echo "entries=5 max_entries=100"
	} > "$T/dbg/stats"
}
fake_lru() { # 값
	local n
	for n in $LRU_STATS_NAMES; do setro "$T/lrup/$n" "$1"; done
}

# 가짜 워크로드: pre 스냅샷이 끝난 뒤에 "측정 구간" 값을 만든다.
fake_work() { # cgroup(비면 드라이런) PFX
	local cg=$1 pfx=$2 t0=1000000000000
	fake_proc A
	if [ -n "$cg" ]; then
		printf 'workingset_refault_file 5\nworkingset_activate_file 1\npgscan 100\npgsteal 40\n' > "$cg/memory.stat"
		fake_stats 100 0
		fake_lru 0
	fi
	for ((i = 0; i < 100; i++)); do [ -e "$T/pre_done" ] && break; sleep 0.1; done
	fake_proc B
	if [ -n "$cg" ]; then
		printf 'workingset_refault_file 15\nworkingset_activate_file 4\npgscan 300\npgsteal 140\n' > "$cg/memory.stat"
		fake_stats 1100 20
		[ -n "${ZERO_LRU:-}" ] || fake_lru 7
	fi
	if [ "$WL" = loop ]; then
		{
			echo "idx,start_ns,end_ns,rc,io_bytes"
			echo "1,$t0,$((t0 + 1000000000)),0,1048576"
			echo "2,$((t0 + 1000000000)),$((t0 + 2000000000)),0,1048576"
			[ "${LOOP_PASSES:-2}" -lt 2 ] || echo "3,$((t0 + 2000000000)),$((t0 + 3000000000)),0,1048576"
		} > "$pfx.passes.csv"
		printf 't0_ns=%s\nramp_s=1\nsecs=1\nfile_bytes=1048576\n' "$t0" > "$pfx.passes.meta"
	fi
	sleep "${WL_SLEEP:-0.2}"
	return "${WL_RC:-0}"
}
swl_exec_in_cgroup() { fake_work "$1" "${@: -1}"; }
swl_run_r11() { fake_work "" "${@: -1}"; }

# hook 감싸기: 구간 표시, cat 감시
eval "$(declare -f hook_pre_snapshot | sed '1s/^hook_pre_snapshot/orig_hook_pre_snapshot/')"
eval "$(declare -f hook_post_snapshot | sed '1s/^hook_post_snapshot/orig_hook_post_snapshot/')"
eval "$(declare -f hook_before_workload | sed '1s/^hook_before_workload/orig_hook_before_workload/')"
hook_before_workload() {
	rm -f "$T/pre_done"
	orig_hook_before_workload || return 1
	[ -z "${BAD_STATE:-}" ] || echo bogus >> "$RUN_PFX.state"
	return 0
}
hook_pre_snapshot() {
	[ -z "${FAIL_PRE:-}" ] || { : > "$T/pre_done"; return 1; }
	orig_hook_pre_snapshot || return 1
	INWIN=1; : > "$T/pre_done"
}
hook_post_snapshot() { INWIN=0; orig_hook_post_snapshot; }
cat() { [ "$INWIN" != 1 ] || echo "$*" >> "$T/window_reads"; command cat "$@"; }
: > "$T/window_reads"

if [ "$DRY" = 0 ]; then read_saved_state || { echo "save failed: $SAVE_ERR" >&2; exit 99; }; fi
install_traps
cachestat_probe
n=0; rc=0
for c in $CFGS; do
	n=$((n + 1))
	run_one "$n" "$n" "$c" || { rc=$?; break; }
done
echo "$rc" > "$T/rc"
echo "CSV_ROWS=$CSV_ROWS CACHESTAT_PID=$CACHESTAT_PID CACHESTAT_OK=$CACHESTAT_OK" > "$T/dump"
exit "$rc"
EOF

drive() { # tree cfgs [VAR=val ...]
	local t=$1 cfgs=$2
	shift 2
	env T="$t" BENCH="$BENCH" WLSH="$WLSH" CFGS="$cfgs" "$@" bash "$TMP/snap_driver.sh" 2> "$t/err"
	RC=$?
}
errhas() { grep -q -- "$2" "$1/err"; }
restored_ok() { [ ! -d "$1/cg/samon_bench" ] && [ "$(cat "$1/kd/0/state")" = off ] && [ "$(cat "$1/lrup/enabled")" = N ] &&
	[ "$(tail -1 "$1/err")" = "bench: restore verified: no mismatch" ]; }
files_of() { (cd "$1" && LC_ALL=C ls | tr '\n' ' '); }

# ---------------------------------------------------------------------------
# 1. SAMON 구성: 스냅샷 파일, 차분, 큐 경고, 구간 안 읽기 없음
# ---------------------------------------------------------------------------
t=$TMP/samon; mk_tree "$t"
drive "$t" "samon_all" SB_CACHESTAT=/nonexistent/cachestat
csv=$t/out/runs.csv
check "samon_all: run ok, restored" "$([ "$RC" = 0 ] && restored_ok "$t"; echo $?)" "rc=$RC $(tail -5 "$t/err")"
check "samon_all: pre snapshot has vmstat stat meminfo memory.stat samon_stats kd_stat ts, no lru_sort_stats" "$([ "$(files_of "$t/out/snap_1_pre")" = "kd_stat meminfo memory.stat samon_stats stat ts vmstat " ]; echo $?)" "$(files_of "$t/out/snap_1_pre")"
check "samon_all: post snapshot has the same files" "$([ "$(files_of "$t/out/snap_1_post")" = "kd_stat meminfo memory.stat samon_stats stat ts vmstat " ]; echo $?)" "$(files_of "$t/out/snap_1_post")"
check "pre snapshot holds ramp-end values, post the later ones" "$(grep -q '^pgpgin 1000$' "$t/out/snap_1_pre/vmstat" && grep -q '^pgpgin 9192$' "$t/out/snap_1_post/vmstat" && grep -qx 'req_p1=100' "$t/out/snap_1_pre/samon_stats" && grep -qx 'req_p1=1100' "$t/out/snap_1_post/samon_stats"; echo $?)"
check "stat snapshot is the first line only" "$([ "$(wc -l < "$t/out/snap_1_pre/stat")" = 1 ] && grep -q '^cpu ' "$t/out/snap_1_pre/stat"; echo $?)"
check "pre ts < post ts" "$(python3 -c "import sys; sys.exit(0 if float(open('$t/out/snap_1_pre/ts').read()) < float(open('$t/out/snap_1_post/ts').read()) else 1)"; echo $?)"
check "no debugfs/LRU_SORT/any file read between pre and post" "$([ ! -s "$t/window_reads" ]; echo $?)" "$(cat "$t/window_reads")"
check "runs.csv: header + 1 row, same column count" "$([ "$(wc -l < "$csv")" = 2 ] && [ "$(awk -F, '{print NF}' "$csv" | sort -u | wc -l)" = 1 ]; echo $?)"
check "runs.csv header equals samon_benchlib.py header" "$([ "$(head -1 "$csv")" = "$(python3 "$BDIR/samon_benchlib.py" header)" ]; echo $?)"
check "row: identity and confirmed state from the state file" "$([ "$(csvval "$csv" 1 config)" = samon_all ] && [ "$(csvval "$csv" 1 workload)" = mixed ] && [ "$(csvval "$csv" 1 rep)" = 1 ] && [ "$(csvval "$csv" 1 seed)" = 123 ] && [ "$(csvval "$csv" 1 samon_kd_state)" = on ] && [ "$(csvval "$csv" 1 act_p1)" = 1 ] && [ "$(csvval "$csv" 1 opt_b)" = 0 ] && [ "$(csvval "$csv" 1 lru_gen_enabled)" = 0x0007 ] && [ "$(csvval "$csv" 1 mon_aggr_us)" = 100000 ] && [ "$(csvval "$csv" 1 fio_rc)" = 0 ]; echo $?)" "$(tail -1 "$csv")"
check "row: pgpgin, cpu sys/irq/softirq deltas" "$(csveq "$csv" 1 pgpgin_kib 8192 && csveq "$csv" 1 cpu_sys_s "$(python3 -c "print(100/$CLK)")" && csveq "$csv" 1 cpu_irq_s "$(python3 -c "print(5/$CLK)")" && csveq "$csv" 1 cpu_softirq_s "$(python3 -c "print(30/$CLK)")" && csveq "$csv" 1 cpu_sys_irq_softirq_s "$(python3 -c "print(135/$CLK)")"; echo $?)" "$(tail -1 "$csv")"
check "row: memory.stat deltas from the cgroup (read before it was removed)" "$(csveq "$csv" 1 cg_workingset_refault_file 10 && csveq "$csv" 1 cg_workingset_activate_file 3 && csveq "$csv" 1 cg_pgscan 200 && csveq "$csv" 1 cg_pgsteal 100; echo $?)"
check "row: slab and sunreclaim deltas (negative kept)" "$(csveq "$csv" 1 slab_kb 300 && csveq "$csv" 1 sunreclaim_kb -50; echo $?)"
check "row: kdamond CPU from /proc/<pid>/stat (pid read before pre)" "$(csveq "$csv" 1 kd_cpu_s "$(python3 -c "print(60/$CLK)")"; echo $?)"
check "row: SAMON stats deltas, q_cap is the post value" "$(csveq "$csv" 1 s_req_p1 1000 && csveq "$csv" 1 s_drop_queue_p1 20 && csveq "$csv" 1 s_rq_seen 100 && csveq "$csv" 1 s_q_cap 1024; echo $?)" "$(tail -1 "$csv")"
check "row: LRU_SORT columns and damon_inactive are NA for SAMON" "$([ "$(csvval "$csv" 1 ls_nr_lru_sorted_hot_regions)" = NA ] && [ "$(csvval "$csv" 1 damon_inactive)" = NA ]; echo $?)"
check "row: queue-drop 2% > 1% sets q_warn=1" "$([ "$(csvval "$csv" 1 q_warn)" = 1 ]; echo $?)"
check "q_warn warning printed with the sums" "$(errhas "$t" 'WARNING: run 1 (rep 1, config samon_all): queue drops 20 exceed 1% of requests 1000'; echo $?)" "$(cat "$t/err")"
check "cachestat unavailable: cachestat_hit_pct NA, warning printed, no cachestat file" "$([ "$(csvval "$csv" 1 cachestat_hit_pct)" = NA ] && errhas "$t" 'not found: cachestat_hit_pct = NA' && [ ! -e "$t/out/cachestat_1.txt" ]; echo $?)"
check "hook_teardown turned the kdamond off and removed the cgroup" "$([ "$(cat "$t/kd/0/state")" = off ] && [ ! -d "$t/cg/samon_bench" ]; echo $?)"

# --q-warn-pct 5: 2%는 경고가 아니다
t=$TMP/samon_q5; mk_tree "$t"
drive "$t" "samon_all" SB_CACHESTAT=/nonexistent QWARN=5
check "--q-warn-pct 5: q_warn=0 and no queue-drop warning" "$([ "$RC" = 0 ] && [ "$(csvval "$t/out/runs.csv" 1 q_warn)" = 0 ] && ! errhas "$t" 'queue drops'; echo $?)"

# ---------------------------------------------------------------------------
# 2. damon 계열, off 계열, 여러 실행(헤더 한 번)
# ---------------------------------------------------------------------------
t=$TMP/multi; mk_tree "$t"
drive "$t" "damon off" SB_CACHESTAT=/nonexistent
csv=$t/out/runs.csv
check "damon then off: rc 0, restored" "$([ "$RC" = 0 ] && restored_ok "$t"; echo $?)" "rc=$RC $(tail -4 "$t/err")"
check "two runs: one header + 2 rows" "$([ "$(wc -l < "$csv")" = 3 ] && [ "$(grep -c '^run,' "$csv")" = 1 ]; echo $?)"
check "damon: snapshot has lru_sort_stats (10 lines) and kd_stat, no samon_stats" "$([ "$(files_of "$t/out/snap_1_pre")" = "kd_stat lru_sort_stats meminfo memory.stat stat ts vmstat " ] && [ "$(wc -l < "$t/out/snap_1_pre/lru_sort_stats")" = 10 ]; echo $?)" "$(files_of "$t/out/snap_1_pre")"
check "damon: 10 LRU_SORT deltas recorded (7 - 0), damon_inactive=0" "$(for n in $LRU_NAMES; do csveq "$csv" 1 "ls_$n" 7 || exit 1; done; [ "$(csvval "$csv" 1 damon_inactive)" = 0 ]; echo $?)" "$(tail -2 "$csv" | head -1)"
check "damon: SAMON columns NA, q_warn NA, kd_cpu_s from kdamond_pid" "$([ "$(csvval "$csv" 1 s_req_p1)" = NA ] && [ "$(csvval "$csv" 1 q_warn)" = NA ] && csveq "$csv" 1 kd_cpu_s "$(python3 -c "print(60/$CLK)")"; echo $?)"
check "damon: state columns (enabled Y, live pid)" "$([ "$(csvval "$csv" 1 lrusort_enabled)" = Y ] && [ "$(csvval "$csv" 1 config)" = damon ] && [ "$(csvval "$csv" 1 lrusort_pid)" -gt 0 ]; echo $?)"
check "damon: no read between pre and post (LRU_SORT files only in snapshots)" "$([ ! -s "$t/window_reads" ]; echo $?)"
check "off: only /proc and memory.stat files, kd_cpu_s and SAMON/LRU_SORT columns NA" "$([ "$(files_of "$t/out/snap_2_pre")" = "meminfo memory.stat stat ts vmstat " ] && [ "$(csvval "$csv" 2 kd_cpu_s)" = NA ] && [ "$(csvval "$csv" 2 s_req_p1)" = NA ] && [ "$(csvval "$csv" 2 ls_nr_lru_sorted_hot_regions)" = NA ] && [ "$(csvval "$csv" 2 damon_inactive)" = NA ]; echo $?)"
check "off: cgroup deltas present" "$(csveq "$csv" 2 cg_pgscan 200; echo $?)"

t=$TMP/inactive; mk_tree "$t"
drive "$t" "damon" SB_CACHESTAT=/nonexistent ZERO_LRU=1
check "damon with zero applied regions: damon_inactive=1, warning, run still ok" "$([ "$RC" = 0 ] && [ "$(csvval "$t/out/runs.csv" 1 damon_inactive)" = 1 ] && errhas "$t" 'damon_inactive=1'; echo $?)" "rc=$RC"

# ---------------------------------------------------------------------------
# 3. cachestat
# ---------------------------------------------------------------------------
cat > "$TMP/fake_cachestat" <<'EOF'
#!/bin/bash
echo $$ > "$CS_PIDFILE"
echo "TIME HITS MISSES DIRTIES RATIO BUFFERS_MB CACHED_MB"
while :; do printf '%s 90 10 0 90.0%% 1 2\n' "$(date +%H:%M:%S)"; sleep 0.5; done
EOF
chmod +x "$TMP/fake_cachestat"
cat > "$TMP/dead_cachestat" <<'EOF'
#!/bin/bash
echo "cannot attach kprobe" >&2
exit 1
EOF
chmod +x "$TMP/dead_cachestat"

t=$TMP/cs; mk_tree "$t"
drive "$t" "off" SB_CACHESTAT="$TMP/fake_cachestat" CS_PIDFILE="$t/cs.pid" WL_SLEEP=2.2
csv=$t/out/runs.csv
check "cachestat: run ok, restored" "$([ "$RC" = 0 ] && restored_ok "$t"; echo $?)" "rc=$RC $(tail -4 "$t/err")"
check "cachestat: output kept as cachestat_1.txt" "$(grep -q '^TIME ' "$t/out/cachestat_1.txt" && [ "$(wc -l < "$t/out/cachestat_1.txt")" -ge 3 ]; echo $?)" "$(cat "$t/out/cachestat_1.txt")"
check "cachestat: hit rate from lines between pre and post (90%)" "$(csveq "$csv" 1 cachestat_hit_pct 90; echo $?)" "$(csvval "$csv" 1 cachestat_hit_pct)"
check "cachestat: process ended after post and CACHESTAT_PID cleared" "$(! kill -0 "$(cat "$t/cs.pid")" 2>/dev/null && grep -q 'CACHESTAT_PID= ' "$t/dump"; echo $?)" "$(cat "$t/dump")"

# 실행 중 실패하면 restore가 cachestat를 끝낸다(CACHESTAT_PID 추적)
t=$TMP/cs_fail; mk_tree "$t"
drive "$t" "off" SB_CACHESTAT="$TMP/fake_cachestat" CS_PIDFILE="$t/cs.pid" FAIL_PRE=1
check "failure after cachestat start: rc 1, cachestat killed by restore, restore verified" "$([ "$RC" = 1 ] && [ -s "$t/cs.pid" ] && ! kill -0 "$(cat "$t/cs.pid")" 2>/dev/null && restored_ok "$t"; echo $?)" "rc=$RC $(tail -3 "$t/err")"

# 띄우자마자 죽는 cachestat: 경고만 하고 실행은 계속, NA
t=$TMP/cs_dead; mk_tree "$t"
drive "$t" "off off" SB_CACHESTAT="$TMP/dead_cachestat"
check "cachestat dies at start: warning, NA, run continues (not retried)" "$([ "$RC" = 0 ] && errhas "$t" 'cachestat_hit_pct = NA from here on' && [ "$(csvval "$t/out/runs.csv" 1 cachestat_hit_pct)" = NA ] && [ "$(csvval "$t/out/runs.csv" 2 cachestat_hit_pct)" = NA ] && [ "$(grep -c 'exited at start' "$t/err")" = 1 ]; echo $?)" "rc=$RC $(cat "$t/err")"

# ---------------------------------------------------------------------------
# 4. 워크로드 종료 코드, loop, 실패 경로
# ---------------------------------------------------------------------------
t=$TMP/fiorc; mk_tree "$t"
drive "$t" "off" SB_CACHESTAT=/nonexistent WL_RC=3
check "workload rc 3: row written with fio_rc=3 and a warning, run ok" "$([ "$RC" = 0 ] && [ "$(csvval "$t/out/runs.csv" 1 fio_rc)" = 3 ] && errhas "$t" 'workload exit code 3'; echo $?)" "rc=$RC"

t=$TMP/loop2; mk_tree "$t"
drive "$t" "off" SB_CACHESTAT=/nonexistent WLN=loop LOOP_PASSES=2
check "loop with 2 completed passes: loop_passes=2, bandwidth, valid" "$([ "$RC" = 0 ] && [ "$(csvval "$t/out/runs.csv" 1 loop_passes)" = 2 ] && csveq "$t/out/runs.csv" 1 loop_bw_mib 1.0 && [ "$(csvval "$t/out/runs.csv" 1 loop_invalid)" = 0 ]; echo $?)" "rc=$RC $(tail -1 "$t/out/runs.csv")"
t=$TMP/loop1; mk_tree "$t"
drive "$t" "off" SB_CACHESTAT=/nonexistent WLN=loop LOOP_PASSES=1
check "loop with 1 completed pass: loop_invalid=1 and a warning" "$([ "$RC" = 0 ] && [ "$(csvval "$t/out/runs.csv" 1 loop_passes)" = 1 ] && [ "$(csvval "$t/out/runs.csv" 1 loop_invalid)" = 1 ] && errhas "$t" 'loop_invalid=1'; echo $?)" "rc=$RC"

t=$TMP/badrow; mk_tree "$t"
drive "$t" "off off" SB_CACHESTAT=/nonexistent BAD_STATE=1
check "row failure: BENCH RUN FAIL csv_row, rc 1, no runs.csv, restore verified" "$([ "$RC" = 1 ] && errhas "$t" 'BENCH RUN FAIL csv_row:' && [ ! -e "$t/out/runs.csv" ] && restored_ok "$t"; echo $?)" "rc=$RC $(tail -4 "$t/err")"

# ---------------------------------------------------------------------------
# 5. 드라이런: sysfs·cgroup·cachestat 없이 /proc 스냅샷과 CSV 행만
# ---------------------------------------------------------------------------
t=$TMP/dry; mk_tree "$t"
snap_before=$(cd "$t" && find kd parm lrup cg dbg lrugen -type f -print0 | sort -z | xargs -0 cat | md5sum)
drive "$t" "samon_all damon" DRYMODE=1 SB_CACHESTAT="$TMP/fake_cachestat" CS_PIDFILE="$t/cs.pid"
snap_after=$(cd "$t" && find kd parm lrup cg dbg lrugen -type f -print0 | sort -z | xargs -0 cat | md5sum)
csv=$t/out/runs.csv
check "dry run: rc 0, 2 rows" "$([ "$RC" = 0 ] && [ "$(wc -l < "$csv")" = 3 ]; echo $?)" "rc=$RC $(cat "$t/err")"
check "dry run: sysfs/cgroup/LRU_SORT trees unchanged, no cgroup, cachestat not started" "$([ "$snap_before" = "$snap_after" ] && [ ! -d "$t/cg/samon_bench" ] && [ ! -e "$t/cs.pid" ] && [ ! -e "$t/out/cachestat_1.txt" ]; echo $?)"
check "dry run: snapshot has only /proc files" "$([ "$(files_of "$t/out/snap_1_pre")" = "meminfo stat ts vmstat " ]; echo $?)" "$(files_of "$t/out/snap_1_pre")"
check "dry run: /proc deltas recorded, cgroup/SAMON/LRU_SORT/cachestat columns NA" "$(csveq "$csv" 1 pgpgin_kib 8192 && [ "$(csvval "$csv" 1 cg_pgscan)" = NA ] && [ "$(csvval "$csv" 1 s_req_p1)" = NA ] && [ "$(csvval "$csv" 2 ls_nr_lru_sorted_hot_regions)" = NA ] && [ "$(csvval "$csv" 1 kd_cpu_s)" = NA ] && [ "$(csvval "$csv" 1 cachestat_hit_pct)" = NA ] && [ "$(csvval "$csv" 1 samon_kd_state)" = NA ]; echo $?)" "$(tail -2 "$csv")"
check "dry run: CSV header and rows have the same number of columns" "$([ "$(awk -F, '{print NF}' "$csv" | sort -u | wc -l)" = 1 ]; echo $?)"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
