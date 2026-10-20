#!/bin/bash
# samon_s0_capture.sh — S0 block trace 수집 (측정 도구, 구현의 기반 아님)
#
# SAMON kdamond가 정지된 상태에서 워크로드 하나를 실행하며 bench/samon_trace.bt로
# block_rq_issue / block_rq_complete를 기록한다(요구사항 5 기준 1, 3, design T1).
# 오프라인 재현은 bench/samon_replay.py가 한다. 이 스크립트는 root로 User가 실행한다.
#
# usage: sudo bash bench/samon_s0_capture.sh -w <workload> [-d DIR] [-m 768M] [-t 120] [-r 10] [-o OUT]
#   workload: mixed reread loop seqwrite (요구사항 11 형태, cgroup 안에서 ramp + 측정 시간)
#             p1 p1rand p2 p3 p4 rand    (요구사항 9 기준 3 형태, cgroup 없이 1회)
#   -d DIR  워크로드 파일 위치(기본 /var/tmp/samon_s0wl). tmpfs 금지, 대상 디스크 위
#   -m      memory.max(기본 768M, R11 형태만)
#   -t / -r 측정 시간 / ramp(초, 기본 120 / 10, R11 형태만)
#   -o OUT  최종 결과 디렉터리(기본 /var/tmp/samon_s0/<run>)
#
# 결과(OUT): trace.txt(bpftrace stdout), trace.stderr, ranges.txt, capture.txt, 워크로드 출력.
# 수집 중에는 sda에 쓰지 않도록 /dev/shm/samon_s0/<run>/에 쓰고, 끝난 뒤 OUT으로 옮긴다.
#
# 마지막 줄:
#   S0 CAPTURE OK issue=<n> complete=<n> lost=0 out=<dir>          (종료 코드 0)
#   S0 CAPTURE INVALID <사유> issue=<n> complete=<n> lost=<n> out=<dir> (종료 코드 1)
# 사전 확인 실패(root 아님, 인자 오류, LRU_SORT 켜짐 등)는 "S0 CAPTURE ERROR <사유>", 종료 코드 2.

set -u

HERE=$(dirname "$(readlink -f "$0")")
BT=$HERE/samon_trace.bt
WLSH=$HERE/samon_workloads.sh
KD=/sys/kernel/mm/damon/admin/kdamonds
LRUS=/sys/module/damon_lru_sort/parameters/enabled
CG=/sys/fs/cgroup/samon_s0
SHM_BASE=/dev/shm/samon_s0
OUT_BASE=/var/tmp/samon_s0
ATTACH_WAIT_S=30
STOP_WAIT_S=30

W=""; DIR=/var/tmp/samon_s0wl; MEM=768M; SECS=120; RAMP=10; OUT=""

die() { echo "S0 CAPTURE ERROR $*"; exit 2; }
log() { echo "s0: $*" >&2; }

while getopts "w:d:m:t:r:o:h" opt; do
	case "$opt" in
	w) W=$OPTARG ;;
	d) DIR=$OPTARG ;;
	m) MEM=$OPTARG ;;
	t) SECS=$OPTARG ;;
	r) RAMP=$OPTARG ;;
	o) OUT=$OPTARG ;;
	*) sed -n '8,14p' "$0"; exit 2 ;;
	esac
done

[ "$(id -u)" = 0 ] || die "not root (run with sudo)"
[ -r "$BT" ] || die "missing $BT"
[ -r "$WLSH" ] || die "missing $WLSH"
command -v bpftrace >/dev/null || die "bpftrace not found"
command -v filefrag >/dev/null || die "filefrag not found"
command -v fio >/dev/null || die "fio not found"
case "$SECS$RAMP" in *[!0-9]*) die "-t and -r must be integers" ;; esac

# shellcheck source=bench/samon_workloads.sh
. "$WLSH"
KIND=$(swl_kind "$W") || die "unknown workload '$W' (r11: $(swl_r11_names); r93: $(swl_r93_names))"
SWL_MEM=$MEM
swl_defaults || die "bad -m $MEM"
# swl_exec_in_cgroup의 자식 bash도 같은 값을 쓰게 한다
export SWL_MEM SWL_HOT_SIZE SWL_HOT_ZIPF SWL_SCAN_SIZE SWL_REREAD_SIZE SWL_REREAD_ZIPF \
	SWL_LOOP_SIZE SWL_LOOP_BS SWL_WRITER_SIZE SWL_WRITER_BS SWL_P2_PASS_S SWL_BG_RUNTIME

mkdir -p "$DIR" || die "cannot create $DIR"
DIR=$(readlink -f "$DIR")
[ "$(findmnt -no FSTYPE -T "$DIR" 2>/dev/null || echo x)" != tmpfs ] || die "$DIR is tmpfs"

# 대상 디스크: -d의 파일시스템 → 파티션 → 부모 디스크(기존 하네스와 같은 방법)
SRCDEV=$(findmnt -no SOURCE -T "$DIR") || die "findmnt failed for $DIR"
PART=$(basename "$(readlink -f "$SRCDEV")")
[ -e "/sys/class/block/$PART" ] || die "no /sys/class/block/$PART (source $SRCDEV)"
if [ -e "/sys/class/block/$PART/partition" ]; then
	DISK=$(basename "$(readlink -f "/sys/class/block/$PART/..")")
	PSTART=$(cat "/sys/class/block/$PART/start")
else
	DISK=$PART
	PSTART=0
fi
DMAJ=$(cut -d: -f1 "/sys/class/block/$DISK/dev")
DMIN=$(cut -d: -f2 "/sys/class/block/$DISK/dev")
FSBS=$(stat -f -c %S "$DIR") || die "stat -f failed for $DIR"
[ $((FSBS % 512)) = 0 ] || die "fs block size $FSBS not a multiple of 512"

# LRU_SORT는 꺼져 있어야 한다(확인만, 바꾸지 않음)
if [ -r "$LRUS" ]; then
	[ "$(cat "$LRUS")" = N ] || die "DAMON_LRU_SORT enabled=$(cat "$LRUS"), set it to N first"
fi

# SAMON kdamond는 정지 상태여야 한다. 켜져 있으면 끄고(최대 10초) 기록한다
wait_state() {
	local i
	for i in $(seq 1 50); do
		[ "$(cat "$KD/0/state" 2>/dev/null)" = "$1" ] && return 0
		sleep 0.2
	done
	return 1
}
KD_BEFORE=none
if [ -r "$KD/0/state" ]; then
	KD_BEFORE=$(cat "$KD/0/state")
	if [ "$KD_BEFORE" != off ]; then
		log "SAMON kdamond is $KD_BEFORE, turning it off"
		echo off > "$KD/0/state" 2>/dev/null
		wait_state off || die "kdamond did not stop within 10s"
	fi
fi

RUN=$(date +%Y%m%d-%H%M%S)-$W
TMP=$SHM_BASE/$RUN
[ -n "$OUT" ] || OUT=$OUT_BASE/$RUN
[ -e "$OUT" ] && die "$OUT already exists"
mkdir -p "$TMP" || die "cannot create $TMP"
SHM_AVAIL=$(df --output=avail -BM /dev/shm | tail -1 | tr -dc 0-9)
[ "${SHM_AVAIL:-0}" -gt 512 ] || log "warning: /dev/shm has only ${SHM_AVAIL}MiB free"

BPID=""
CG_MADE=0
cleanup() {
	if [ -n "$BPID" ] && kill -0 "$BPID" 2>/dev/null; then
		kill -INT "$BPID" 2>/dev/null
		sleep 2
		kill -TERM "$BPID" 2>/dev/null
	fi
	if [ "$CG_MADE" = 1 ] && [ -d "$CG" ]; then
		echo 1 > "$CG/cgroup.kill" 2>/dev/null
		sleep 0.5
		rmdir "$CG" 2>/dev/null
	fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CAP=$TMP/capture.txt
{
	echo "cmd=$0 $*"
	echo "run=$RUN"
	echo "workload=$W kind=$KIND"
	echo "dir=$DIR"
	echo "kernel=$(uname -r) $(uname -v)"
	echo "dev=$DMAJ:$DMIN disk=$DISK part=$PART part_start=$PSTART fs_block=$FSBS"
	echo "samon_kdamond_before=$KD_BEFORE"
	echo "lru_sort_enabled=$(cat "$LRUS" 2>/dev/null || echo NA)"
	echo "bpftrace=$(bpftrace --version 2>/dev/null | head -1)"
	echo "trace_script=$BT sha256=$(sha256sum "$BT" | cut -d' ' -f1)"
	if [ "$KIND" = r11 ]; then
		echo "memory_max=$MEM swap_max=0 secs=$SECS ramp=$RAMP"
	fi
	env | grep '^SWL_' | sort
} > "$CAP"

# ranges.txt: <file> <start_sector> <end_sector(배타적)>, filefrag -e의 물리 블록 기준
write_ranges() {	# 파일 경로를 stdin에서 한 줄씩
	local f r=$TMP/ranges.txt
	[ -e "$r" ] || printf '# part=%s part_start=%s fs_block=%s dev=%s:%s\n' \
		"$PART" "$PSTART" "$FSBS" "$DMAJ" "$DMIN" > "$r"
	while read -r f; do
		[ -e "$f" ] || { log "ranges: $f missing"; continue; }
		filefrag -e "$f" 2>/dev/null | awk -v f="$f" -v spb=$((FSBS / 512)) -v ps="$PSTART" '
			/^ *[0-9]+:/ {
				gsub(/\.\./, " "); gsub(/:/, " ")
				# $1 ext, $2..$3 logical, $4..$5 physical(포함)
				printf "%s %d %d\n", f, $4 * spb + ps, ($5 + 1) * spb + ps
				n++
			}
			END { if (!n) exit 1 }' >> "$r" || log "ranges: no extents for $f"
	done
}

# 1. 워크로드 파일 준비(cgroup 밖, fsync), 캐시 비움
log "prefill $W in $DIR"
swl_prefill "$W" "$DIR" || die "prefill failed"
sync
echo 3 > /proc/sys/vm/drop_caches || die "drop_caches failed"
# p4의 pat_w256은 워크로드가 만든 뒤 extent를 읽는다
[ "$W" = p4 ] || swl_files "$W" "$DIR" | write_ranges

# 2. R11 형태: 측정 cgroup 준비
if [ "$KIND" = r11 ]; then
	grep -qw memory /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null \
		|| die "memory controller not enabled in /sys/fs/cgroup/cgroup.subtree_control"
	if [ -d "$CG" ]; then
		echo 1 > "$CG/cgroup.kill" 2>/dev/null
		sleep 0.5
		rmdir "$CG" || die "cannot remove stale $CG"
	fi
	mkdir "$CG" || die "cannot create $CG"
	CG_MADE=1
	echo "$MEM" > "$CG/memory.max" || die "cannot set memory.max"
	echo 0 > "$CG/memory.swap.max" || die "cannot set memory.swap.max"
	[ "$(cat "$CG/memory.max")" = "$(swl_bytes "$MEM")" ] || die "memory.max readback $(cat "$CG/memory.max")"
	[ "$(cat "$CG/memory.swap.max")" = 0 ] || die "memory.swap.max readback $(cat "$CG/memory.swap.max")"
fi

# 3. bpftrace 시작, Attaching(또는 BEGIN 머리 줄) 대기
log "starting bpftrace dev=$DMAJ:$DMIN"
BPFTRACE_PERF_RB_PAGES=4096 bpftrace -o "$TMP/trace.txt" "$BT" "$DMAJ" "$DMIN" \
	2> "$TMP/trace.stderr" &
BPID=$!
ATT=0
for _ in $(seq 1 $((ATTACH_WAIT_S * 5))); do
	kill -0 "$BPID" 2>/dev/null || break
	if grep -qs 'Attaching' "$TMP/trace.stderr" "$TMP/trace.txt"; then
		ATT=1
		break
	fi
	sleep 0.2
done
if [ "$ATT" != 1 ]; then
	cat "$TMP/trace.stderr" >&2
	die "bpftrace did not attach within ${ATTACH_WAIT_S}s"
fi
sleep 1	# BEGIN 출력과 probe 활성화 여유
echo "trace_start=$(date +%s%N)" >> "$CAP"

# 4. 워크로드 실행
log "running $W"
WRC=0
if [ "$KIND" = r11 ]; then
	swl_exec_in_cgroup "$CG" swl_run_r11 "$W" "$DIR" "$SECS" "$RAMP" "$TMP/wl" || WRC=$?
else
	swl_run_r93 "$W" "$DIR" > "$TMP/wl.log" 2>&1 || WRC=$?
fi
echo "workload_end=$(date +%s%N) workload_rc=$WRC" >> "$CAP"
[ "$W" = p4 ] && swl_files "$W" "$DIR" | write_ranges

# 5. sync 완료 후 trace 종료
sync
sleep 1
kill -INT "$BPID" 2>/dev/null
for _ in $(seq 1 $((STOP_WAIT_S * 5))); do
	kill -0 "$BPID" 2>/dev/null || break
	sleep 0.2
done
if kill -0 "$BPID" 2>/dev/null; then
	log "bpftrace did not exit after SIGINT, sending SIGTERM"
	kill -TERM "$BPID" 2>/dev/null
fi
wait "$BPID" 2>/dev/null
BRC=$?
BPID=""
echo "trace_end=$(date +%s%N) bpftrace_rc=$BRC" >> "$CAP"
if [ "$CG_MADE" = 1 ]; then
	rmdir "$CG" 2>/dev/null
	CG_MADE=0
fi

# 6. 판정
ISS=$(grep -c '^I ' "$TMP/trace.txt" 2>/dev/null) || ISS=0
CMP=$(grep -c '^C ' "$TMP/trace.txt" 2>/dev/null) || CMP=0
LOST=$(grep -Eoh 'Lost [0-9]+ events' "$TMP/trace.txt" "$TMP/trace.stderr" 2>/dev/null \
	| awk '{s += $2; n++} END {print (n ? (s ? s : n) : 0)}')
echo "issue=$ISS complete=$CMP lost=$LOST" >> "$CAP"

# 7. 결과를 OUT으로 옮기고 SUDO_USER 소유로
mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"
mv "$TMP" "$OUT" || die "cannot move $TMP to $OUT"
rmdir "$SHM_BASE" 2>/dev/null
if [ -n "${SUDO_USER:-}" ]; then
	chown -R "$SUDO_USER:" "$OUT"
	[ "$(dirname "$OUT")" = "$OUT_BASE" ] && chown "$SUDO_USER:" "$OUT_BASE"
fi

WHY=""
[ "$ISS" -gt 0 ] || WHY="$WHY no_issue"
[ "$CMP" -gt 0 ] || WHY="$WHY no_complete"
[ "$LOST" = 0 ] || WHY="$WHY lost_events"
[ "$WRC" = 0 ] || WHY="$WHY workload_rc=$WRC"
if [ -n "$WHY" ]; then
	echo "S0 CAPTURE INVALID${WHY} issue=$ISS complete=$CMP lost=$LOST out=$OUT"
	exit 1
fi
echo "S0 CAPTURE OK issue=$ISS complete=$CMP lost=0 out=$OUT"
exit 0
