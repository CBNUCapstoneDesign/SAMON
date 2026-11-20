#!/bin/bash
# remeasure_1120.sh — 재측정 큐 (11/20 계획): trace → s1_rec → s2_def → s3_cls0
#
# usage: sudo bash overnight/remeasure_1120.sh [all|trace|stages]
#   tmux: sudo tmux new-session -d -s samon "bash overnight/remeasure_1120.sh 2>&1 | tee -a bench/results/results_remeasure_1120/queue.log"
# 파일럿은 따로: sudo bash overnight/run_stage.sh -s pilot -d /mnt/samon_bench/work -n 1 -B 1 --mem-pct 25 --p2-mode 2
#
# trace: SAMON·LRU_SORT 꺼진 상태(MGLRU)에서 워크로드별 1회, 성능 측정과 분리.
#        이벤트 유실(INVALID lost_events)이면 버퍼를 키워 한 번 더(<W>_rb4096). 그래도 실패하면 기록만 하고 계속.
# stages: 블록 5회 x 2, 측정 60초, ramp 10초, memory.max 512M. 이미 있는 단계는 건너뜀(덮어쓰지 않음).
set -u
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 2
REPO=$PWD
SUB=results_remeasure_1120
BASE=$REPO/bench/results/$SUB
D=/mnt/samon_bench/work
WHAT=${1:-all}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
mkdir -p "$BASE"
echo "##### queue start $(date '+%F %T') what=$WHAT #####"

capture() {	# workload out rb_pages
	BPFTRACE_PERF_RB_PAGES=$3 bash bench/samon_s0_capture.sh -w "$1" -d "$D" -m 512M -t 60 -r 10 -o "$2" 2>&1 | tail -3
	return "${PIPESTATUS[0]}"
}
if [ "$WHAT" = all ] || [ "$WHAT" = trace ]; then
	for W in reread loop seqwrite mixed; do
		OUT=$BASE/trace/$W
		if [ -e "$OUT" ]; then echo "--- trace $W: exists, skip ---"; continue; fi
		echo "--- trace $W start $(date '+%F %T') ---"
		capture "$W" "$OUT" 1024; rc=$?
		if [ "$rc" = 1 ] && grep -q "lost=[1-9]" "$OUT/capture.txt" 2>/dev/null; then
			echo "--- trace $W lost events → retry with BPFTRACE_PERF_RB_PAGES=4096 ---"
			capture "$W" "${OUT}_rb4096" 4096; rc=$?
		fi
		echo "--- trace $W end rc=$rc $(date '+%F %T') ---"
	done
fi

stage() {	# name mem_pct p2_mode classifier
	if [ -e "$BASE/$1/DONE" ]; then echo "--- stage $1: DONE exists, skip ---"; return 0; fi
	local extra=(); [ -e "$BASE/$1" ] && extra+=(--resume)
	bash overnight/run_stage.sh -s "$1" -d "$D" -m 512M -n 5 -B 2 -t 60 -r 10 \
		--mem-pct "$2" --p2-mode "$3" --classifier "$4" "${extra[@]}"
	echo "##### stage $1 rc=$? $(date '+%F %T') #####"
}
if [ "$WHAT" = all ] || [ "$WHAT" = stages ]; then
	stage s1_rec  25 2 1
	stage s2_def   0 1 1
	stage s3_cls0 25 2 0
fi

# saddr 파라미터를 커널 기본값으로 되돌린다
P=/sys/module/saddr/parameters
echo 0 > $P/samon_loop_protect_mem_pct; echo 1 > $P/samon_p2_mode; echo 1 > $P/samon_classifier
echo "restored: mem_pct=$(cat $P/samon_loop_protect_mem_pct) p2_mode=$(cat $P/samon_p2_mode) classifier=$(cat $P/samon_classifier)"
echo "##### queue end $(date '+%F %T') #####"
