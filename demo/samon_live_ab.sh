#!/bin/bash
# samon_live_ab.sh — 시연용: mixed 워크로드를 MGLRU(SAMON 끔)와 SAMON(켬)으로 번갈아 계속 돌리며
#                    실행마다 refault/s 와 SAMON 패턴 판정 수를 CSV 에 쌓는다. (시연 도구, 측정 하네스 아님)
#
# 조건은 2026-10-28 측정(kernel/README.md "측정 결과")과 같다:
#   mixed 워크로드(hot 1GiB zipf 4KiB randrw + 2GiB 순차 scan), 측정 40초 + ramp 10초, memory.max 512M,
#   SAMON 권장값 samon_loop_protect_mem_pct=25, samon_p2_mode=2, samon_classifier=1, 토글 P1~P4 on (samon_all).
#
# usage: sudo bash demo/samon_live_ab.sh [-d DIR] [-m MEM] [-t SECS] [-r RAMP] [-n CYCLES] [-c CPU%] [-o CSV]
#   -d DIR     작업 파일 위치. 없으면 만든다. 기본: /mnt/samon_bench/work 가 있으면 그곳, 없으면 /var/tmp/samon_live_work
#              hot.dat(1GiB)·scan.dat(2GiB) 가 없으면 처음 실행 때 만든다 (여유 공간 4GiB 이상 필요, tmpfs 불가)
#   -m MEM     cgroup memory.max (기본 512M)
#   -t SECS    측정 초 (기본 40)      -r RAMP  ramp 초 (기본 10)
#   -n CYCLES  사이클 수, 0 = Ctrl-C 까지 계속 (기본 0). 사이클 1개 = MGLRU 1회 + SAMON 1회
#   -c CPU%    stress-ng 로 CPU 부하를 함께 건다 (10/28 의 0/50/100 조건, 기본 0 = 안 함)
#   -o CSV     결과 CSV (기본 /var/tmp/samon_live/cycles.csv, 이미 있으면 이어서 쓴다)
# 화면: 다른 터미널에서 sudo python3 demo/samon_live_score.py  (또는 demo/samon_live_demo.sh 로 둘 다)
#
# 바꾸는 것: kdamond 0 (saddr, target region = 대상 디스크 전체), monitoring_attrs, saddr 파라미터,
#            DAMON_LRU_SORT enabled=N, cgroup samon_live. 끝나면(Ctrl-C 포함) kdamond 상태와 saddr 파라미터,
#            LRU_SORT enabled 를 시작 값으로 되돌리고 cgroup 을 지운다. target region 은 그대로 둔다.
# 순서: 홀수 사이클은 MGLRU→SAMON, 짝수 사이클은 SAMON→MGLRU (순서 효과를 상쇄).
set -u
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 2
REPO=$PWD

DIR=""; MEM=512M; SECS=40; RAMP=10; CYCLES=0; CPU=0
OUT=/var/tmp/samon_live/cycles.csv
while getopts "d:m:t:r:n:c:o:h" o; do
	case $o in
	d) DIR=$OPTARG ;; m) MEM=$OPTARG ;; t) SECS=$OPTARG ;; r) RAMP=$OPTARG ;;
	n) CYCLES=$OPTARG ;; c) CPU=$OPTARG ;; o) OUT=$OPTARG ;;
	*) sed -n '2,24p' "$0"; exit 2 ;;
	esac
done
[ "$(id -u)" = 0 ] || { echo "root 로 실행: sudo bash $0"; exit 2; }

KD=/sys/kernel/mm/damon/admin/kdamonds
PARM=/sys/module/saddr/parameters
LRUP=/sys/module/damon_lru_sort/parameters
DBG=/sys/kernel/debug/samon
CG=/sys/fs/cgroup/samon_live
PHASE_DIR=/run/samon_demo; PHASE_FILE=$PHASE_DIR/phase
WORK=$(dirname "$OUT")
log() { echo "[$(date +%T)] $*"; }
phase() { mkdir -p "$PHASE_DIR" 2>/dev/null && printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s.%N)" > "$PHASE_FILE.tmp" && mv -f "$PHASE_FILE.tmp" "$PHASE_FILE"; }
die() { echo "FATAL: $*" >&2; phase "오류" "$*  (아래 칸 메시지 확인)"; rm -f "$PHASE_DIR/runner.pid"; exit 2; }

# shellcheck source=/dev/null
. "$REPO/bench/samon_workloads.sh" || die "bench/samon_workloads.sh 를 읽지 못함"
mkdir -p "$WORK" "$PHASE_DIR" && chmod 755 "$PHASE_DIR" || die "cannot create $WORK / $PHASE_DIR"
echo $$ > "$PHASE_DIR/runner.pid"     # 화면(samon_live_score.py)이 실행기가 살아 있는지 확인하는 데 쓴다
if [ -z "$DIR" ]; then
	DIR=/var/tmp/samon_live_work; [ -d /mnt/samon_bench/work ] && DIR=/mnt/samon_bench/work
fi
mkdir -p "$DIR" || die "작업 디렉터리를 만들 수 없음: $DIR"
[ "$(findmnt -no FSTYPE --target "$DIR")" != tmpfs ] || die "$DIR 는 tmpfs(메모리)라 쓸 수 없음. 디스크 위 경로를 -d 로 지정"
need=0
for f in "hot.dat 1073741824" "scan.dat 2147483648"; do
	set -- $f
	[ "$(stat -c %s "$DIR/$1" 2>/dev/null || echo 0)" -ge "$2" ] || need=$((need + $2))
done
if [ "$need" -gt 0 ]; then
	avail=$(( $(df --output=avail -B1 "$DIR" | tail -1) ))
	[ "$avail" -ge $((need + 1073741824)) ] ||
		die "여유 공간 부족: $DIR 에 $((need / 1048576))MiB 를 만들어야 하는데 여유 $((avail / 1048576))MiB (1GiB 여유 포함 필요)"
	phase "준비" "작업 파일 생성 중 ($((need / 1048576))MiB, 처음 한 번만) — $DIR"
	for f in "hot.dat 1G 1073741824" "scan.dat 2G 2147483648"; do
		set -- $f
		[ "$(stat -c %s "$DIR/$1" 2>/dev/null || echo 0)" -ge "$3" ] && continue
		log "준비: $DIR/$1 ($2) 생성"; rm -f "$DIR/$1"
		swl_prefill_file "$DIR/$1" "$2" || die "작업 파일 생성 실패: $DIR/$1"
	done
fi

# 대상 디스크 (DIR 이 있는 파티션의 상위 디스크)
src=$(findmnt -no SOURCE --target "$DIR") || die "findmnt 실패"
DISK=$(lsblk -no PKNAME "$src" | head -1); [ -n "$DISK" ] || DISK=$(basename "$src")
read -r DMAJ DMIN < <(tr ':' ' ' < "/sys/class/block/$DISK/dev")
DSIZE=$(cat "/sys/class/block/$DISK/size")

# ---------------------------------------------------------------- 상태 저장과 복원
PNAMES="samon_act_p1 samon_act_p2 samon_act_p3 samon_act_p4 samon_opt_b samon_dbg_lba samon_dev_major samon_dev_minor
        samon_q_len samon_loop_protect_mem_pct samon_p2_mode samon_classifier"
declare -A SAVED
for p in $PNAMES; do SAVED[$p]=$(cat "$PARM/$p"); done
SAVED_KD=$(cat "$KD/0/state" 2>/dev/null || echo off)
SAVED_LS=$(cat "$LRUP/enabled")
STRESS_PID=""
restore() {
	trap - EXIT INT TERM
	log "정리: 시작 상태로 되돌림"
	[ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null
	[ -d "$CG" ] && { for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; sleep 1; rmdir "$CG" 2>/dev/null; }
	echo off > "$KD/0/state" 2>/dev/null; sleep 1
	for p in $PNAMES; do echo "${SAVED[$p]}" > "$PARM/$p" 2>/dev/null; done
	[ "$SAVED_KD" = on ] && echo on > "$KD/0/state" 2>/dev/null
	echo "$SAVED_LS" > "$LRUP/enabled" 2>/dev/null
	phase "종료" "시연 끝 (실행기 종료)"; rm -f "$PHASE_DIR/runner.pid"
	exit 0
}
trap restore EXIT INT TERM

setp() { echo "$2" > "$PARM/$1" 2>/dev/null; local g; g=$(cat "$PARM/$1"); case "$g" in "$2"|Y|N) ;; *) die "$1: wrote $2, read $g" ;; esac; }
wait_kd() { for _ in $(seq 1 50); do [ "$(cat "$KD/0/state")" = "$1" ] && return 0; sleep 0.2; done; return 1; }

# ---------------------------------------------------------------- SAMON 준비 (10/28 권장값)
echo off > "$KD/0/state" 2>/dev/null; wait_kd off || die "kdamond 가 꺼지지 않음"
echo N > "$LRUP/enabled"
[ "$(cat "$KD/nr_kdamonds")" = 1 ] || echo 1 > "$KD/nr_kdamonds"
C=$KD/0/contexts
[ "$(cat "$C/nr_contexts")" = 1 ] || echo 1 > "$C/nr_contexts"
[ "$(cat "$C/0/operations")" = saddr ] || echo saddr > "$C/0/operations"
[ "$(cat "$C/0/targets/nr_targets")" = 1 ] || echo 1 > "$C/0/targets/nr_targets"
R=$C/0/targets/0/regions
echo 1 > "$R/nr_regions"; echo 0 > "$R/0/start"; echo "$DSIZE" > "$R/0/end"     # region 비면 classifier=1 이 아무것도 판정 못함
[ "$(cat "$R/0/end")" = "$DSIZE" ] || die "DAMON target region 설정 실패"
A=$C/0/monitoring_attrs/intervals
echo 5000 > "$A/sample_us"; echo 100000 > "$A/aggr_us"; echo 1000000 > "$A/update_us"
setp samon_q_len 8192; setp samon_loop_protect_mem_pct 25; setp samon_p2_mode 2; setp samon_classifier 1
setp samon_dbg_lba 0; setp samon_dev_major "$DMAJ"; setp samon_dev_minor "$DMIN"
for i in 1 2 3 4; do setp "samon_act_p$i" 1; done; setp samon_opt_b 0
log "작업 디렉터리 $DIR, 대상 디스크 $DISK ($DMAJ:$DMIN, region 0-$DSIZE), memory.max=$MEM, ${RAMP}s ramp + ${SECS}s 측정"

if [ "$CPU" -gt 0 ] 2>/dev/null; then
	stress-ng --cpu "$(nproc)" --cpu-load "$CPU" --quiet & STRESS_PID=$!
	log "CPU 부하 ${CPU}% (stress-ng pid $STRESS_PID)"
fi

JOB=$WORK/mixed.fio
swl_jobfile mixed "$DIR" "$SECS" "$RAMP" > "$JOB" || die "fio job 생성 실패"
[ -s "$OUT" ] || echo "cycle,mode,start_epoch,measure_s,refault,refault_per_s,hot_r_iops,scan_mib_s,det_p1,det_p2,det_p3,det_p4,exec_p1,exec_p2,exec_p3,exec_p4,q_drop,mem,cpu_pct,fio_tail_s" > "$OUT"
CYC=$(( $(tail -n +2 "$OUT" | cut -d, -f1 | sort -n | tail -1 | tr -dc 0-9) + 0 ))

stat_get() { awk -F= -v k="$1" '$1 == k { print $2 + 0 }' "$DBG/stats"; }
cg_refault() { awk '$1 == "workingset_refault_file" { print $2 }' "$CG/memory.stat"; }
samon_snap() { local s=""; for k in det_p1 det_p2 det_p3 det_p4 exec_p1 exec_p2 exec_p3 exec_p4 drop_queue_p1 drop_queue_p2 drop_queue_p3 drop_queue_p4; do s="$s $(stat_get $k)"; done; echo "$s"; }

run_one() {	# $1 = off | samon
	local mode=$1 name desc t0 t1 r0 r1 s0 s1 json i
	if [ "$mode" = samon ]; then name="SAMON"; desc="SAMON 켬 (권장값: P3 상한 25%, P2 mark_accessed) · 사이클 $CYC"
	else name="MGLRU"; desc="SAMON 끔 (plain MGLRU) · 사이클 $CYC"; fi
	# cgroup 새로 만들기, 캐시 비우기
	if [ -d "$CG" ]; then for p in $(cat "$CG/cgroup.procs"); do kill -9 "$p" 2>/dev/null; done; sleep 0.5; rmdir "$CG"; fi
	mkdir "$CG" && echo "$MEM" > "$CG/memory.max" && echo 0 > "$CG/memory.swap.max" || die "cgroup 생성 실패"
	sync; echo 3 > /proc/sys/vm/drop_caches
	if [ "$mode" = samon ]; then
		echo on > "$KD/0/state"; wait_kd on || die "kdamond 가 켜지지 않음"
		for _ in $(seq 1 25); do [ "$(stat_get q_cap)" -gt 0 ] 2>/dev/null && break; sleep 0.2; done
	fi
	printf '%s\t%s\t%s\n' "$name" "$desc" "$(date +%s.%N)" > "$PHASE_FILE.tmp" && mv -f "$PHASE_FILE.tmp" "$PHASE_FILE"
	json=$WORK/last_$mode.json
	bash -c 'echo $$ > "$1/cgroup.procs" && exec fio "$2" --output-format=json --output="$3"' _ "$CG" "$JOB" "$json" &
	local fpid=$!
	sleep "$RAMP"
	t0=$(date +%s.%N); r0=$(cg_refault); s0=$(samon_snap)
	# 측정 구간은 ramp 뒤 정확히 SECS 초로 고정한다 (fio 가 끝나는 시점은 모드마다 달라 구간 길이가 달라지므로)
	sleep "$SECS"
	t1=$(date +%s.%N); r1=$(cg_refault); s1=$(samon_snap)
	local tw=$(date +%s)
	wait "$fpid"; local rc=$?
	local tail_s=$(( $(date +%s) - tw ))
	[ "$mode" = samon ] && { echo off > "$KD/0/state"; wait_kd off; }
	[ "$rc" = 0 ] || { log "fio rc=$rc ($mode) — 이 실행은 기록하지 않음"; return 0; }
	python3 - "$json" "$OUT" "$CYC" "$mode" "$t0" "$t1" "$r0" "$r1" "$s0" "$s1" "$MEM" "$CPU" "$tail_s" <<'PY'
import json, sys
js, out, cyc, mode, t0, t1, r0, r1, s0, s1, mem, cpu, tail_s = sys.argv[1:]
d = json.load(open(js)); jobs = {j["jobname"]: j for j in d["jobs"]}
hot = jobs.get("hot", {}).get("read", {}).get("iops", 0.0)
scan = jobs.get("scan", {}).get("read", {}).get("bw", 0) / 1024.0      # KiB/s -> MiB/s
dt = float(t1) - float(t0); rf = int(r1) - int(r0)
a = [int(x) for x in s0.split()]; b = [int(x) for x in s1.split()]; dd = [y - x for x, y in zip(a, b)]
row = [cyc, mode, f"{float(t0):.0f}", f"{dt:.2f}", rf, f"{rf / dt:.1f}", f"{hot:.0f}", f"{scan:.0f}"] + dd[:8] + [sum(dd[8:]), mem, cpu, tail_s]
open(out, "a").write(",".join(map(str, row)) + "\n")
print(f"  {mode:5s}: refault/s={rf / dt:8.1f}  hot read IOPS={hot:8.0f}  scan={scan:6.0f} MiB/s  det P1..P4={dd[:4]}  (fio 마무리 {tail_s}s)")
PY
}

log "시작: 결과 → $OUT (Ctrl-C 로 끝냄)"
START=$CYC
while :; do
	CYC=$((CYC + 1))
	log "사이클 $CYC"
	if [ $((CYC % 2)) = 1 ]; then run_one off; run_one samon; else run_one samon; run_one off; fi
	[ "$CYCLES" != 0 ] && [ $((CYC - START)) -ge "$CYCLES" ] && break
done
