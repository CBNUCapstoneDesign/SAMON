#!/bin/bash
# samon_bench.sh restore() 시험 (tasks 24.3). 가짜 sysfs 트리만 쓴다. root도 sudo도 필요 없다.
#   usage: bash bench/tests/test_samon_bench_restore.sh
# 각 시나리오는 samon_bench.sh를 source한 작은 driver를 별도 프로세스로 돌려
# 실제 EXIT/INT/TERM trap 경로를 거친다.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BENCH=$(cd "$HERE/.." && pwd)/samon_bench.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || echo "     $2"; }
check() { # name, condition result (0 = pass), detail
	if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

mk_tree() { # dir
	local t=$1 f
	mkdir -p "$t/kd/0" "$t/parm" "$t/lrup" "$t/cg" "$t/dbg"
	echo 1 > "$t/kd/nr_kdamonds"
	echo off > "$t/kd/0/state"
	for f in samon_act_p1 samon_act_p2 samon_act_p3 samon_act_p4 samon_dbg_lba samon_dev_major samon_dev_minor; do
		echo 0 > "$t/parm/$f"
	done
	echo 1 > "$t/parm/samon_dbg_lba"
	echo Y > "$t/parm/samon_opt_b"
	echo N > "$t/lrup/enabled"
	echo 1000 > "$t/lrup/wmarks_high"
	echo 999 > "$t/lrup/wmarks_mid"
	echo 0 > "$t/lrup/wmarks_low"
	echo 120000000 > "$t/lrup/cold_min_age"
	echo "-1" > "$t/lrup/kdamond_pid"; chmod 444 "$t/lrup/kdamond_pid"
	echo 0 > "$t/lrup/nr_lru_sorted_hot_regions"; chmod 444 "$t/lrup/nr_lru_sorted_hot_regions"
	echo N > "$t/lrup/commit_inputs"
	echo 0x0007 > "$t/lrugen"
	echo "q_cap=1024" > "$t/dbg/stats"
}

# driver: restore를 걸고 상태를 바꾼 뒤 시나리오대로 끝난다.
cat > "$TMP/driver.sh" <<'EOF'
#!/bin/bash
# usage: driver.sh MODE   (환경 변수 T = 가짜 트리 루트)
MODE=$1
export SB_KD=$T/kd SB_PARM=$T/parm SB_LRUP=$T/lrup SB_LRUGEN=$T/lrugen SB_DBG=$T/dbg SB_CGROOT=$T/cg
export SB_RESTORE_WAIT=${SB_RESTORE_WAIT:-1}
# shellcheck disable=SC1090
. "$BENCH"
DRY=0
[ "$MODE" != dry ] || DRY=1
if [ "$DRY" = 0 ]; then read_saved_state || { echo "save failed: $SAVE_ERR"; exit 99; }; fi
install_traps

# 실행 중 바뀌는 상태 흉내
[ "$MODE" = partial ] || {
	echo on > "$SB_KD/0/state"; SAMON_KD_STARTED=1
	echo 1 > "$SB_PARM/samon_act_p1"; echo 1 > "$SB_PARM/samon_act_p4"
	echo N > "$SB_PARM/samon_opt_b"; echo 0 > "$SB_PARM/samon_dbg_lba"
	echo 8 > "$SB_PARM/samon_dev_major"; echo 16 > "$SB_PARM/samon_dev_minor"
	echo Y > "$SB_LRUP/enabled"; echo 5 > "$SB_LRUP/wmarks_low"; echo 3 > "$SB_LRUP/cold_min_age"
	echo 7 > "$SB_LRUP/commit_inputs"      # 저장·복원 대상이 아니다
	echo 0 > "$SB_LRUGEN"
	mkdir -p "$CG"
	sleep 4321 & CACHESTAT_PID=$!
	echo "$CACHESTAT_PID" > "$T/cachestat.pid"
}
case $MODE in
stepfail)  echo 998 > "$SB_LRUP/wmarks_mid"; chmod 444 "$SB_LRUP/wmarks_mid" ;;   # restore가 쓸 수 없다
cgfail)    echo 0 > "$CG/cgroup.kill" ;;                # 가짜 트리라 rmdir이 안 된다
esac
echo ready > "$T/ready"
case $MODE in
exit0|dry|partial|stepfail|cgfail) exit 0 ;;
exit3) exit 3 ;;
err)   false; exit $? ;;
int|term) sleep 4321 & wait ;;   # 시그널을 기다린다
esac
EOF

run_driver() { # tree, mode -> rc in $RC, stderr in $TMP/err
	T=$1 BENCH=$BENCH bash "$TMP/driver.sh" "$2" 2> "$TMP/err"
	RC=$?
}

snap() { # tree -> 비교용 문자열
	local t=$1
	{
		cat "$t/kd/0/state" "$t/lrugen" "$t/lrup/enabled" "$t/lrup/wmarks_high" "$t/lrup/wmarks_mid" \
			"$t/lrup/wmarks_low" "$t/lrup/cold_min_age" "$t/parm"/*
		[ -d "$t/cg/samon_bench" ] && echo CGROUP_EXISTS
	} 2>&1
}

alive() { kill -0 "$1" 2>/dev/null; }

for mode in exit0 exit3 err; do
	t=$TMP/t_$mode; mk_tree "$t"; before=$(snap "$t")
	run_driver "$t" $mode
	exp=0; [ $mode = exit3 ] && exp=3; [ $mode = err ] && exp=1
	check "$mode: exit code $exp preserved" "$([ "$RC" = $exp ]; echo $?)" "rc=$RC"
	check "$mode: state restored" "$([ "$(snap "$t")" = "$before" ]; echo $?)"
	check "$mode: opt_b written back as Y" "$([ "$(cat "$t/parm/samon_opt_b")" = Y ]; echo $?)"
	check "$mode: commit_inputs left alone" "$([ "$(cat "$t/lrup/commit_inputs")" = 7 ]; echo $?)"
	check "$mode: lru_sort.enabled N" "$([ "$(cat "$t/lrup/enabled")" = N ]; echo $?)"
	check "$mode: cachestat killed" "$(! alive "$(cat "$t/cachestat.pid")"; echo $?)"
	check "$mode: last line says no mismatch" "$([ "$(tail -1 "$TMP/err")" = "bench: restore verified: no mismatch" ]; echo $?)" "$(tail -1 "$TMP/err")"
done

# SIGINT / SIGTERM mid-run
for sig in INT TERM; do
	t=$TMP/t_sig$sig; mk_tree "$t"; before=$(snap "$t")
	set -m		# 비대화형 셸의 백그라운드 작업은 SIGINT를 무시한 채 시작하므로 작업 제어를 켠다
	T=$t BENCH=$BENCH bash "$TMP/driver.sh" "$(echo $sig | tr A-Z a-z)" 2> "$TMP/err" &
	dpid=$!
	set +m
	for _ in $(seq 50); do [ -e "$t/ready" ] && break; sleep 0.1; done
	kill -$sig "$dpid"; wait "$dpid"; RC=$?
	exp=130; [ $sig = TERM ] && exp=143
	check "SIG$sig: exit code $exp" "$([ "$RC" = $exp ]; echo $?)" "rc=$RC"
	check "SIG$sig: state restored" "$([ "$(snap "$t")" = "$before" ]; echo $?)"
	check "SIG$sig: cachestat killed" "$(! alive "$(cat "$t/cachestat.pid")"; echo $?)"
	pkill -f "sleep 4321" 2>/dev/null
done

# restore 단계 하나가 실패(쓰기 불가 파일): 나머지는 복원되고, 불일치 이름을 내고, 0이 아닌 종료
if [ "$(id -u)" = 0 ]; then
	echo "skip stepfail (root ignores file modes)"
else
	t=$TMP/t_stepfail; mk_tree "$t"
	run_driver "$t" stepfail
	check "stepfail: nonzero exit (1)" "$([ "$RC" = 1 ]; echo $?)" "rc=$RC"
	check "stepfail: names lru_sort.wmarks_mid" "$(grep -q 'MISMATCH lru_sort.wmarks_mid' "$TMP/err"; echo $?)"
	check "stepfail: FAIL line is last" "$([ "$(tail -1 "$TMP/err" | grep -c 'RESTORE FAIL: 1 item')" = 1 ]; echo $?)" "$(tail -1 "$TMP/err")"
	check "stepfail: later steps still ran (lru_gen)" "$([ "$(cat "$t/lrugen")" = 0x0007 ]; echo $?)"
	check "stepfail: later steps still ran (samon_opt_b)" "$([ "$(cat "$t/parm/samon_opt_b")" = Y ]; echo $?)"
	check "stepfail: kdamond off" "$([ "$(cat "$t/kd/0/state")" = off ]; echo $?)"
	pkill -f "sleep 4321" 2>/dev/null
fi

# cgroup을 지울 수 없을 때(가짜 트리의 cgroup.kill 파일): cgroup.kill에 1을 쓰고, cgroup 불일치를 보고
t=$TMP/t_cgfail; mk_tree "$t"
run_driver "$t" cgfail
check "cgfail: cgroup.kill got 1" "$([ "$(cat "$t/cg/samon_bench/cgroup.kill")" = 1 ]; echo $?)"
check "cgfail: names cgroup" "$(grep -q 'MISMATCH cgroup:' "$TMP/err"; echo $?)"
check "cgfail: nonzero exit" "$([ "$RC" = 1 ]; echo $?)" "rc=$RC"
check "cgfail: rest restored (lru_gen)" "$([ "$(cat "$t/lrugen")" = 0x0007 ]; echo $?)"
pkill -f "sleep 4321" 2>/dev/null

# 부분 설정(아무것도 시작하지 않음): 아무것도 건드리지 않고 정상 종료
t=$TMP/t_partial; mk_tree "$t"; before=$(snap "$t")
run_driver "$t" partial
check "partial: rc 0" "$([ "$RC" = 0 ]; echo $?)" "rc=$RC"
check "partial: nothing changed" "$([ "$(snap "$t")" = "$before" ]; echo $?)"
# kdamond 디렉터리가 아예 없는 경우
t=$TMP/t_partial2; mk_tree "$t"; rm -rf "$t/kd/0"
run_driver "$t" partial
check "partial: no kdamond dir -> rc 0" "$([ "$RC" = 0 ]; echo $?)" "rc=$RC"

# -D 드라이런: 복원하지 않고 아무것도 읽거나 쓰지 않는다
t=$TMP/t_dry; mk_tree "$t"
cat > "$TMP/dry_driver.sh" <<'EOF'
export SB_KD=$T/kd SB_PARM=$T/parm SB_LRUP=$T/lrup SB_LRUGEN=$T/lrugen SB_CGROOT=$T/cg
. "$BENCH"
DRY=1
install_traps
echo changed > "$SB_LRUGEN"; echo on > "$SB_KD/0/state"
exit 0
EOF
T=$t BENCH=$BENCH bash "$TMP/dry_driver.sh" 2> "$TMP/err"; RC=$?
check "dry: rc 0" "$([ "$RC" = 0 ]; echo $?)" "rc=$RC"
check "dry: no restore (values stay as changed)" "$([ "$(cat "$t/lrugen")" = changed ] && [ "$(cat "$t/kd/0/state")" = on ]; echo $?)"
check "dry: restore prints nothing" "$([ ! -s "$TMP/err" ]; echo $?)" "$(cat "$TMP/err")"

# 멱등: restore_state를 두 번 불러도 두 번째는 아무것도 쓰지 않는다
t=$TMP/t_idem; mk_tree "$t"
cat > "$TMP/idem_driver.sh" <<'EOF'
export SB_KD=$T/kd SB_PARM=$T/parm SB_LRUP=$T/lrup SB_LRUGEN=$T/lrugen SB_CGROOT=$T/cg SB_RESTORE_WAIT=1
. "$BENCH"
read_saved_state || exit 99
echo on > "$SB_KD/0/state"; echo 1 > "$SB_PARM/samon_act_p2"; echo 0 > "$SB_LRUGEN"; echo 5 > "$SB_LRUP/wmarks_low"
restore_state 2>/dev/null || exit 10
WRITES=0
rwrite() { WRITES=$((WRITES + 1)); { printf '%s\n' "$2" > "$1"; } 2>/dev/null; }
restore_state 2>/dev/null || exit 11
[ "$WRITES" = 0 ] || exit 12
exit 0
EOF
T=$t BENCH=$BENCH bash "$TMP/idem_driver.sh"; RC=$?
check "idempotent: second restore_state writes nothing, rc 0" "$([ "$RC" = 0 ]; echo $?)" "rc=$RC (10/11 restore failed, 12 second run wrote)"

# 값 비교: 0x0007 == 7, Y != N
cat > "$TMP/cmp_driver.sh" <<'EOF'
. "$BENCH"
vals_equal 0x0007 7 && vals_equal 007 7 && vals_equal -1 -1 && ! vals_equal Y N && ! vals_equal 0x0007 0 && ! vals_equal "" 0
EOF
BENCH=$BENCH bash "$TMP/cmp_driver.sh"
check "vals_equal: hex/decimal/Y-N" "$?"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
