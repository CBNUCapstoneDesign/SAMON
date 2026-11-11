#!/bin/bash
# tonight.sh — 재측정 큐: 단계 1(권장값) → 단계 2(기본값). 각 단계는 4개 워크로드를 순서대로.
# 한 단계가 실패해도 다음 단계를 계속한다. 결과: bench/results/s1_recommended, s2_default
# 실행: sudo tmux new-session -d -s samon "bash overnight/tonight.sh 2>&1 | tee -a bench/results/tonight.log"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
D=${SAMON_WORK_DIR:-/mnt/samon_bench/work}
echo "##### tonight start $(date '+%F %T') #####"
bash overnight/run_stage.sh -s s1_recommended -d "$D" -m 512M -n 10 -t 60 -r 10 --mem-pct 25 --p2-mode 2
echo "##### stage1 rc=$? $(date '+%F %T') #####"
bash overnight/run_stage.sh -s s2_default -d "$D" -m 512M -n 10 -t 60 -r 10 --mem-pct 0 --p2-mode 1
echo "##### stage2 rc=$? $(date '+%F %T') #####"
echo "##### tonight end $(date '+%F %T') #####"
