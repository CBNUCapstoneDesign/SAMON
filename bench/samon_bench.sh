#!/bin/bash
# samon_bench.sh — SAMON 측정 하네스 (S4, design T6, 요구사항 10·11)
#
# 리눅스 기본 동작(off), DAMON_LRU_SORT(damon), SAMON 구성(samon_*)을 같은 워크로드로
# 비교한다. bash는 순서와 sysfs 쓰기만 맡고, CSV 열 정의·행 생성·실행 순서·fio JSON
# 해석은 bench/samon_benchlib.py가 맡는다. 워크로드 정의는 bench/samon_workloads.sh.
#
# usage: sudo bash bench/samon_bench.sh -w WORKLOAD [옵션]
#   (옵션은 `--help` 참조. 긴 옵션은 `--name value`와 `--name=value` 모두 받는다.)
#
# 구현 상태(tasks.md 24.x):
#   24.2  옵션, 사전 확인, saved.txt, env.txt, prefill            <- 이 파일에 구현됨
#   24.3  restore trap(restore_* 단계, 재확인, 불일치 출력)        <- 이 파일에 구현됨
#   24.4  구성 표, 실행 순서(order.txt), 실행 하나의 시작·확인      <- 이 파일에 구현됨(run_all, run_one)
#   24.5  스냅샷, cachestat, CSV 행, 경고, 구성 정리                <- 이 파일에 구현됨(hook_*)
#
# 결과 디렉터리($OUT)에 남는 파일(실행 번호 N은 order.txt의 줄 번호):
#   runs.csv            실행당 한 행(열 정의와 행 생성은 samon_benchlib.py). 첫 행을 쓸 때 헤더도 쓴다.
#   run<N>.state        하네스가 다시 읽어 확인한 상태(`열=값`, samon_benchlib.py row --state-file)
#   run<N>.{fio,json}   fio 잡 파일과 출력(loop는 run<N>.passes.csv, run<N>.passes.meta)
#   snap_<N>_{pre,post}/ 원문 스냅샷: vmstat stat meminfo memory.stat [samon_stats] [lru_sort_stats]
#                       [kd_stat] ts. pre = ramp 끝, post = 워크로드 종료 직후(요구사항 10 기준 7).
#                       측정 구간(pre ~ post) 사이에는 debugfs와 LRU_SORT 파일을 읽지 않는다.
#                       kdamond pid는 워크로드 시작 직전에 읽는다.
#   cachestat_<N>.txt   cachestat-bpfcc -T 1 원문(실행 가능할 때만. 아니면 cachestat_hit_pct = NA)
#
# 종료 코드: 0 정상(모든 실행의 행이 runs.csv에 기록됨), 1 실행 중 실패/복원 불일치,
#            2 인자·사전 확인 실패, 130/143 SIGINT/SIGTERM.
#
# -D(드라이런): root 없이 fio와 CSV 경로만 돈다. sysfs·cgroup·drop_caches·cachestat은 건드리지 않으므로
# 상태·SAMON·LRU_SORT·cgroup 열은 NA이고 /proc 기반 열(pgpgin, cpu_*, slab)과 fio 열만 채워진다.
#
# 이 파일을 `source`하면 함수만 정의하고 main은 실행하지 않는다(시험용).
# sysfs 경로는 환경 변수 SB_KD, SB_PARM, SB_LRUP, SB_LRUGEN, SB_DBG, SB_CGROOT로
# 바꿀 수 있다(시험용 가짜 트리). SB_DROP(drop_caches 파일), SB_STATE_WAIT(state 전환 대기 초),
# SB_RESTORE_WAIT도 시험용이다. 실제 측정에서는 쓰지 않는다.
set -u
set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BENCHLIB=$HERE/samon_benchlib.py
WLSH=$HERE/samon_workloads.sh

KD=${SB_KD:-/sys/kernel/mm/damon/admin/kdamonds}
PARM=${SB_PARM:-/sys/module/saddr/parameters}
LRUP=${SB_LRUP:-/sys/module/damon_lru_sort/parameters}
LRUGEN=${SB_LRUGEN:-/sys/kernel/mm/lru_gen/enabled}
DBG=${SB_DBG:-/sys/kernel/debug/samon}
CGROOT=${SB_CGROOT:-/sys/fs/cgroup}
CG=$CGROOT/samon_bench

PROC=${SB_PROC:-/proc}			# 시험용 가짜 /proc
CACHESTAT_CMD=${SB_CACHESTAT:-cachestat-bpfcc}
CACHESTAT_WAIT_S=${SB_CACHESTAT_WAIT:-10}	# 워크로드 시작 전에 cachestat 첫 출력을 기다리는 최대 초

# 하네스가 쓰는 SAMON 모듈 파라미터(요구사항 10 기준 9). 읽기에 하나라도 실패하면 중단한다.
SAMON_WRITTEN_PARAMS="samon_act_p1 samon_act_p2 samon_act_p3 samon_act_p4 samon_opt_b samon_dbg_lba samon_dev_major samon_dev_minor"
# 부록 A 확정 기본값 표 DEFAULTS(SAMON_DEF_*와 같음). env.txt에서 실제 값과 대조한다.
# 예외: samon_q_len=8192(User 확정 2026-10-18, kernel/samon_qlen_sweep.sh #12 결과).
# saddr.c SAMON_DEF_Q_LEN은 1024 그대로이고, 이 하네스는 samon_q_len을 쓰지 않고 대조만 한다.
SAMON_DEFAULTS_APPX="samon_q_len=8192 samon_loop_min_kb=8192 samon_loop_protect_pct=50 samon_reread_slots=65536 samon_reread_ms=10000 samon_seq_min=4 samon_stream_new_kb=64 samon_stream_gap_req=2 samon_stream_idle_ms=1000 samon_q_max_ms=100 samon_stream_slots=16 samon_loop_slots=16"
# LRU_SORT 파라미터 중 저장 대상에서 빼는 것(요구사항 10 기준 9의 쓰기 가능 집합에서 제외)
LRUSORT_SKIP="kdamond_pid commit_inputs"

# ---------------------------------------------------------------------------
# 옵션 기본값 (design T6 옵션 표)
# ---------------------------------------------------------------------------
WL=""
DIR=/var/tmp/samon_bench
MEM=768M
SECS=120
RAMP=10
REPS=5
OUT=""
DRY=0
WITH_PN=0
SEED=""
SAMPLE_US=5000
AGGR_US=100000
UPDATE_US=1000000
NR_MIN=""			# 비면 sysfs 기본값(실행마다 읽어 CSV mon_nr_min에 기록)
NR_MAX=""
COLD_MIN_AGE=10000000		# µs
PID_WAIT=5
Q_WARN_PCT=1
# 워크로드 파라미터는 SWL_* 환경 변수로 samon_workloads.sh에 넘긴다(비어 있으면 그쪽 기본값).

# 상태
RESTORE_ARMED=0
START_NS=0
DISK=""; DMAJ=""; DMIN=""; DIR_FSTYPE=""; DIR_SOURCE=""
SAVED_LRU_GEN=""
declare -A SAVED_LRUSORT=()
declare -a SAVED_LRUSORT_NAMES=()
declare -A SAVED_SAMON=()
SAVE_ERR=""
APPX_MISMATCH=0
MEM_BYTES=0

# restore()가 읽는 실행 상태. 24.4, 24.5가 실행 중에 갱신한다. restore는 이 값이 기본값(비어 있음)이어도
# 아무 일 없이 넘어가므로, 설정 도중 중단돼도 안전하다.
#   CG                 측정 cgroup 경로($CGROOT/samon_bench, 위에서 정의). 디렉터리가 있으면 restore가
#                      cgroup.kill → rmdir 한다. 아직 만들지 않았으면 건너뛴다.
#   CACHESTAT_PID      24.5가 띄운 cachestat-bpfcc의 PID. 비어 있으면 건너뛴다. 감싸는 프로세스(timeout,
#                      sudo 등)를 거쳐 띄우면 그 PID가 아니라 실제로 종료해야 할 PID를 넣어야 한다.
#                      종료를 확인하면 restore가 다시 비운다.
#   SAMON_KD_STARTED   24.4가 SAMON kdamond에 `on`을 쓰기 직전에 1로 바꾼다(쓰기 실패 가능성이 있으므로
#                      쓰기 전). restore는 이 값과 상관없이 $KD/0/state가 on이면 off로 돌리고, 값이 0인데
#                      on이면 하네스가 켜지 않은 kdamond를 껐다는 경고만 더 낸다.
#   RESTORE_WAIT_S     state 전환, cgroup rmdir, cachestat 종료를 기다리는 최대 초(기본 10, 시험용
#                      SB_RESTORE_WAIT).
CACHESTAT_PID=""
SAMON_KD_STARTED=0
RESTORE_WAIT_S=${SB_RESTORE_WAIT:-10}
declare -a RESTORE_MISMATCH=()

log() { echo "bench: $*" >&2; }

usage() {
	cat <<'EOF'
usage: sudo bash bench/samon_bench.sh -w WORKLOAD [options]

  -w NAME          mixed | reread | loop | seqwrite (required)
  -d DIR           workload files, not tmpfs, on the SAMON target disk
                   (default /var/tmp/samon_bench)
  -m SIZE          memory.max of the measurement cgroup (default 768M)
  -t SECS          measurement window after ramp (default 120)
  -r SECS          ramp time (default 10)
  -n N             repetitions (default 5)
  -o DIR           result directory (default bench/results/<date>-<workload>)
  -D               dry run: no root, no sysfs/cgroup/cachestat access, fio + CSV path only
  --with-pn        also run samon_p1..p4 and samon_p1_classic, samon_p4_classic
  --seed N         random seed for the run order (default: current time in ns)

workload parameters (requirement 11 criterion 2):
  --hot-size S (1G)   --hot-zipf Z (1.2)   --scan-size S (2G)
  --reread-size S (ceil(memory.max x 1.3) MiB)   --reread-zipf Z (0.8)
  --loop-size S (1G, must be > memory.max)   --loop-bs S (128k)
  --writer-size S (2G)   --writer-bs S (1M)

SAMON kdamond monitoring_attrs (requirement 10 criterion 14):
  --sample-us N (5000)  --aggr-us N (100000)  --update-us N (1000000)
  --nr-min N / --nr-max N (default: sysfs default read at kdamond setup)

other:
  --cold-min-age US (10000000)   LRU_SORT cold_min_age in microseconds
  --pid-wait SECS (5)            wait for LRU_SORT kdamond_pid > 0
  --q-warn-pct P (1)             queue-drop warning threshold (percent of sum(req))
  -h, --help
EOF
}

usage_err() {
	echo "bench: $*" >&2
	echo "try 'bash bench/samon_bench.sh --help'" >&2
	exit 2
}

# 사전 확인 실패: 실패한 확인 이름과 읽은 값을 출력하고 종료 코드 2(요구사항 11 기준 6).
# 상태를 바꾸기 전(trap 설치 전)에만 쓴다.
die_check() {
	echo "BENCH CHECK FAIL $1: ${2:-}" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# 옵션 파싱과 검증
# ---------------------------------------------------------------------------
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# 앞의 0을 떼어 10진수로(08, 010을 8진수로 읽지 않게)
norm_uint() { local v=$1; v=${v#"${v%%[!0]*}"}; echo "${v:-0}"; }

parse_args() {
	local opt val eq
	while [ $# -gt 0 ]; do
		opt=$1; shift; val=""; eq=0
		case $opt in
		--*=*) val=${opt#*=}; opt=${opt%%=*}; eq=1 ;;
		-D|--with-pn|-h|--help) ;;
		-*)
			[ $# -ge 1 ] || usage_err "option $opt needs a value"
			val=$1; shift ;;
		*) usage_err "unexpected argument: $opt" ;;
		esac
		case $opt in
		-D|--with-pn|-h|--help)
			[ $eq = 0 ] || usage_err "option $opt takes no value" ;;
		esac
		case $opt in
		-w) WL=$val ;;
		-d) DIR=$val ;;
		-m) MEM=$val ;;
		-t) SECS=$val ;;
		-r) RAMP=$val ;;
		-n) REPS=$val ;;
		-o) OUT=$val ;;
		-D) DRY=1 ;;
		--with-pn) WITH_PN=1 ;;
		--seed) SEED=$val ;;
		--hot-size) SWL_HOT_SIZE=$val ;;
		--hot-zipf) SWL_HOT_ZIPF=$val ;;
		--scan-size) SWL_SCAN_SIZE=$val ;;
		--reread-size) SWL_REREAD_SIZE=$val ;;
		--reread-zipf) SWL_REREAD_ZIPF=$val ;;
		--loop-size) SWL_LOOP_SIZE=$val ;;
		--loop-bs) SWL_LOOP_BS=$val ;;
		--writer-size) SWL_WRITER_SIZE=$val ;;
		--writer-bs) SWL_WRITER_BS=$val ;;
		--sample-us) SAMPLE_US=$val ;;
		--aggr-us) AGGR_US=$val ;;
		--update-us) UPDATE_US=$val ;;
		--nr-min) NR_MIN=$val ;;
		--nr-max) NR_MAX=$val ;;
		--cold-min-age) COLD_MIN_AGE=$val ;;
		--pid-wait) PID_WAIT=$val ;;
		--q-warn-pct) Q_WARN_PCT=$val ;;
		-h|--help) usage; exit 0 ;;
		*) usage_err "unknown option: $opt" ;;
		esac
	done
	[ -n "$WL" ] || { usage >&2; usage_err "-w WORKLOAD is required"; }
}

# 숫자 옵션 하나 확인: 변수 이름, 옵션 이름, 최솟값. 통과하면 변수에 정규화한 값을 넣는다.
# (명령 치환 안에서 exit하면 부모가 계속되므로 nameref로 값을 돌려준다)
need_uint() {
	local -n ref=$1
	local name=$2 min=$3 v=$ref
	is_uint "$v" || die_check "option_$name" "'$v' is not a non-negative integer"
	v=$(norm_uint "$v")
	[ "$v" -ge "$min" ] || die_check "option_$name" "'$v' < $min"
	ref=$v
}

# 형식 검증과 기본값 확정(root 없이 가능). R11.6 (a) 워크로드 이름, (c) loop 크기.
validate_options() {
	# shellcheck source=bench/samon_workloads.sh
	. "$WLSH" || die_check "workloads_lib" "cannot source $WLSH"

	# (a) 워크로드 이름: R11 표의 이름만(R93 형태 이름은 하네스 대상이 아님)
	case "$WL" in
	mixed|reread|loop|seqwrite) ;;
	*) die_check "workload_name" "'$WL' is not one of: $(swl_r11_names)" ;;
	esac

	need_uint SECS t 1
	need_uint RAMP r 0
	need_uint REPS n 1
	need_uint PID_WAIT pid-wait 1
	need_uint SAMPLE_US sample-us 1
	need_uint AGGR_US aggr-us 1
	need_uint UPDATE_US update-us 1
	need_uint COLD_MIN_AGE cold-min-age 1
	[ -z "$NR_MIN" ] || need_uint NR_MIN nr-min 1
	[ -z "$NR_MAX" ] || need_uint NR_MAX nr-max 1
	if [ -n "$NR_MIN" ] && [ -n "$NR_MAX" ] && [ "$NR_MIN" -gt "$NR_MAX" ]; then
		die_check "option_nr-min" "nr-min $NR_MIN > nr-max $NR_MAX"
	fi
	[ "$AGGR_US" -ge "$SAMPLE_US" ] ||
		die_check "option_aggr-us" "aggr-us $AGGR_US < sample-us $SAMPLE_US"
	case "$Q_WARN_PCT" in
	''|*[!0-9.]*|.*|*.|*.*.*) die_check "option_q-warn-pct" "'$Q_WARN_PCT' is not a non-negative number" ;;
	esac
	if [ -z "$SEED" ]; then
		SEED=$(date +%s%N)
	else
		is_uint "$SEED" || die_check "option_seed" "'$SEED' is not a non-negative integer"
		SEED=$(norm_uint "$SEED")
	fi
	[ -n "$DIR" ] || die_check "option_d" "empty directory"
	DIR=$(readlink -m "$DIR")

	# 워크로드 파라미터: 비어 있는 SWL_*를 기본값으로 채우고 형식을 검사한다.
	SWL_MEM=$MEM
	swl_defaults || die_check "workload_params" "invalid size/zipf option (see swl: lines above)"
	export SWL_MEM SWL_HOT_SIZE SWL_HOT_ZIPF SWL_SCAN_SIZE SWL_REREAD_SIZE SWL_REREAD_ZIPF \
		SWL_LOOP_SIZE SWL_LOOP_BS SWL_WRITER_SIZE SWL_WRITER_BS SWL_P2_PASS_S SWL_BG_RUNTIME
	MEM_BYTES=$(swl_bytes "$MEM") || die_check "option_m" "bad memory.max '$MEM'"

	# (c) loop 파일 크기가 memory.max 이하면 측정하지 않는다(드라이런 포함, 크기 확인일 뿐이다)
	if [ "$WL" = loop ] && ! swl_loop_larger_than_mem; then
		die_check "loop_size" "loop size $SWL_LOOP_SIZE <= memory.max $MEM"
	fi
	[ -n "$OUT" ] || OUT=$HERE/results/$(date +%Y%m%d-%H%M%S)-$WL
	OUT=$(readlink -m "$OUT")
	CSV=$OUT/runs.csv
}

# ---------------------------------------------------------------------------
# 사전 확인 (R10.8, R10.9, R11.1(a), R11.6(b))
# ---------------------------------------------------------------------------
nearest_dir() {
	local d=$1
	while [ ! -d "$d" ]; do d=$(dirname "$d"); done
	echo "$d"
}

# -d의 파일시스템 → 파티션 → 부모 디스크. DISK, DMAJ, DMIN, DIR_FSTYPE, DIR_SOURCE를 채운다.
# 실패하면 사유를 SAVE_ERR에 쓰고 1. (design T6: 대상 디스크는 -d에서 구한다)
resolve_target_disk() {
	local base src part
	base=$(nearest_dir "$DIR")
	DIR_FSTYPE=$(findmnt -no FSTYPE -T "$base" 2>/dev/null) || DIR_FSTYPE=""
	DIR_SOURCE=$(findmnt -no SOURCE -T "$base" 2>/dev/null) || DIR_SOURCE=""
	[ -n "$DIR_SOURCE" ] || { SAVE_ERR="findmnt found no source for $base"; return 1; }
	part=$(basename "$(readlink -f "$DIR_SOURCE")")
	[ -e "/sys/class/block/$part" ] || { SAVE_ERR="no /sys/class/block/$part (source $DIR_SOURCE)"; return 1; }
	if [ -e "/sys/class/block/$part/partition" ]; then
		DISK=$(basename "$(readlink -f "/sys/class/block/$part/..")")
	else
		DISK=$part
	fi
	# 여러 디스크 위에 쌓인 장치(dm, md)는 한 디스크로 정할 수 없다
	if [ -d "/sys/class/block/$DISK/slaves" ] && [ -n "$(ls -A "/sys/class/block/$DISK/slaves" 2>/dev/null)" ]; then
		SAVE_ERR="$DISK is a stacked device (slaves: $(ls "/sys/class/block/$DISK/slaves" | tr '\n' ' '))"
		return 1
	fi
	[ -r "/sys/class/block/$DISK/dev" ] || { SAVE_ERR="cannot read /sys/class/block/$DISK/dev"; return 1; }
	DMAJ=$(cut -d: -f1 "/sys/class/block/$DISK/dev")
	DMIN=$(cut -d: -f2 "/sys/class/block/$DISK/dev")
	is_uint "$DMAJ" && is_uint "$DMIN" || { SAVE_ERR="bad dev number for $DISK: $DMAJ:$DMIN"; return 1; }
	return 0
}

# 필요한 파일 공간(바이트): 워크로드가 prefill하는 파일 크기 합
workload_bytes() {
	local v b total=0
	case "$WL" in
	mixed)    set -- SWL_HOT_SIZE SWL_SCAN_SIZE ;;
	reread)   set -- SWL_REREAD_SIZE ;;
	loop)     set -- SWL_LOOP_SIZE ;;
	seqwrite) set -- SWL_HOT_SIZE SWL_WRITER_SIZE ;;
	esac
	for v in "$@"; do
		b=$(swl_bytes "${!v}") || return 1
		total=$((total + b))
	done
	echo "$total"
}

check_tools() {
	local t
	for t in fio python3 numfmt findmnt timeout awk sync stat df; do
		command -v "$t" >/dev/null 2>&1 || die_check "tool_$t" "command not found"
	done
	[ -r "$BENCHLIB" ] || die_check "benchlib" "missing $BENCHLIB"
}

preflight_dry() {
	log "dry run (-D): root, sysfs and cgroup checks skipped"
	check_tools
	# 디스크는 알아낼 수 있으면 env.txt에 기록할 뿐 필수가 아니다
	resolve_target_disk || { log "dry run: target disk unresolved ($SAVE_ERR)"; DISK=""; DMAJ=""; DMIN=""; SAVE_ERR=""; }
}

preflight_system() {
	local need avail have

	[ "$(id -u)" = 0 ] || die_check "root" "run as root (or use -D for a dry run)"
	check_tools

	# cgroup v2 + memory 컨트롤러(루트 cgroup의 subtree_control에 켜져 있어야 하위 cgroup에 memory.max가 생김)
	[ "$(stat -fc %T "$CGROOT" 2>/dev/null)" = cgroup2fs ] ||
		die_check "cgroup_v2" "$CGROOT is not cgroup2fs"
	grep -qw memory "$CGROOT/cgroup.controllers" 2>/dev/null ||
		die_check "cgroup_memory" "memory controller missing in $CGROOT/cgroup.controllers"
	grep -qw memory "$CGROOT/cgroup.subtree_control" 2>/dev/null ||
		die_check "cgroup_memory_subtree" "memory not enabled in $CGROOT/cgroup.subtree_control"

	# SAMON 커널이 떠 있어야 한다(S1 이후 stats: q_cap 줄)
	[ -d "$PARM" ] || die_check "samon_params" "no $PARM (SAMON kernel not running?)"
	[ -r "$DBG/stats" ] || die_check "samon_debugfs" "cannot read $DBG/stats (debugfs mounted? SAMON kernel?)"
	grep -q '^q_cap=' "$DBG/stats" 2>/dev/null ||
		die_check "samon_stats_q_cap" "$DBG/stats has no q_cap line (S1 or later kernel required)"
	[ -e "$KD/nr_kdamonds" ] || die_check "damon_sysfs" "no $KD/nr_kdamonds"
	[ -d "$LRUP" ] || die_check "lru_sort_params" "no $LRUP (damon_lru_sort not available)"
	[ -r "$LRUGEN" ] || die_check "lru_gen" "cannot read $LRUGEN"

	# R11.1(a), R11.6(b): -d는 tmpfs가 아니고 SAMON 대상 디스크 위
	local disk_rc=0
	resolve_target_disk || disk_rc=$?
	[ "$DIR_FSTYPE" != tmpfs ] || die_check "tmpfs" "$DIR is on tmpfs"
	[ -n "$DIR_FSTYPE" ] || die_check "tmpfs" "cannot determine file system type of $DIR"
	[ "$disk_rc" = 0 ] || die_check "disk_match" "$SAVE_ERR"

	# 공간: 필요한 파일 크기 합(+ 여유 10%와 256MiB) <= 남은 공간 + 이미 있는 같은 이름 파일
	need=$(workload_bytes) || die_check "workload_params" "cannot size workload files"
	avail=$(df --output=avail -B1 "$(nearest_dir "$DIR")" | tail -1 | tr -dc 0-9)
	have=0
	local f
	while IFS= read -r f; do
		[ -e "$f" ] && have=$((have + $(stat -c %s "$f")))
	done < <(swl_files "$WL" "$DIR")
	need=$((need + need / 10 + 268435456))
	[ "$need" -le $((avail + have)) ] ||
		die_check "free_space" "need ~$((need >> 20)) MiB, free $((avail >> 20)) MiB (+ $((have >> 20)) MiB existing) in $DIR"
}

preflight() {
	if [ "$DRY" = 1 ]; then preflight_dry; else preflight_system; fi
	# 결과 디렉터리는 덮어쓰지 않는다(이미 측정한 디렉터리는 고치지 않는다, 요구사항 1 기준 6)
	local f
	for f in runs.csv saved.txt env.txt order.txt; do
		[ ! -e "$OUT/$f" ] ||
			die_check "outdir_exists" "$OUT/$f already exists (results are never overwritten; use another -o)"
	done
}

# ---------------------------------------------------------------------------
# 상태 저장 saved.txt (R10.9)
# ---------------------------------------------------------------------------
# 다른 값을 쓰기 전에 모든 LRU_SORT 파라미터(쓰기 가능한 것), lru_gen 원문, 하네스가 쓰는
# SAMON 모듈 파라미터를 메모리에 읽는다. 하나라도 읽지 못하면 SAVE_ERR를 채우고 1을
# 반환하며 이 함수는 어떤 파일도 쓰지 않는다(호출자는 이 경우 종료한다).
read_saved_state() {
	local f n v mode
	local -A lru=() sam=()
	local -a lru_names=()

	v=$(cat "$LRUGEN" 2>/dev/null) || { SAVE_ERR="cannot read $LRUGEN"; return 1; }
	local lru_gen=$v

	for f in "$LRUP"/*; do
		[ -e "$f" ] || { SAVE_ERR="no LRU_SORT parameters under $LRUP"; return 1; }
		n=$(basename "$f")
		case " $LRUSORT_SKIP " in *" $n "*) continue ;; esac
		mode=$(stat -c %a "$f" 2>/dev/null) || { SAVE_ERR="cannot stat $f"; return 1; }
		# 소유자 쓰기 비트가 없는 파일(통계, kdamond_pid)은 저장 대상이 아니다
		(( (8#$mode & 8#200) != 0 )) || continue
		v=$(cat "$f" 2>/dev/null) || { SAVE_ERR="cannot read $f"; return 1; }
		lru[$n]=$v
		lru_names+=("$n")
	done

	for n in $SAMON_WRITTEN_PARAMS; do
		v=$(cat "$PARM/$n" 2>/dev/null) || { SAVE_ERR="cannot read $PARM/$n"; return 1; }
		sam[$n]=$v
	done

	# 모두 읽었다: 전역에 반영
	SAVED_LRU_GEN=$lru_gen
	SAVED_LRUSORT=()
	SAVED_LRUSORT_NAMES=("${lru_names[@]}")
	for n in "${lru_names[@]}"; do SAVED_LRUSORT[$n]=${lru[$n]}; done
	SAVED_SAMON=()
	for n in $SAMON_WRITTEN_PARAMS; do SAVED_SAMON[$n]=${sam[$n]}; done
	return 0
}

write_saved_file() {
	local n
	{
		echo "# samon_bench.sh saved state, read before any value is written (R10.9)"
		echo "# format: <key>=<raw value>; restore() writes these back (R10.10)"
		if [ "$DRY" = 1 ]; then
			echo "# dry run: nothing read, nothing to restore"
		else
			echo "lru_gen=$SAVED_LRU_GEN"
			for n in "${SAVED_LRUSORT_NAMES[@]}"; do echo "lru_sort.$n=${SAVED_LRUSORT[$n]}"; done
			for n in $SAMON_WRITTEN_PARAMS; do echo "samon.$n=${SAVED_SAMON[$n]}"; done
		fi
	} > "$OUT/saved.txt"
}

# ---------------------------------------------------------------------------
# 환경 기록 env.txt (R10.8, R11.2, R1.6)
# ---------------------------------------------------------------------------
# 파일을 읽어 첫 줄을 출력, 못 읽으면 NA
rd() {
	local v
	if v=$(cat "$1" 2>/dev/null); then
		v=${v%%$'\n'*}
		printf '%s' "${v%"${v##*[![:space:]]}"}"
	else
		printf 'NA'
	fi
}

# 부록 A 표 한 줄: 항목 | 부록 A 값 | 이번 실행 값 | 확정(Y/N) | 비교
# 확정(Y) 값과 다르면 APPX_MISMATCH를 올린다.
appx_row() {
	local item=$1 appx=$2 used=$3 conf=$4 cmp=${5:-}
	if [ -z "$cmp" ]; then
		if [ "$used" = NA ]; then
			cmp="확인 불가"
		elif [ "$appx" = "$used" ]; then
			if [ "$conf" = Y ]; then cmp="일치"; else cmp="제안값과 같음(미확정)"; fi
		else
			if [ "$conf" = Y ]; then
				cmp="확정값과 다름"
				APPX_MISMATCH=$((APPX_MISMATCH + 1))
			else
				cmp="제안값과 다름(미확정)"
			fi
		fi
	fi
	printf '%s | %s | %s | %s | %s\n' "$item" "$appx" "$used" "$conf" "$cmp"
}

# 확정 여부는 requirements.md 부록 A "확정 기록"(2026-10-18)을 따른다. 기록이 바뀌면 이 표의
# Y/N을 같이 고친다.
write_appendix_a() {
	local kv n a used
	echo "item | appendix_A_value | this_run_value | confirmed | comparison"
	appx_row "monitoring_attrs sample_us" 5000 "$SAMPLE_US" Y
	appx_row "monitoring_attrs aggr_us" 100000 "$AGGR_US" Y
	appx_row "monitoring_attrs update_us" 1000000 "$UPDATE_US" Y
	appx_row "monitoring_attrs nr_regions min" "sysfs 기본값 유지" "${NR_MIN:-sysfs 기본값 유지}" N
	appx_row "monitoring_attrs nr_regions max" "sysfs 기본값 유지" "${NR_MAX:-sysfs 기본값 유지}" N
	for kv in $SAMON_DEFAULTS_APPX; do
		n=${kv%%=*}; a=${kv#*=}
		used=$(rd "$PARM/$n")
		appx_row "$n" "$a" "$used" Y
	done
	appx_row "LRU_SORT cold_min_age (us)" 10000000 "$COLD_MIN_AGE" N
	appx_row "LRU_SORT 그 외(quota, hot_thres)" "기본값 유지" "saved.txt lru_sort.* 참조" N "비교 안 함"
	appx_row "LRU_SORT kdamond_pid 확인 대기 (s)" 5 "$PID_WAIT" N
	appx_row "측정 구간 (s)" 120 "$SECS" N
	appx_row "ramp (s)" 10 "$RAMP" N
	appx_row "반복" 5 "$REPS" N
	appx_row "memory.max" 768M "$MEM" N
	appx_row "loop pass bs" 128k "$SWL_LOOP_BS" N
	appx_row "seqwrite writer bs" 1M "$SWL_WRITER_BS" N
	appx_row "samon_pN 단독 구성 측정 여부(--with-pn)" "1차는 없음" "$([ "$WITH_PN" = 1 ] && echo 있음 || echo 없음)" N \
		"$([ "$WITH_PN" = 1 ] && echo '2차 측정(User 결정 필요)' || echo '1차')"
	appx_row "Build_Script MemTotal 하한 (kB)" 7500000 "하네스 밖" Y "해당 없음"
	appx_row "Verify_Script 판정 수치 P1_MIN_PCT/RAND_MAX_PCT/P2_PASS_S/Q_WAIT_S/IDLE_HOLD_MS" "50/5/4/5/600000" "하네스 밖" Y "해당 없음"
	appx_row "판정 배수 k" 2 "summarize.py --k" N "해당 없음"
	appx_row "summarize.py sd = 0 바닥값" "두지 않음" "summarize.py" N "해당 없음"
	appx_row "평가 문서 위치" /home/sim1010/cap2/samon-eval.md "하네스 밖" N "해당 없음"
}

write_env_file() {
	local p f n git_head git_dirty cmd
	git_head=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo NA)
	git_dirty=$(git -C "$HERE" status --porcelain -- . 2>/dev/null | wc -l)
	printf -v cmd '%q ' "$0" "${ORIG_ARGS[@]}"
	{
		echo "# samon_bench.sh environment record (R10.8, R11.2, R1.6)"
		echo "[run]"
		echo "started_at=$(date -Is)"
		echo "started_at_ns=$START_NS"
		echo "harness=$HERE/samon_bench.sh"
		echo "harness_git_head=$git_head"
		echo "harness_git_dirty_files=$git_dirty"
		echo "command=${cmd% }"
		echo "dry_run=$DRY"
		echo
		echo "[system]"
		echo "uname_v=$(uname -v)"
		echo "uname_r=$(uname -r)"
		echo "cmdline=$(rd /proc/cmdline)"
		echo "memtotal_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
		echo "vcpus=$(nproc)"
		echo "clk_tck=$(getconf CLK_TCK)"
		echo "target_disk=${DISK:-NA}"
		echo "target_disk_dev=${DMAJ:-NA}:${DMIN:-NA}"
		echo "disk_model=$([ -n "$DISK" ] && rd "/sys/block/$DISK/device/model" || echo NA)"
		echo "workload_dir=$DIR"
		echo "workload_dir_source=${DIR_SOURCE:-NA}"
		echo "workload_dir_fstype=${DIR_FSTYPE:-NA}"
		echo "lru_gen_enabled_start=$([ "$DRY" = 1 ] && rd "$LRUGEN" || echo "$SAVED_LRU_GEN")"
		echo
		echo "[options]"
		echo "workload=$WL"
		echo "memory_max=$MEM"
		echo "memory_max_bytes=$MEM_BYTES"
		echo "measure_secs=$SECS"
		echo "ramp_secs=$RAMP"
		echo "reps=$REPS"
		echo "outdir=$OUT"
		echo "with_pn=$WITH_PN"
		echo "seed=$SEED"
		echo "cold_min_age_us=$COLD_MIN_AGE"
		echo "pid_wait_s=$PID_WAIT"
		echo "q_warn_pct=$Q_WARN_PCT"
		echo
		echo "[monitoring_attrs] (SAMON kdamond, written before every SAMON kdamond start, R10.14)"
		echo "sample_us=$SAMPLE_US"
		echo "aggr_us=$AGGR_US"
		echo "update_us=$UPDATE_US"
		echo "nr_regions_min=${NR_MIN:-sysfs-default (per-run value in runs.csv mon_nr_min)}"
		echo "nr_regions_max=${NR_MAX:-sysfs-default (per-run value in runs.csv mon_nr_max)}"
		echo "kdamond_sysfs_current_sample_us=$(rd "$KD/0/contexts/0/monitoring_attrs/intervals/sample_us")"
		echo "kdamond_sysfs_current_aggr_us=$(rd "$KD/0/contexts/0/monitoring_attrs/intervals/aggr_us")"
		echo "kdamond_sysfs_current_update_us=$(rd "$KD/0/contexts/0/monitoring_attrs/intervals/update_us")"
		echo "kdamond_sysfs_current_nr_regions_min=$(rd "$KD/0/contexts/0/monitoring_attrs/nr_regions/min")"
		echo "kdamond_sysfs_current_nr_regions_max=$(rd "$KD/0/contexts/0/monitoring_attrs/nr_regions/max")"
		echo
		echo "[workload_params] (actual values; *_over_mem = file size / memory.max, R11.2)"
		swl_describe
		echo
		echo "[samon_params] ($PARM, read at start)"
		for f in "$PARM"/*; do
			[ -e "$f" ] || { echo "(none readable)"; break; }
			n=$(basename "$f"); echo "$n=$(rd "$f")"
		done
		echo
		echo "[lru_sort_params] ($LRUP, read at start; statistics are read once here, before any measurement)"
		for f in "$LRUP"/*; do
			[ -e "$f" ] || { echo "(none readable)"; break; }
			n=$(basename "$f"); echo "$n=$(rd "$f")"
		done
		echo
		echo "[appendix_A]"
		write_appendix_a
		echo
		echo "[tools]"
		for p in fio python3 bpftrace cachestat-bpfcc fincore; do
			echo "$p=$(command -v "$p" 2>/dev/null || echo NA)"
		done
		echo "fio_version=$(fio --version 2>/dev/null || echo NA)"
		echo "python_version=$(python3 --version 2>&1)"
	} > "$OUT/env.txt"
	if [ "$APPX_MISMATCH" -gt 0 ]; then
		log "WARNING: $APPX_MISMATCH confirmed Appendix A value(s) differ from this run (see [appendix_A] in $OUT/env.txt)"
	fi
}

# ---------------------------------------------------------------------------
# prefill (R11.1(c)): cgroup 밖, fsync
# ---------------------------------------------------------------------------
prefill_workload() {
	log "prefill ($WL) in $DIR"
	swl_prefill "$WL" "$DIR" || { log "prefill failed"; return 1; }
	sync
	return 0
}

# ---------------------------------------------------------------------------
# restore (R10.10, 요구사항 10 기준 3)
# ---------------------------------------------------------------------------
# 정상 종료, 오류, SIGINT, SIGTERM 모두 EXIT trap으로 온다. 원래 종료 코드를 보존하되
# 복원 불일치가 있으면 0이 아닌 값으로 바꾼다.
#
# 설계 원칙
#  - 멱등: 어느 단계도 이미 복원된 상태에서는 아무것도 쓰지 않는다(현재 값이 저장 값과 같으면 쓰기 생략).
#  - 부분 설정 허용: cgroup이 없거나, kdamond를 켠 적이 없거나, cachestat을 띄운 적이 없어도 넘어간다.
#  - 한 단계가 실패해도 다음 단계로 간다. 성패는 마지막 restore_verify가 *다시 읽은 값*으로만 정한다.
#  - 경로는 KD, PARM, LRUP, LRUGEN, CG 변수만 쓴다(SB_* 로 가짜 트리를 가리키면 시험할 수 있다).
#  - LRU_SORT enabled는 시작 때 Y였더라도 N으로 남긴다(기준 10 (2): "enabled=N으로 끄고").
#  - 복원 중에는 INT/TERM을 무시한다. 두 번째 Ctrl-C가 복원을 끊으면 시스템이 반쯤 복원된 채 남는다.

# 파일에 한 줄 쓰기. 실패해도 메시지 없이 상태 코드만 돌려준다.
rwrite() { { printf '%s\n' "$2" > "$1"; } 2>/dev/null; }

# 파일 내용(끝 개행 제거)을 출력. 읽지 못하면 1.
rread() {
	local v
	v=$(cat "$1" 2>/dev/null) || return 1
	printf '%s' "$v"
}

# 정수로 읽히는 값(10진, 0x 16진, 음수)이면 10진 정수를 출력, 아니면 1.
num_of() {
	local v=$1 neg=""
	case $v in -*) neg=-; v=${v#-} ;; esac
	case $v in
	0[xX]?*)
		[[ ${v#0?} =~ ^[0-9a-fA-F]+$ ]] || return 1
		printf '%d' "$neg$v" ;;
	''|*[!0-9]*) return 1 ;;
	*) printf '%s%s' "$neg" "$(norm_uint "$v")" ;;
	esac
}

# 저장 값과 현재 값이 같은가: 문자열이 같거나, 둘 다 정수로 읽히고 값이 같다.
# (lru_gen은 0x0007 / 7 같은 표기 차이를 허용, design T6 실행 하나 1단계)
vals_equal() {
	local a b
	[ "$1" = "$2" ] && return 0
	a=$(num_of "$1") || return 1
	b=$(num_of "$2") || return 1
	[ "$a" = "$b" ]
}

# 현재 값이 저장 값과 다를 때만 쓴다. 쓰기 실패는 경고만 남기고 넘어간다(판정은 verify가 한다).
restore_one() {
	local file=$1 want=$2 name=$3 cur
	if cur=$(rread "$file") && vals_equal "$want" "$cur"; then
		return 0
	fi
	rwrite "$file" "$want" || log "restore: cannot write $name ($file)"
	return 0
}

# 기다림 반복 횟수(0.2초 단위)
restore_ticks() { echo $((RESTORE_WAIT_S * 5)); }

# 1. 진행 중인 워크로드 정리: cgroup.kill, rmdir. cgroup이 없으면 할 일이 없다.
restore_kill_workload() {
	local p i=0 n killed=0
	[ -n "$CG" ] && [ -d "$CG" ] || return 0
	if [ -e "$CG/cgroup.kill" ] && rwrite "$CG/cgroup.kill" 1; then
		killed=1
	else
		log "restore: cgroup.kill unusable in $CG; killing cgroup.procs members"
	fi
	if [ "$killed" = 0 ] && [ -r "$CG/cgroup.procs" ]; then
		while read -r p; do
			[ -n "$p" ] && [ "$p" != "$$" ] && kill -KILL "$p" 2>/dev/null
		done < "$CG/cgroup.procs"
	fi
	# 프로세스가 사라져도 cgroup이 비는 데 시간이 걸린다(EBUSY)
	n=$(restore_ticks)
	while [ -d "$CG" ] && ! rmdir "$CG" 2>/dev/null; do
		[ "$i" -lt "$n" ] || { log "restore: cannot remove $CG"; break; }
		i=$((i + 1))
		sleep 0.2
	done
	return 0
}

# 1. cachestat 종료. PID가 없거나 이미 죽었으면 넘어간다.
restore_stop_cachestat() {
	local pid=$CACHESTAT_PID i n
	[ -n "$pid" ] || return 0
	if ! is_uint "$pid" || ! kill -0 "$pid" 2>/dev/null; then
		CACHESTAT_PID=""
		return 0
	fi
	kill -TERM "$pid" 2>/dev/null
	n=$(restore_ticks)
	for ((i = 0; i < n; i++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.2
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -KILL "$pid" 2>/dev/null
		sleep 0.2
	fi
	kill -0 "$pid" 2>/dev/null || CACHESTAT_PID=""
	return 0
}

# 2. SAMON kdamond state off. 상태가 on이 아니면 쓰지 않는다. kdamond가 없으면(nr_kdamonds=0) 이미 꺼진 것.
restore_samon_off() {
	local st=$KD/0/state cur i n
	[ -e "$st" ] || return 0
	cur=$(rread "$st") || cur=""
	[ "$cur" != off ] || return 0
	if [ "$cur" = on ] && [ "$SAMON_KD_STARTED" != 1 ]; then
		log "restore: SAMON kdamond is on although this harness did not start it; turning it off"
	fi
	rwrite "$st" off || log "restore: cannot write samon kdamond state ($st)"
	n=$(restore_ticks)
	for ((i = 0; i < n; i++)); do
		[ "$(rread "$st")" != on ] && break
		sleep 0.2
	done
	return 0
}

# 3. LRU_SORT: enabled=N을 먼저, 그다음 나머지 쓰기 가능한 파라미터를 saved 값으로.
restore_lrusort() {
	local n
	if [ -e "$LRUP/enabled" ]; then
		if [ "${SAVED_LRUSORT[enabled]:-N}" != N ]; then
			log "restore: lru_sort.enabled was ${SAVED_LRUSORT[enabled]} at start; leaving it N (R10 criterion 10)"
		fi
		restore_one "$LRUP/enabled" N lru_sort.enabled
	fi
	for n in "${SAVED_LRUSORT_NAMES[@]}"; do
		[ "$n" != enabled ] || continue
		restore_one "$LRUP/$n" "${SAVED_LRUSORT[$n]}" "lru_sort.$n"
	done
	return 0
}

# 4. SAMON 모듈 파라미터. samon_opt_b는 bool이라 읽은 Y/N을 그대로 쓴다.
restore_samon_params() {
	local n
	for n in $SAMON_WRITTEN_PARAMS; do
		[ "${SAVED_SAMON[$n]+set}" = set ] || continue
		restore_one "$PARM/$n" "${SAVED_SAMON[$n]}" "samon.$n"
	done
	return 0
}

# 5. lru_gen enabled 원문 값. 저장하지 못했으면(빈 값) 건드리지 않는다.
restore_lru_gen() {
	[ -n "$SAVED_LRU_GEN" ] || return 0
	restore_one "$LRUGEN" "$SAVED_LRU_GEN" lru_gen
	return 0
}

# 불일치 하나를 기록하고 출력
restore_mismatch() {
	RESTORE_MISMATCH+=("$1")
	echo "BENCH RESTORE MISMATCH $1: expected '$2' got '$3'" >&2
}

# 값 하나를 다시 읽어 저장 값과 비교
restore_check_one() {
	local file=$1 want=$2 name=$3 cur
	if ! cur=$(rread "$file"); then
		restore_mismatch "$name" "$want" "<unreadable>"
	elif ! vals_equal "$want" "$cur"; then
		restore_mismatch "$name" "$want" "$cur"
	fi
}

# 6. 모든 항목을 단계 결과와 상관없이 다시 읽어 확인한다. 불일치가 있으면 이름을 출력하고 1.
# 성공하면 마지막 출력 줄이 "restore verified: no mismatch"이다(tasks 30.1 성공 조건).
restore_verify() {
	local n cur
	RESTORE_MISMATCH=()

	if [ -n "$CG" ] && [ -d "$CG" ]; then
		restore_mismatch cgroup "removed" "still exists: $CG"
	fi
	if [ -n "$CACHESTAT_PID" ] && kill -0 "$CACHESTAT_PID" 2>/dev/null; then
		restore_mismatch cachestat "stopped" "pid $CACHESTAT_PID alive"
	fi
	if [ -e "$KD/0/state" ]; then
		if ! cur=$(rread "$KD/0/state"); then
			restore_mismatch samon_kdamond_state "off" "<unreadable>"
		elif [ "$cur" = on ]; then
			restore_mismatch samon_kdamond_state "off" "$cur"
		fi
	fi
	if [ -e "$LRUP/enabled" ]; then
		restore_check_one "$LRUP/enabled" N lru_sort.enabled
	fi
	for n in "${SAVED_LRUSORT_NAMES[@]}"; do
		[ "$n" != enabled ] || continue
		restore_check_one "$LRUP/$n" "${SAVED_LRUSORT[$n]}" "lru_sort.$n"
	done
	for n in $SAMON_WRITTEN_PARAMS; do
		[ "${SAVED_SAMON[$n]+set}" = set ] || continue
		restore_check_one "$PARM/$n" "${SAVED_SAMON[$n]}" "samon.$n"
	done
	if [ -n "$SAVED_LRU_GEN" ]; then
		restore_check_one "$LRUGEN" "$SAVED_LRU_GEN" lru_gen
	fi

	if [ "${#RESTORE_MISMATCH[@]}" -gt 0 ]; then
		echo "BENCH RESTORE FAIL: ${#RESTORE_MISMATCH[@]} item(s) differ from saved state: ${RESTORE_MISMATCH[*]}" >&2
		return 1
	fi
	log "restore verified: no mismatch"
	return 0
}

# 위 단계를 차례로 실행하고 verify 결과를 돌려준다(여러 번 불러도 안전).
restore_state() {
	restore_kill_workload
	restore_stop_cachestat
	restore_samon_off
	restore_lrusort
	restore_samon_params
	restore_lru_gen
	restore_verify
}

restore() {
	local rc=$?
	set +u			# 복원 중 미정의 변수로 중간에 죽지 않게
	trap - EXIT
	trap '' INT TERM
	[ "$RESTORE_ARMED" = 1 ] || exit "$rc"
	RESTORE_ARMED=0
	is_uint "$RESTORE_WAIT_S" || RESTORE_WAIT_S=10
	if [ "$DRY" = 0 ]; then
		restore_state || { [ "$rc" -ne 0 ] || rc=1; }
	elif [ -n "${RUN_WL_PID:-}" ]; then
		# 드라이런은 cgroup이 없으므로 워크로드 서브셸과 그 자식(fio)을 직접 정리한다
		pkill -TERM -P "$RUN_WL_PID" 2>/dev/null
		kill -TERM "$RUN_WL_PID" 2>/dev/null
	fi
	exit "$rc"
}

# 상태를 읽어 저장한 뒤에만 건다(design T6 시작 전 3)
install_traps() {
	RESTORE_ARMED=1
	trap restore EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# ---------------------------------------------------------------------------
# 구성 표와 실행 순서 (24.4, 요구사항 10 기준 1·13, design T6)
# ---------------------------------------------------------------------------
# 값은 `kd lrusort lrugen act`이다.
#   kd       SAMON kdamond: off | on
#   lrusort  DAMON_LRU_SORT: N | Y
#   lrugen   lru_gen enabled: start(saved.txt의 시작 원문 값) | 0
#   act      다섯 글자 p1 p2 p3 p4 opt_b (각각 0/1)
declare -A CFG=(
	[off]="off N start 00000"          [off2]="off N start 00000"
	[damon]="off Y start 00000"        [samon_observe]="on N start 00000"
	[samon_all]="on N start 11110"
	[samon_p1]="on N start 10000"      [samon_p2]="on N start 01000"
	[samon_p3]="on N start 00100"      [samon_p4]="on N start 00010"
	[off_classic]="off N 0 00000"      [damon_classic]="off Y 0 00000"
	[samon_all_classic]="on N 0 11110"
	[samon_p1_classic]="on N 0 10000"  [samon_p4_classic]="on N 0 00010"
)

# 워크로드별 구성 이름 목록(공백으로 구분, 표 순서). 공통 off, damon, samon_observe, samon_all
# (+ --with-pn이면 samon_p1~p4). mixed는 off2를 더하고, mixed와 seqwrite는 off_classic, damon_classic,
# samon_all_classic(+ --with-pn이면 samon_p1_classic, samon_p4_classic)을 더한다.
configs_for_workload() {
	local wl=${1:-$WL} pn=${2:-$WITH_PN}
	local -a l=(off)
	[ "$wl" != mixed ] || l+=(off2)
	l+=(damon samon_observe samon_all)
	[ "$pn" != 1 ] || l+=(samon_p1 samon_p2 samon_p3 samon_p4)
	case "$wl" in
	mixed|seqwrite)
		l+=(off_classic damon_classic samon_all_classic)
		[ "$pn" != 1 ] || l+=(samon_p1_classic samon_p4_classic) ;;
	esac
	echo "${l[*]}"
}

# 구성 이름 하나를 CFG_KD, CFG_LRU, CFG_GEN, CFG_ACT, CFG_FAMILY(off|damon|samon)로 푼다.
cfg_parse() {
	local c=$1
	[ "${CFG[$c]+set}" = set ] || { run_fail config_name "'$c' is not in the config table"; return 1; }
	read -r CFG_KD CFG_LRU CFG_GEN CFG_ACT <<< "${CFG[$c]}"
	if [ "$CFG_KD" = on ]; then CFG_FAMILY=samon
	elif [ "$CFG_LRU" = Y ]; then CFG_FAMILY=damon
	else CFG_FAMILY=off
	fi
	return 0
}

# ---------------------------------------------------------------------------
# 실행 하나 (24.4, 요구사항 10 기준 2·3·13·14, 요구사항 8 기준 23)
# ---------------------------------------------------------------------------
# 현재 실행의 식별 정보와 확인한 상태. 24.5가 CSV 행을 만들 때 쓴다.
#   RUN_NO RUN_REP RUN_CFG   order.txt의 줄 번호(1부터), 반복, 구성 이름
#   RUN_PFX                  실행별 파일 접두어($OUT/run<N>): .fio .json .passes.csv .state
#   RUN_STATE[열]            실제로 다시 읽어 확인한 값(samon_benchlib.py의 열 이름). 해당 없는 열은 키가 없다(NA).
#   RUN_LRU_GEN              실제 적용된 lru_gen enabled 원문(다시 읽은 값)
#   RUN_FIO_RC               워크로드 종료 코드(실행 뒤에만)
RUN_NO=0; RUN_REP=0; RUN_CFG=""; RUN_PFX=""; RUN_LRU_GEN=""; RUN_FIO_RC=""; RUN_WL_PID=""
CFG_KD=""; CFG_LRU=""; CFG_GEN=""; CFG_ACT=""; CFG_FAMILY=""
declare -A RUN_STATE=()
STATE_WAIT_S=${SB_STATE_WAIT:-10}	# state, enabled 전환을 기다리는 최대 초(시험용 SB_STATE_WAIT)
DROPCACHES=${SB_DROP:-/proc/sys/vm/drop_caches}

# 확인·쓰기 실패: 항목과 값을 출력하고 1을 돌려준다. 호출자는 `|| return 1`로 중단한다(기준 3).
run_fail() {
	echo "BENCH RUN FAIL $1: ${2:-} [run=$RUN_NO rep=$RUN_REP config=$RUN_CFG]" >&2
	return 1
}

# Y/N을 1/0으로(그 외는 그대로). bool 모듈 파라미터는 1을 써도 Y로 읽힌다.
bool01() {
	case "$1" in Y|y) echo 1 ;; N|n) echo 0 ;; *) printf '%s' "$1" ;; esac
}

# 같은 값인가: vals_equal(문자열 또는 정수 동치) 또는 bool01 동치
same_val() {
	vals_equal "$1" "$2" && return 0
	[ "$(bool01 "$1")" = "$(bool01 "$2")" ]
}

# FILE이 WANT와 같아질 때까지 최대 SECS초 기다린다(0.2초 간격, 최소 한 번 읽는다).
wait_val() {
	local f=$1 want=$2 secs=$3 i n cur
	n=$((secs * 5))
	for ((i = 0; i <= n; i++)); do
		cur=$(rread "$f") && same_val "$want" "$cur" && return 0
		[ "$i" -lt "$n" ] && sleep 0.2
	done
	return 1
}

# FILE에 WANT를 쓰고 다시 읽어 일치를 확인한다. 항목 이름은 ITEM.
set_verify() {
	local f=$1 want=$2 item=$3 cur
	rwrite "$f" "$want" || { run_fail "$item" "cannot write '$want' to $f"; return 1; }
	cur=$(rread "$f") || { run_fail "$item" "wrote '$want' to $f, cannot read it back"; return 1; }
	same_val "$want" "$cur" || { run_fail "$item" "wrote '$want' to $f, read back '$cur'"; return 1; }
	return 0
}

# 이미 같은 값이면 쓰지 않는다(sysfs 구조 파일은 같은 값을 다시 쓰면 하위 디렉터리가 다시 만들어질 수 있다).
ensure_val() {
	local f=$1 want=$2 item=$3 cur
	if cur=$(rread "$f") && same_val "$want" "$cur"; then return 0; fi
	set_verify "$f" "$want" "$item"
}

# 1. lru_gen enabled: 구성이 start면 시작 원문 값, 0이면 0. 쓰고 다시 읽어 정수로 비교한다.
step_lru_gen() {
	local want=$CFG_GEN cur
	[ "$want" != start ] || want=$SAVED_LRU_GEN
	[ -n "$want" ] || { run_fail lru_gen "no saved start value for config $RUN_CFG"; return 1; }
	set_verify "$LRUGEN" "$want" lru_gen || return 1
	cur=$(rread "$LRUGEN") || cur=""
	RUN_LRU_GEN=$cur
	return 0
}

# 2. 측정 cgroup: 남은 것을 지우고 새로 만들어 memory.max, memory.swap.max = 0을 쓰고 다시 읽는다.
cg_remove() {
	[ -d "$CG" ] || return 0
	restore_kill_workload
	[ ! -d "$CG" ] || { run_fail cgroup "cannot remove $CG"; return 1; }
	return 0
}

step_cgroup() {
	local cur b
	cg_remove || return 1
	mkdir "$CG" 2>/dev/null || { run_fail cgroup "cannot create $CG"; return 1; }
	# memory.max는 바이트로 읽히므로 IEC 크기로 바꿔 비교한다
	rwrite "$CG/memory.max" "$MEM" || { run_fail cgroup_memory_max "cannot write '$MEM' to $CG/memory.max"; return 1; }
	cur=$(rread "$CG/memory.max") || { run_fail cgroup_memory_max "wrote '$MEM', cannot read it back"; return 1; }
	b=$(swl_bytes "$cur" 2>/dev/null) && [ "$b" = "$MEM_BYTES" ] ||
		{ run_fail cgroup_memory_max "wrote '$MEM' ($MEM_BYTES bytes), read back '$cur'"; return 1; }
	set_verify "$CG/memory.swap.max" 0 cgroup_memory_swap_max || return 1
	return 0
}

# 3, 4. sync와 drop_caches=3
step_sync_drop() {
	sync || { run_fail sync "sync failed"; return 1; }
	rwrite "$DROPCACHES" 3 || { run_fail drop_caches "cannot write 3 to $DROPCACHES"; return 1; }
	return 0
}

# --- 구성 시작과 확인 (기준 2, 14) -----------------------------------------
# SAMON kdamond를 멈춘다. state 파일이 없으면 kdamond 자체가 없으니 멈춘 것이다.
samon_stop() {
	local st=$KD/0/state cur
	[ -e "$st" ] || return 0
	cur=$(rread "$st") || { run_fail samon_kdamond_state "cannot read $st"; return 1; }
	if [ "$cur" != off ]; then
		rwrite "$st" off || { run_fail samon_kdamond_state "state was '$cur', cannot write off"; return 1; }
		wait_val "$st" off "$STATE_WAIT_S" ||
			{ run_fail samon_kdamond_state "wrote off, read '$(rread "$st")' after ${STATE_WAIT_S}s"; return 1; }
	fi
	return 0
}

# LRU_SORT를 N으로 두고 kdamond_pid = -1을 확인한다. Y로 남아 있으면 N을 쓴다(알림만 남긴다).
lrusort_stop() {
	local cur
	cur=$(rread "$LRUP/enabled") || { run_fail lrusort_enabled "cannot read $LRUP/enabled"; return 1; }
	if [ "$(bool01 "$cur")" != 0 ]; then
		log "run $RUN_NO: LRU_SORT enabled='$cur'; writing N before starting config $RUN_CFG"
		rwrite "$LRUP/enabled" N || { run_fail lrusort_enabled "was '$cur', cannot write N"; return 1; }
		wait_val "$LRUP/enabled" N "$STATE_WAIT_S" ||
			{ run_fail lrusort_enabled "wrote N, read '$(rread "$LRUP/enabled")'"; return 1; }
	fi
	wait_val "$LRUP/kdamond_pid" -1 "$PID_WAIT" ||
		{ run_fail lrusort_kdamond_pid "expected -1, read '$(rread "$LRUP/kdamond_pid")' (waited ${PID_WAIT}s)"; return 1; }
	return 0
}

# 마지막으로 읽은 상태를 RUN_STATE에 기록한다(기준 4). 해당 없는 열은 넣지 않는다.
record_common_state() {
	local v
	if [ -e "$KD/0/state" ]; then v=$(rread "$KD/0/state") || v=NA; else v=off; fi
	RUN_STATE[samon_kd_state]=$v
	v=$(rread "$LRUP/enabled") || v=NA; RUN_STATE[lrusort_enabled]=$v
	v=$(rread "$LRUP/kdamond_pid") || v=NA; RUN_STATE[lrusort_pid]=$v
	RUN_STATE[lru_gen_enabled]=$RUN_LRU_GEN
}

start_off() {
	samon_stop || return 1
	lrusort_stop || return 1
	record_common_state
}

start_damon() {
	local pid i n
	samon_stop || return 1
	lrusort_stop || return 1
	set_verify "$LRUP/wmarks_high" 1000 lrusort_wmarks_high || return 1
	set_verify "$LRUP/wmarks_mid" 999 lrusort_wmarks_mid || return 1
	set_verify "$LRUP/wmarks_low" 0 lrusort_wmarks_low || return 1
	set_verify "$LRUP/cold_min_age" "$COLD_MIN_AGE" lrusort_cold_min_age || return 1
	# commit_inputs는 쓰지 않는다(기준 2(b))
	set_verify "$LRUP/enabled" Y lrusort_enabled || return 1
	n=$((PID_WAIT * 5))
	for ((i = 0; i <= n; i++)); do
		pid=$(rread "$LRUP/kdamond_pid") || pid=""
		if is_uint "$pid" && [ "$pid" -gt 0 ] && [ -d "/proc/$pid" ]; then
			record_common_state
			return 0
		fi
		[ "$i" -lt "$n" ] && sleep 0.2
	done
	run_fail lrusort_kdamond_pid "expected a live pid > 0 within ${PID_WAIT}s after enabled=Y, read '${pid:-<unreadable>}' (/proc/${pid:-?} $([ -d "/proc/${pid:-x}" ] && echo exists || echo missing))"
	return 1
}

# SAMON kdamond의 구조 sysfs(nr_kdamonds, nr_contexts, operations, nr_targets). 이미 맞으면 쓰지 않는다.
samon_structure() {
	ensure_val "$KD/nr_kdamonds" 1 samon_nr_kdamonds || return 1
	ensure_val "$KD/0/contexts/nr_contexts" 1 samon_nr_contexts || return 1
	ensure_val "$KD/0/contexts/0/operations" saddr samon_operations || return 1
	ensure_val "$KD/0/contexts/0/targets/nr_targets" 1 samon_nr_targets || return 1
}

# monitoring_attrs를 kdamond를 켜기 전에 쓰고 다시 읽어 확인한다(기준 14).
# nr_regions는 --nr-min/--nr-max가 없으면 쓰지 않고 sysfs 기본값을 읽어 기록만 한다.
samon_attrs() {
	local a=$KD/0/contexts/0/monitoring_attrs v
	set_verify "$a/intervals/sample_us" "$SAMPLE_US" mon_sample_us || return 1
	set_verify "$a/intervals/aggr_us" "$AGGR_US" mon_aggr_us || return 1
	set_verify "$a/intervals/update_us" "$UPDATE_US" mon_update_us || return 1
	if [ -n "$NR_MIN" ]; then set_verify "$a/nr_regions/min" "$NR_MIN" mon_nr_min || return 1; fi
	if [ -n "$NR_MAX" ]; then set_verify "$a/nr_regions/max" "$NR_MAX" mon_nr_max || return 1; fi
	RUN_STATE[mon_sample_us]=$(rread "$a/intervals/sample_us") || return 1
	RUN_STATE[mon_aggr_us]=$(rread "$a/intervals/aggr_us") || return 1
	RUN_STATE[mon_update_us]=$(rread "$a/intervals/update_us") || return 1
	v=$(rread "$a/nr_regions/min") || { run_fail mon_nr_min "cannot read $a/nr_regions/min"; return 1; }
	RUN_STATE[mon_nr_min]=$v
	v=$(rread "$a/nr_regions/max") || { run_fail mon_nr_max "cannot read $a/nr_regions/max"; return 1; }
	RUN_STATE[mon_nr_max]=$v
	return 0
}

# stats의 q_cap > 0(큐 할당 성공)을 PID_WAIT초 안에 확인한다(요구사항 7 기준 5의 init은 kdamond 스레드가 한다).
samon_check_qcap() {
	local i n q=""
	n=$((PID_WAIT * 5))
	for ((i = 0; i <= n; i++)); do
		q=$(awk -F= '$1 == "q_cap" { print $2 + 0 }' "$DBG/stats" 2>/dev/null) || q=""
		is_uint "$q" && [ "$q" -gt 0 ] && return 0
		[ "$i" -lt "$n" ] && sleep 0.2
	done
	run_fail samon_q_cap "expected q_cap > 0 in $DBG/stats within ${PID_WAIT}s, read '${q:-<none>}'"
	return 1
}

start_samon() {
	local i p want cur
	lrusort_stop || return 1
	samon_stop || return 1
	samon_structure || return 1
	samon_attrs || return 1
	# 토글 쓰기: act_p1..p4, opt_b, samon_dbg_lba = 0(요구사항 8 기준 23), 대상 디스크
	for i in 1 2 3 4; do
		set_verify "$PARM/samon_act_p$i" "${CFG_ACT:$((i - 1)):1}" "samon_act_p$i" || return 1
	done
	set_verify "$PARM/samon_opt_b" "${CFG_ACT:4:1}" samon_opt_b || return 1
	set_verify "$PARM/samon_dbg_lba" 0 samon_dbg_lba || return 1
	set_verify "$PARM/samon_dev_major" "$DMAJ" samon_dev_major || return 1
	set_verify "$PARM/samon_dev_minor" "$DMIN" samon_dev_minor || return 1
	# 켜기 직전에 표시한다(쓰기가 실패해도 켜졌을 수 있으므로 쓰기 전). restore가 쓴다.
	SAMON_KD_STARTED=1
	rwrite "$KD/0/state" on || { run_fail samon_kdamond_state "cannot write on to $KD/0/state (read '$(rread "$KD/0/state")')"; return 1; }
	wait_val "$KD/0/state" on "$STATE_WAIT_S" ||
		{ run_fail samon_kdamond_state "wrote on, read '$(rread "$KD/0/state")' after ${STATE_WAIT_S}s"; return 1; }
	samon_check_qcap || return 1
	# 켠 뒤 토글을 다시 읽어 표와 비교한다(opt_b는 Y/N을 1/0으로)
	record_common_state
	for i in 1 2 3 4; do
		want=${CFG_ACT:$((i - 1)):1}
		cur=$(rread "$PARM/samon_act_p$i") || { run_fail "samon_act_p$i" "cannot read $PARM/samon_act_p$i"; return 1; }
		same_val "$want" "$cur" || { run_fail "samon_act_p$i" "expected '$want', read '$cur'"; return 1; }
		RUN_STATE[act_p$i]=$cur
	done
	cur=$(rread "$PARM/samon_opt_b") || { run_fail samon_opt_b "cannot read $PARM/samon_opt_b"; return 1; }
	same_val "${CFG_ACT:4:1}" "$cur" || { run_fail samon_opt_b "expected '${CFG_ACT:4:1}', read '$cur'"; return 1; }
	RUN_STATE[opt_b]=$(bool01 "$cur")
	p=$(rread "$PARM/samon_dbg_lba") || p=""
	same_val 0 "$p" || { run_fail samon_dbg_lba "expected '0', read '${p:-<unreadable>}'"; return 1; }
	return 0
}

config_start() {
	case "$CFG_FAMILY" in
	off)   start_off ;;
	damon) start_damon ;;
	samon) start_samon ;;
	esac
}

# 구성을 정지 상태로 돌린다(기준 13 끝: damon은 LRU_SORT N, SAMON은 kdamond off).
config_stop() {
	case "$CFG_FAMILY" in
	damon) lrusort_stop ;;
	samon) samon_stop ;;
	*) return 0 ;;
	esac
}

# 실행 상태를 CSV 행 도구가 읽는 `열=값` 파일로 쓴다(samon_benchlib.py row --state-file).
write_run_state_file() {
	local k
	{
		echo "run=$RUN_NO"
		echo "workload=$WL"
		echo "rep=$RUN_REP"
		echo "config=$RUN_CFG"
		echo "seed=$SEED"
		for k in "${!RUN_STATE[@]}"; do echo "$k=${RUN_STATE[$k]}"; done | sort
	} > "$RUN_PFX.state" || { run_fail state_file "cannot write $RUN_PFX.state"; return 1; }
}

# --- 스냅샷, cachestat, CSV 행 (24.5, 요구사항 10 기준 4~7, 요구사항 12 기준 1, design T6) ---
# 각 hook은 실패하면 0이 아닌 값을 돌려주고, run_one은 그 실행을 중단한다(출력은 hook이 한다).
#   hook_before_workload  워크로드 시작 직전: kdamond pid 읽기, cachestat 시작(CACHESTAT_PID)
#   hook_pre_snapshot     ramp 끝 직후: pre 스냅샷(snap_<N>_pre)
#   hook_post_snapshot    워크로드 종료 직후: post 스냅샷(snap_<N>_post), cachestat 종료
#   hook_run_finish       samon_benchlib.py row로 runs.csv에 행 추가(RUN_FIO_RC 사용), 경고 출력
#   hook_teardown         구성 정리(스냅샷이 cgroup 파일을 읽은 뒤): damon은 LRU_SORT N, SAMON은 kdamond off, cgroup 삭제

# 요구사항 10 기준 5의 LRU_SORT 통계 10개. samon_benchlib.py의 LRU_SORT_STATS_KEYS와 같아야 한다(시험이 대조).
LRU_STATS_NAMES="nr_lru_sort_tried_hot_regions nr_lru_sorted_hot_regions nr_lru_sort_tried_cold_regions nr_lru_sorted_cold_regions bytes_lru_sort_tried_hot_regions bytes_lru_sorted_hot_regions bytes_lru_sort_tried_cold_regions bytes_lru_sorted_cold_regions nr_hot_quota_exceeds nr_cold_quota_exceeds"

RUN_KD_PID=""		# 이 실행의 kdamond pid(워크로드 시작 직전에 읽음). 없으면 빈 값
RUN_CS_FILE=""		# 이 실행의 cachestat 출력 파일. cachestat를 띄우지 않았으면 빈 값
CACHESTAT_OK=""		# "": 아직 모름, 1: 쓸 수 있음, 0: 쓸 수 없음(이 결과 디렉터리 전 행 NA)
CSV_ROWS=0

# 시작 때 cachestat를 쓸 수 있는지 한 번 정한다(요구사항 12 기준 1). 드라이런은 BPF가 root를 요구하므로 쓰지 않는다.
cachestat_probe() {
	if [ "$DRY" = 1 ]; then
		CACHESTAT_OK=0
		log "dry run: cachestat not started (cachestat_hit_pct = NA)"
	elif command -v "$CACHESTAT_CMD" >/dev/null 2>&1; then
		CACHESTAT_OK=1
		log "cachestat: using $(command -v "$CACHESTAT_CMD")"
	else
		CACHESTAT_OK=0
		log "WARNING: $CACHESTAT_CMD not found: cachestat_hit_pct = NA in every row of $OUT/runs.csv"
	fi
}

# 워크로드 시작 전에 cgroup 밖에서 `cachestat-bpfcc -T 1`을 띄운다(design T6). BPF 컴파일이 끝나
# 첫 출력이 나올 때까지 최대 CACHESTAT_WAIT_S초 기다린다(측정 시작 전이다). 띄우지 못해도 실행은 계속한다.
# PYTHONUNBUFFERED=1은 파일로 돌릴 때 SIGTERM으로 끝나도 줄이 남게 한다. 환경 변수 접두어와 `&`는
# 래퍼 프로세스 없이 도구를 직접 exec하므로 $!가 종료할 PID이다.
start_cachestat() {
	local out=$OUT/cachestat_$RUN_NO.txt i n
	[ "$CACHESTAT_OK" = 1 ] || return 0
	PYTHONUNBUFFERED=1 "$CACHESTAT_CMD" -T 1 > "$out" 2>&1 &
	CACHESTAT_PID=$!
	RUN_CS_FILE=$out
	n=$((CACHESTAT_WAIT_S * 5))
	for ((i = 0; i < n; i++)); do
		[ -s "$out" ] && break
		kill -0 "$CACHESTAT_PID" 2>/dev/null || break
		sleep 0.2
	done
	if ! kill -0 "$CACHESTAT_PID" 2>/dev/null; then
		log "WARNING: run $RUN_NO: $CACHESTAT_CMD exited at start ($(head -n1 "$out" 2>/dev/null)); cachestat_hit_pct = NA from here on"
		CACHESTAT_PID=""; RUN_CS_FILE=""; CACHESTAT_OK=0
	elif [ ! -s "$out" ]; then
		log "WARNING: run $RUN_NO: $CACHESTAT_CMD printed nothing within ${CACHESTAT_WAIT_S}s; starting the workload anyway"
	fi
	return 0
}

hook_before_workload() {
	local pf="" pid=""
	RUN_KD_PID=""; RUN_CS_FILE=""
	if [ "$DRY" = 0 ]; then
		# LRU_SORT 파라미터 파일은 측정 구간 전에만 읽는다. pid는 이 시점(pre 스냅샷 직전)에 읽는다.
		case "$CFG_FAMILY" in
		samon) pf=$KD/0/pid ;;
		damon) pf=$LRUP/kdamond_pid ;;
		esac
		if [ -n "$pf" ]; then
			pid=$(rread "$pf") || pid=""
			if is_uint "$pid" && [ "$pid" -gt 0 ] && [ -d "$PROC/$pid" ]; then
				RUN_KD_PID=$pid
			else
				log "WARNING: run $RUN_NO: no live kdamond pid in $pf (read '${pid:-<unreadable>}'); kd_cpu_s = NA"
			fi
		fi
	fi
	start_cachestat
}

# 파일 하나를 스냅샷 디렉터리에 복사. 읽지 못하면 파일을 만들지 않고(= 열 NA) 경고하고 1.
snap_copy() {
	local src=$1 dst=$2
	if cat "$src" > "$dst" 2>/dev/null; then return 0; fi
	rm -f "$dst"
	log "WARNING: run $RUN_NO: snapshot cannot read $src"
	return 1
}

# 스냅샷 하나(pre 또는 post)를 snap_<N>_<when>/에 원문으로 저장한다. 읽는 파일은 /proc 3개, cgroup
# memory.stat, SAMON stats(SAMON 계열), LRU_SORT 통계 10개(damon 계열), kdamond /proc/<pid>/stat이다.
# 개별 파일을 못 읽으면 경고만 하고 계속한다(그 열은 NA). 디렉터리를 만들지 못하면 실패다.
take_snapshot() {
	local when=$1 d=$OUT/snap_${RUN_NO}_$1 n v
	mkdir -p "$d" || { run_fail snapshot "cannot create $d"; return 1; }
	date +%s.%N > "$d/ts" || { run_fail snapshot "cannot write $d/ts"; return 1; }
	snap_copy "$PROC/vmstat" "$d/vmstat"
	if head -n 1 "$PROC/stat" > "$d/stat" 2>/dev/null; then :; else rm -f "$d/stat"; log "WARNING: run $RUN_NO: snapshot cannot read $PROC/stat"; fi
	snap_copy "$PROC/meminfo" "$d/meminfo"
	[ "$DRY" = 0 ] || return 0
	snap_copy "$CG/memory.stat" "$d/memory.stat"
	[ "$CFG_FAMILY" != samon ] || snap_copy "$DBG/stats" "$d/samon_stats"
	if [ "$CFG_FAMILY" = damon ]; then
		: > "$d/lru_sort_stats"
		for n in $LRU_STATS_NAMES; do
			if v=$(cat "$LRUP/$n" 2>/dev/null); then
				echo "$n=$v" >> "$d/lru_sort_stats"
			else
				rm -f "$d/lru_sort_stats"
				log "WARNING: run $RUN_NO: snapshot cannot read $LRUP/$n; ls_* columns = NA"
				break
			fi
		done
	fi
	[ -z "$RUN_KD_PID" ] || snap_copy "$PROC/$RUN_KD_PID/stat" "$d/kd_stat"
	return 0
}

hook_pre_snapshot() { take_snapshot pre; }

hook_post_snapshot() {
	local rc=0
	take_snapshot post || rc=1
	# cachestat는 post 직후에 끝낸다. 실행 중에는 restore와 같은 정리 함수를 쓰므로 PID가 비워진다.
	restore_stop_cachestat
	return "$rc"
}

# 실행 번호 N의 행을 만들어 runs.csv에 덧붙인다(첫 행이면 헤더도). 열 정의와 차분은 samon_benchlib.py가 한다.
# 워크로드 종료 코드는 fio_rc 열에 들어간다(0이 아니어도 행은 쓴다. summarize.py가 그 행을 뺀다).
hook_run_finish() {
	local csv=${CSV:-$OUT/runs.csv} pre=$OUT/snap_${RUN_NO}_pre post=$OUT/snap_${RUN_NO}_post
	local out t0 fb
	local -a args=(row --pre "$pre" --post "$post" --workload "$WL"
		--state-file "$RUN_PFX.state" --set "fio_rc=$RUN_FIO_RC" --q-warn-pct "$Q_WARN_PCT")
	[ -s "$csv" ] || args+=(--header)
	[ ! -s "$RUN_PFX.json" ] || args+=(--fio-json "$RUN_PFX.json")
	[ -z "$RUN_CS_FILE" ] || [ ! -s "$RUN_CS_FILE" ] || args+=(--cachestat "$RUN_CS_FILE")
	if [ "$WL" = loop ]; then
		[ ! -r "$RUN_PFX.passes.csv" ] || args+=(--passes-csv "$RUN_PFX.passes.csv")
		t0=$(sed -n 's/^t0_ns=//p' "$RUN_PFX.passes.meta" 2>/dev/null)
		fb=$(sed -n 's/^file_bytes=//p' "$RUN_PFX.passes.meta" 2>/dev/null)
		if is_uint "$t0" && is_uint "$fb"; then
			args+=(--ramp-end-ns "$((t0 + RAMP * 1000000000))" --loop-size-bytes "$fb")
		fi
	fi
	out=$(python3 "$BENCHLIB" "${args[@]}") ||
		{ run_fail csv_row "samon_benchlib.py row failed (see message above)"; return 1; }
	printf '%s\n' "$out" >> "$csv" || { run_fail csv_row "cannot append to $csv"; return 1; }
	CSV_ROWS=$((CSV_ROWS + 1))
	report_row_warnings "${out##*$'\n'}"
	return 0
}

# 방금 쓴 행의 표시 열을 읽어 경고를 출력한다(요구사항 10 기준 5, 6, 요구사항 11 기준 4).
# 값 계산은 samon_benchlib.py가 이미 했다. 여기서는 읽어서 문장으로 바꿀 뿐이다.
report_row_warnings() {
	local kind a b c ctx="run $RUN_NO (rep $RUN_REP, config $RUN_CFG)"
	while read -r kind a b c; do
		case $kind in
		q_warn) log "WARNING: $ctx: queue drops $b exceed ${Q_WARN_PCT}% of requests $a (q_warn=1); the row is excluded from summaries" ;;
		damon_inactive) log "WARNING: $ctx: DAMON_LRU_SORT applied no hot/cold regions (damon_inactive=1); the row is excluded from summaries" ;;
		loop_invalid) log "WARNING: $ctx: only $a completed loop pass(es), need >= 2 (loop_invalid=1); the row is excluded from summaries" ;;
		fio_rc) log "WARNING: $ctx: workload exit code $a (row excluded from summaries)" ;;
		esac
	done < <(python3 - "$HERE" "$1" <<'PY'
import csv, sys
sys.path.insert(0, sys.argv[1])
import samon_benchlib as b
d = dict(zip(b.COLUMNS, next(csv.reader([sys.argv[2]]))))
def total(prefix):
    t = 0
    for i in range(1, 6):
        try:
            t += int(d.get(prefix + str(i), "NA"))
        except ValueError:
            return "NA"
    return t
if d.get("q_warn") == "1":
    print("q_warn", total("s_req_p"), total("s_drop_queue_p"))
if d.get("damon_inactive") == "1":
    print("damon_inactive")
if d.get("loop_invalid") == "1":
    print("loop_invalid", d.get("loop_passes", "NA"))
if d.get("fio_rc") not in ("0", "NA", None):
    print("fio_rc", d["fio_rc"])
PY
)
}

# 구성 정리: 기본은 config_stop과 cgroup 삭제(스냅샷이 cgroup 파일을 읽은 뒤에 불린다).
hook_teardown() {
	[ "$DRY" = 0 ] || return 0
	config_stop || return 1
	cg_remove
}

# 워크로드를 백그라운드로 시작한다. 드라이런은 cgroup 없이 직접 실행한다.
start_workload() {
	if [ "$DRY" = 1 ]; then
		swl_run_r11 "$WL" "$DIR" "$SECS" "$RAMP" "$RUN_PFX" &
	else
		swl_exec_in_cgroup "$CG" swl_run_r11 "$WL" "$DIR" "$SECS" "$RAMP" "$RUN_PFX" &
	fi
	RUN_WL_PID=$!
}

# 실행 하나. 인자: 실행 번호, 반복 번호, 구성 이름. 0이 아닌 값은 실행 실패(하네스 중단)이다.
# 순서(기준 13): lru_gen → cgroup → sync → drop_caches → 구성 시작·확인 → 워크로드.
# 확인 하나라도 실패하면 워크로드를 시작하지 않는다(기준 3). 워크로드가 0이 아닌 코드로 끝난 것은
# 실패가 아니라 RUN_FIO_RC에 남는 값이다(행의 fio_rc, 요약 도구가 그 행을 뺀다). 단 cgroup에 넣지
# 못한 경우(코드 125)는 하네스 실패이다.
run_one() {
	RUN_NO=$1; RUN_REP=$2; RUN_CFG=$3
	RUN_PFX=$OUT/run$RUN_NO
	RUN_STATE=(); RUN_LRU_GEN=""; RUN_FIO_RC=""; RUN_WL_PID=""
	log "run $RUN_NO: rep $RUN_REP config $RUN_CFG"
	cfg_parse "$RUN_CFG" || return 1
	if [ "$DRY" = 1 ]; then
		log "dry run: lru_gen, cgroup, drop_caches and config start skipped"
	else
		step_lru_gen || return 1
		step_cgroup || return 1
		step_sync_drop || return 1
		config_start || return 1
	fi
	write_run_state_file || return 1
	hook_before_workload || return 1

	start_workload
	if [ "$RAMP" -gt 0 ]; then
		# 백그라운드 sleep을 wait하면 INT/TERM trap이 바로 실행된다
		sleep "$RAMP" & wait $!
	fi
	hook_pre_snapshot || return 1
	wait "$RUN_WL_PID"
	RUN_FIO_RC=$?
	RUN_WL_PID=""
	hook_post_snapshot || return 1

	if [ "$DRY" = 0 ] && [ "$RUN_FIO_RC" = 125 ]; then
		run_fail workload_cgroup "workload could not join $CG (rc 125)"
		return 1
	fi
	[ "$RUN_FIO_RC" = 0 ] || log "run $RUN_NO: workload exited with rc=$RUN_FIO_RC"
	hook_run_finish || return 1
	hook_teardown || return 1
	return 0
}

# order.txt를 만들고(samon_benchlib.py order, 요구사항 10 기준 13) 순서대로 실행 하나씩 돌린다.
# 실행마다 hook_run_finish가 runs.csv에 한 행을 덧붙인다. 모든 실행이 끝나면 행 수를 확인하고 0을 돌려준다.
run_all() {
	local cfgs total i rep cfg rows
	CSV_ROWS=0
	cachestat_probe
	local -a order
	cfgs=$(configs_for_workload) || return 1
	python3 "$BENCHLIB" order --seed "$SEED" --reps "$REPS" --configs "${cfgs// /,}" > "$OUT/order.txt" ||
		{ log "cannot create $OUT/order.txt"; return 1; }
	mapfile -t order < "$OUT/order.txt"
	total=${#order[@]}
	[ "$total" -gt 0 ] || { log "order.txt is empty"; return 1; }
	log "order.txt: $total runs ($REPS reps x $((total / REPS)) configs: ${cfgs}), seed $SEED"
	for ((i = 0; i < total; i++)); do
		read -r rep cfg <<< "${order[$i]}"
		run_one "$((i + 1))" "$rep" "$cfg" || return 1
	done
	if [ "$CSV_ROWS" != "$total" ]; then
		log "expected $total rows in ${CSV:-$OUT/runs.csv}, recorded $CSV_ROWS"
		return 1
	fi
	rows=$(( $(wc -l < "${CSV:-$OUT/runs.csv}") - 1 ))
	[ "$rows" = "$total" ] || { log "runs.csv has $rows data rows, expected $total"; return 1; }
	log "done: $total runs, $rows rows in ${CSV:-$OUT/runs.csv}; results directory: $OUT"
	return 0
}

# ---------------------------------------------------------------------------
main() {
	ORIG_ARGS=("$@")
	START_NS=$(date +%s%N)
	parse_args "$@"
	validate_options
	preflight

	# 읽기만 한다. 실패하면 아무 값도 쓰지 않고 종료한다(R10.9)
	if [ "$DRY" = 0 ]; then
		read_saved_state || die_check "saved_state" "$SAVE_ERR"
	fi
	mkdir -p "$OUT" || die_check "outdir" "cannot create $OUT"
	write_saved_file || { log "cannot write $OUT/saved.txt"; exit 1; }
	install_traps
	write_env_file || { log "cannot write $OUT/env.txt"; exit 1; }
	prefill_workload || exit 1
	run_all
	exit $?
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
