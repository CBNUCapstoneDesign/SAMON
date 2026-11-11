#!/bin/bash
# run_stage.sh — SAMON 재측정 한 단계(배치)를 워크로드 순서대로 실행한다.
#
# usage: sudo bash overnight/run_stage.sh -s STAGE -d DIR [옵션]
#   -s NAME         단계 이름 (결과: bench/results/NAME/<workload>/)
#   -d DIR          워크로드 파일 디렉터리 (단일 디스크 위, tmpfs·LVM·md 아님)
#   -w "LIST"       워크로드 순서 (기본 "reread loop seqwrite mixed")
#   -m SIZE         memory.max (기본 512M)
#   -n N / -t SECS / -r SECS   반복 10 / 측정 60 / ramp 10 (기본)
#   --mem-pct P     samon_loop_protect_mem_pct (기본 0 = P3 상한 없음)
#   --p2-mode M     samon_p2_mode (기본 1)
#   --classifier C  samon_classifier (기본 1)
#   --with-pn       samon_p1~p4 개별 구성도 측정
#
# 한 워크로드가 실패하거나 시간 제한에 걸려도 다음 워크로드를 계속한다.
# 인터럽트(130/143)면 단계 전체를 중단한다. 끝나면 $SD/DONE을 쓴다.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BENCH="$REPO/bench/samon_bench.sh"
SUMM="$REPO/bench/summarize.py"
PARM=/sys/module/saddr/parameters

STAGE=""; DIR=""; WLS="reread loop seqwrite mixed"; MEM=512M; N=10; T=60; R=10
MEMPCT=0; P2=1; CLS=1; WITHPN=0
while [ $# -gt 0 ]; do
	case "$1" in
	-s) STAGE=$2; shift 2 ;;
	-d) DIR=$2; shift 2 ;;
	-w) WLS=$2; shift 2 ;;
	-m) MEM=$2; shift 2 ;;
	-n) N=$2; shift 2 ;;
	-t) T=$2; shift 2 ;;
	-r) R=$2; shift 2 ;;
	--mem-pct) MEMPCT=$2; shift 2 ;;
	--p2-mode) P2=$2; shift 2 ;;
	--classifier) CLS=$2; shift 2 ;;
	--with-pn) WITHPN=1; shift ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$STAGE" ] && [ -n "$DIR" ] || { echo "usage: -s STAGE -d DIR [options]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }

SD="$REPO/bench/results/$STAGE"
mkdir -p "$SD" "$DIR" || exit 2
exec > >(tee -a "$SD/stage.log") 2>&1
echo "=== stage $STAGE start $(date '+%F %T') ==="
echo "kernel=$(uname -r) git=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null) dir=$DIR mem=$MEM n=$N t=$T r=$R"
echo "workloads=$WLS with_pn=$WITHPN"

setp() {	# name value: 쓰고 다시 읽어 확인한다
	[ -w "$PARM/$1" ] || { echo "FATAL: $PARM/$1 not writable (SAMON kernel not running?)"; exit 2; }
	echo "$2" > "$PARM/$1" 2>/dev/null
	local got; got=$(cat "$PARM/$1")
	[ "$got" = "$2" ] || { echo "FATAL: $1: wrote $2, read back $got"; exit 2; }
	echo "param $1=$got"
}
setp samon_q_len 8192
setp samon_loop_protect_mem_pct "$MEMPCT"
setp samon_p2_mode "$P2"
setp samon_classifier "$CLS"

out=$(bash -c 'source "$1" >/dev/null 2>&1; DIR=$2
	if resolve_target_disk; then echo "OK $DISK $DMAJ:$DMIN $DIR_FSTYPE $DIR_SOURCE"
	else echo "ERR $SAVE_ERR"; fi' _ "$BENCH" "$DIR")
echo "target: $out"
case "$out" in OK*) ;; *) echo "FATAL: cannot resolve a single target disk for $DIR"; exit 2 ;; esac

declare -A RC
for W in $WLS; do
	OUT="$SD/$W"
	nc=$(bash -c 'source "$1" >/dev/null 2>&1; set -- $(configs_for_workload "$2" "$3"); echo $#' _ "$BENCH" "$W" "$WITHPN")
	if ! [ "${nc:-0}" -gt 0 ] 2>/dev/null; then nc=8; fi
	LIMIT=$(( nc * N * (R + T + 150) ))	# 실행당 ramp + 측정 + 150초 여유. 넘으면 INT로 중단
	echo "--- $W: $nc configs x $N reps, limit ${LIMIT}s, $(date '+%F %T') ---"
	extra=(); [ "$WITHPN" = 1 ] && extra+=(--with-pn)
	timeout --signal=INT --kill-after=300 "$LIMIT" \
		bash "$BENCH" -w "$W" -d "$DIR" -m "$MEM" -t "$T" -r "$R" -n "$N" -o "$OUT" "${extra[@]}"
	rc=$?
	RC[$W]=$rc
	echo "--- $W finished rc=$rc $(date '+%F %T') ---"
	if [ -s "$OUT/runs.csv" ]; then
		python3 "$SUMM" "$OUT/runs.csv" > "$OUT/summary.md" 2> "$OUT/summary.err" \
			|| echo "WARN: summarize failed for $W (see $OUT/summary.err)"
	else
		echo "WARN: no runs.csv for $W"
	fi
	case $rc in 130|143) echo "interrupted: stopping stage"; break ;; esac
done

{ echo "stage=$STAGE"; echo "finished=$(date '+%F %T')"
  for W in $WLS; do echo "rc_$W=${RC[$W]:-notrun}"; done; } > "$SD/DONE"
echo "=== stage $STAGE done $(date '+%F %T') ==="
