#!/bin/bash
# samon_live_demo.sh — 시연 시작: tmux 세션 하나에 반복 실행기(아래 8줄)와 화면(위)을 띄운다.
# usage: sudo bash demo/samon_live_demo.sh [samon_live_ab.sh 옵션...]     예: sudo bash demo/samon_live_demo.sh -c 50
#   들어가기: sudo tmux attach -t samon_live        끝내기: 아래 칸에서 Ctrl-C (정리 후 실행기 종료) → sudo tmux kill-session -t samon_live
set -u
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 2
[ "$(id -u)" = 0 ] || { echo "root 로 실행: sudo bash $0"; exit 2; }
tmux has-session -t samon_live 2>/dev/null && { echo "이미 실행 중: sudo tmux attach -t samon_live"; exit 1; }
args=$(printf ' %q' "$@")
tmux new-session -d -s samon_live -x 200 -y 50 -c "$PWD" "python3 demo/samon_live_score.py; bash"
tmux split-window -v -l 8 -t samon_live -c "$PWD" "bash demo/samon_live_ab.sh$args; bash"
tmux select-pane -t samon_live:0.0
echo "시작함. 보기: sudo tmux attach -t samon_live"
