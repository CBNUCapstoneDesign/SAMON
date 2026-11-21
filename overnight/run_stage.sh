#!/bin/bash
# run_stage.sh — SAMON 재측정 한 단계(파라미터 조합 하나)를 블록 단위로 실행한다.
#
# usage: sudo bash overnight/run_stage.sh -s STAGE -d DIR [옵션]
#   -s NAME         단계 이름. 결과: bench/results/<SUB>/<NAME>/<workload>/b<k>/
#   -d DIR          워크로드 파일 디렉터리 (단일 디스크 위, tmpfs·LVM·md 아님)
#   -w "LIST"       워크로드 순서 (기본 "reread loop seqwrite mixed")
#   -m SIZE         memory.max (기본 512M)
#   -n N            블록당 반복 수 (기본 5)
#   -B N            블록 수 (기본 2) → 총 반복 = n × B
#   -t SECS / -r SECS   측정 60 / ramp 10 (기본)
#   --mem-pct P     samon_loop_protect_mem_pct (기본 0)
#   --p2-mode M     samon_p2_mode (기본 1)
#   --classifier C  samon_classifier (기본 1)
#   --with-pn       samon_p1~p4 개별 구성도 측정
#   --sub NAME      결과 상위 디렉터리 (기본 results_remeasure_1120)
#   --resume        단계 디렉터리가 이미 있을 때만: 완료된 블록은 건너뛰고, 미완료 블록은
#                   새 디렉터리(b<k>r2, r3 …)에 다시 측정한다. 기존 파일은 고치지 않는다.
#
# 순서: 블록 1을 모든 워크로드에 대해 → 블록 2 … (중간에 멈춰도 워크로드마다 n씩 확보)
# 단계 내내 bench/samon_sampler.py가 1초 샘플을 sampler.csv에 남긴다.
# 시험: SAMON_RUNBENCH=echo 를 주면 하네스 대신 명령줄만 출력한다(I/O 없음).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BENCH="$REPO/bench/samon_bench.sh"
SUMM="$REPO/bench/summarize.py"
SAMPLER="$REPO/bench/samon_sampler.py"
PARM=/sys/module/saddr/parameters
RUNBENCH=${SAMON_RUNBENCH:-}

STAGE=""; DIR=""; WLS="reread loop seqwrite mixed"; MEM=512M; N=5; B=2; T=60; R=10
MEMPCT=0; P2=1; CLS=1; WITHPN=0; SUB=results_remeasure_1120; RESUME=0
ARGS="$*"
while [ $# -gt 0 ]; do
	case "$1" in
	-s) STAGE=$2; shift 2 ;;
	-d) DIR=$2; shift 2 ;;
	-w) WLS=$2; shift 2 ;;
	-m) MEM=$2; shift 2 ;;
	-n) N=$2; shift 2 ;;
	-B) B=$2; shift 2 ;;
	-t) T=$2; shift 2 ;;
	-r) R=$2; shift 2 ;;
	--mem-pct) MEMPCT=$2; shift 2 ;;
	--p2-mode) P2=$2; shift 2 ;;
	--classifier) CLS=$2; shift 2 ;;
	--with-pn) WITHPN=1; shift ;;
	--sub) SUB=$2; shift 2 ;;
	--resume) RESUME=1; shift ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$STAGE" ] && [ -n "$DIR" ] || { echo "usage: -s STAGE -d DIR [options]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
case "$STAGE$SUB" in */*|*..*) echo "STAGE/SUB must be plain names" >&2; exit 2 ;; esac

SD="$REPO/bench/results/$SUB/$STAGE"
if [ -e "$SD" ] && [ "$RESUME" = 0 ]; then
	echo "FATAL: $SD already exists (results are never overwritten; use another -s or --resume)" >&2; exit 2
fi
mkdir -p "$SD" "$DIR" || exit 2
exec > >(tee -a "$SD/stage.log") 2>&1
echo "=== stage $STAGE start $(date '+%F %T') resume=$RESUME ==="
echo "args: $ARGS"

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
case "$out" in OK*) DISK=$(echo "$out" | cut -d' ' -f2) ;; *) echo "FATAL: cannot resolve a single target disk for $DIR"; exit 2 ;; esac

# DAMON target region = 대상 디스크 전체 (kernel/README.md). 비어 있으면 classifier=1 이 아무것도 판정하지 않는다.
# sysfs 값은 재부팅하면 사라지므로 단계 시작과 블록마다 다시 쓰고 읽어 확인한다 (11/22 추가).
KDS=/sys/kernel/mm/damon/admin/kdamonds
set_region() {
	local R=$KDS/0/contexts/0/targets/0/regions size
	size=$(cat /sys/class/block/$DISK/size) || { echo "FATAL: cannot read size of $DISK"; exit 2; }
	[ -d "$KDS/0/contexts/0/targets/0" ] || { echo 1 > $KDS/nr_kdamonds; echo 1 > $KDS/0/contexts/nr_contexts; echo saddr > $KDS/0/contexts/0/operations; echo 1 > $KDS/0/contexts/0/targets/nr_targets; } 2>/dev/null
	echo 1 > $R/nr_regions && echo 0 > $R/0/start && echo "$size" > $R/0/end || { echo "FATAL: cannot write DAMON target region"; exit 2; }
	[ "$(cat $R/nr_regions) $(cat $R/0/start) $(cat $R/0/end)" = "1 0 $size" ] || { echo "FATAL: DAMON target region read-back mismatch"; exit 2; }
	echo "region: $DISK 0-$size sectors"
}
# 블록이 끝난 뒤: classifier=1 인데 samon_all 실행의 rgn_nr 이 모두 0 이면 SAMON 이 아무것도 판정하지 않은 것 → 단계 중단
check_rgn() {
	[ "$CLS" = 1 ] || return 0
	local d=$1 st n v any=0 pos=0
	for st in $(grep -l "^config=samon_all" "$d"/run*.state 2>/dev/null); do
		n=$(basename "$st" .state); n=${n#run}
		v=$(sed -n "s/^rgn_nr=//p" "$d/snap_${n}_post/samon_stats" 2>/dev/null); [ -n "$v" ] || continue
		any=1; [ "$v" -gt 0 ] && pos=1
	done
	[ $any = 0 ] && { echo "WARN: rgn check: no samon_all snapshot in $(basename "$d")"; return 0; }
	[ $pos = 1 ] && { echo "rgn check ok: $(basename "$d")"; return 0; }
	echo "FATAL: rgn_nr=0 in every samon_all run of $d (classifier saw no DAMON region)"; return 1
}
set_region

env_stage() {	# 단계 환경 기록 (보고서 "데이터 수집 방법"용)
	local tag=$1
	{
		echo "[$tag] $(date -Is)"
		echo "stage=$STAGE sub=$SUB args=$ARGS"
		echo "uname=$(uname -a)"
		echo "os=$(lsb_release -ds 2>/dev/null)"
		echo "vcpus=$(nproc) memtotal_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)"
		echo "target_disk=$DISK model=$(cat /sys/block/$DISK/device/model 2>/dev/null | xargs)"
		echo "target_queue read_ahead_kb=$(cat /sys/block/$DISK/queue/read_ahead_kb) max_sectors_kb=$(cat /sys/block/$DISK/queue/max_sectors_kb) scheduler=$(cat /sys/block/$DISK/queue/scheduler)"
		echo "git_head=$(git -C "$REPO" rev-parse --short HEAD) git_branch=$(git -C "$REPO" branch --show-current) git_dirty=$(git -C "$REPO" status --porcelain -- bench overnight kernel | wc -l)"
		echo "saddr_c_sha256_repo=$(sha256sum "$REPO/kernel/saddr.c" | cut -d' ' -f1)"
		echo "saddr_c_sha256_built_tree=$(sha256sum /home/sang/src/linux-6.8/mm/damon/saddr.c 2>/dev/null | cut -d' ' -f1)"
		echo "kernel_config: $(grep -E '^CONFIG_(DAMON[A-Z_]*|LRU_GEN[A-Z_]*|DEBUG_INFO_NONE|DEBUG_INFO_BTF)=' /boot/config-$(uname -r) | tr '\n' ' ')"
		echo "fio=$(fio --version 2>/dev/null) fio_seed_policy=fio-default(randrepeat=1): same random offsets in every run"
		echo "workload_shape: n_per_block=$N blocks=$B measure_s=$T ramp_s=$R memory_max=$MEM with_pn=$WITHPN"
		echo "[saddr_params]"; for f in "$PARM"/*; do echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"; done
		echo
	} >> "$SD/env_stage.txt"
}
env_stage start

# 1초 샘플러: 단계 전체 동안
SAMPLER_PID=""
if [ -z "$RUNBENCH" ]; then
	python3 "$SAMPLER" -o "$SD/sampler.csv" -d "$DISK" -c /sys/fs/cgroup/samon_bench &
	SAMPLER_PID=$!
	echo "sampler pid=$SAMPLER_PID → $SD/sampler.csv"
fi
cleanup() { [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null; }
trap cleanup EXIT

nconfigs() { bash -c 'source "$1" >/dev/null 2>&1; set -- $(configs_for_workload "$2" "$3"); echo $#' _ "$BENCH" "$1" "$WITHPN"; }
rows_of() { [ -s "$1/runs.csv" ] && echo $(( $(wc -l < "$1/runs.csv") - 1 )) || echo 0; }

declare -A RC
STOP=0
for b in $(seq 1 "$B"); do
	for W in $WLS; do
		nc=$(nconfigs "$W"); [ "${nc:-0}" -gt 0 ] 2>/dev/null || nc=8
		want=$((nc * N))
		OUT="$SD/$W/b$b"
		if [ -e "$OUT" ]; then
			# b<k> 또는 그 재시도 b<k>r<N> 중 하나라도 완료면 건너뛴다 (11/21 수정: 전에는 b<k>만 봤음)
			full=""; for d in "$OUT" "$OUT"r*; do [ -d "$d" ] && [ "$(rows_of "$d")" -ge "$want" ] && { full=$d; break; }; done
			if [ -n "$full" ]; then
				echo "--- skip $W b$b: complete in $(basename "$full") ($(rows_of "$full")/$want rows) ---"; RC[$W.b$b]=skip; continue
			fi
			k=2; while [ -e "${OUT}r$k" ]; do k=$((k + 1)); done
			echo "--- $W b$b incomplete ($(rows_of "$OUT")/$want rows) → retry in b${b}r$k ---"
			OUT="${OUT}r$k"
		fi
		mkdir -p "$SD/$W"
		set_region
		LIMIT=$(( nc * N * (R + T + 150) ))
		date +%s > "$SD/HEARTBEAT"
		echo "--- $W b$b: $nc configs x $N reps, limit ${LIMIT}s, $(date '+%F %T') ---"
		extra=(); [ "$WITHPN" = 1 ] && extra+=(--with-pn)
		if [ -n "$RUNBENCH" ]; then
			$RUNBENCH bash "$BENCH" -w "$W" -d "$DIR" -m "$MEM" -t "$T" -r "$R" -n "$N" -o "$OUT" "${extra[@]}"
			rc=$?
		else
			timeout --signal=INT --kill-after=300 "$LIMIT" \
				bash "$BENCH" -w "$W" -d "$DIR" -m "$MEM" -t "$T" -r "$R" -n "$N" -o "$OUT" "${extra[@]}"
			rc=$?
		fi
		RC[$W.$(basename "$OUT")]=$rc
		echo "--- $W $(basename "$OUT") finished rc=$rc rows=$(rows_of "$OUT")/$want $(date '+%F %T') ---"
		dmesg --time-format=iso > "$SD/$W/$(basename "$OUT").dmesg" 2>/dev/null
		if [ -s "$OUT/runs.csv" ]; then
			python3 "$SUMM" "$OUT/runs.csv" > "$OUT/summary.md" 2> "$OUT/summary.err" \
				|| echo "WARN: summarize failed for $W $(basename "$OUT")"
		elif [ -z "$RUNBENCH" ]; then
			echo "WARN: no runs.csv for $W $(basename "$OUT")"
		fi
		case $rc in 130|143) echo "interrupted: stopping stage"; STOP=1; break ;; esac
		if [ -z "$RUNBENCH" ] && ! check_rgn "$OUT"; then echo "region check failed: stopping stage"; STOP=1; RGN_FAIL=1; break; fi
	done
	[ "$STOP" = 1 ] && break
done

# 워크로드별 합본(파생 파일): 블록 runs.csv를 이어 붙이고 요약
if [ -z "$RUNBENCH" ]; then
	for W in $WLS; do
		files=$(ls "$SD/$W"/b*/runs.csv 2>/dev/null) || continue
		[ -n "$files" ] || continue
		first=$(echo "$files" | head -1)
		{ head -1 "$first"; for f in $files; do tail -n +2 "$f"; done; } > "$SD/$W/runs_all.csv"
		python3 "$SUMM" "$SD/$W/runs_all.csv" > "$SD/$W/summary_all.md" 2> "$SD/$W/summary_all.err" \
			|| echo "WARN: combined summarize failed for $W"
	done
fi
env_stage end
if [ "${RGN_FAIL:-0}" = 1 ]; then echo "=== stage $STAGE STOPPED (rgn_nr=0), no DONE written ==="; exit 3; fi
{ echo "stage=$STAGE"; echo "finished=$(date '+%F %T')"; echo "stopped_early=$STOP"
  for k in "${!RC[@]}"; do echo "rc_$k=${RC[$k]}"; done | sort; } > "$SD/DONE"
echo "=== stage $STAGE done $(date '+%F %T') ==="
