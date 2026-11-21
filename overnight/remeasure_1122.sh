#!/bin/bash
# remeasure_1122.sh — region 수정 후 재측정 큐 (11/22): s1r_rec → s2r_def
#   11/20 큐(remeasure_1120.sh)의 s1_rec b2 와 s2_def 는 DAMON target region 이 비어 SAMON 이 판정을 하지 않았다.
#   run_stage.sh 가 이제 블록마다 region 을 대상 디스크 전체로 설정하고, 블록 뒤 rgn_nr 를 확인한다(0 이면 rc=3 으로 중단).
# usage: sudo bash overnight/remeasure_1122.sh
#   tmux: sudo tmux new-session -d -s samon "bash overnight/remeasure_1122.sh 2>&1 | tee -a bench/results/results_remeasure_1120/queue.log"
# 결과는 같은 폴더(results_remeasure_1120)에 새 단계 이름으로 쌓인다. 기존 단계는 건드리지 않는다.
set -u
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 2
REPO=$PWD
SUB=results_remeasure_1120
BASE=$REPO/bench/results/$SUB
D=/mnt/samon_bench/work
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
echo "##### queue1122 start $(date '+%F %T') #####"

stage() {	# name mem_pct p2_mode classifier
	if [ -e "$BASE/$1/DONE" ]; then echo "--- stage $1: DONE exists, skip ---"; return 0; fi
	local extra=(); [ -e "$BASE/$1" ] && extra+=(--resume)
	bash overnight/run_stage.sh -s "$1" -d "$D" -m 512M -n 5 -B 2 -t 60 -r 10 \
		--mem-pct "$2" --p2-mode "$3" --classifier "$4" "${extra[@]}"
	local rc=$?
	echo "##### stage $1 rc=$rc $(date '+%F %T') #####"
	return $rc
}
ok=1
stage s1r_rec 25 2 1 || { [ $? = 3 ] && ok=0; }
[ $ok = 1 ] && { stage s2r_def 0 1 1 || { [ $? = 3 ] && ok=0; }; }
[ $ok = 0 ] && echo "##### queue1122 STOPPED: region check failed (rgn_nr=0) #####"

P=/sys/module/saddr/parameters
echo 0 > $P/samon_loop_protect_mem_pct; echo 1 > $P/samon_p2_mode; echo 1 > $P/samon_classifier
echo "restored: mem_pct=$(cat $P/samon_loop_protect_mem_pct) p2_mode=$(cat $P/samon_p2_mode) classifier=$(cat $P/samon_classifier)"
echo "##### queue1122 end $(date '+%F %T') #####"
