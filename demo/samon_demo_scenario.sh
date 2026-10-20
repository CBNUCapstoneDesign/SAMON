#!/bin/bash
# samon_demo_scenario.sh — SAMON 시연 시나리오 (root, 시연 도구이며 검증 스크립트가 아님)
#
# 다른 터미널에서 대시보드를 띄워 두고 실행한다:
#   터미널 1: sudo python3 demo/samon_dashboard.py --record /tmp/samon_demo.csv
#   터미널 2: sudo bash demo/samon_demo_scenario.sh
#   끝난 뒤:  python3 demo/samon_demo_plot.py /tmp/samon_demo.csv -o samon_demo.png
#
# 단계(기본 순서, -p로 고른다). 명령은 kernel/verify_samon.sh 패턴 시험과 같은 방식이다.
#   idle  워크로드 없음 (기준선)
#   p1    256MiB 순차 read                       -> P1
#   rand  같은 크기 파일 4KiB 랜덤 read           -> P6 (P1이 아님)
#   p2    64MiB 랜덤 read 2회, 같은 순서          -> 1회차 P6, 2회차 P2
#   p3    256MiB 순차 read 3회 (캐시 비우고 반복) -> 1회차 P1, 2·3회차 P3
#   p4    256MiB 순차 write (16MiB마다 fdatasync) -> P4
#   p5    같은 32KiB를 동기 write로 반복          -> P5
#   mix   순차 read + 다른 파일 랜덤 read 동시     -> P1과 P6가 따로 잡힘
#
# usage: sudo bash demo/samon_demo_scenario.sh [-d DIR] [-p 단계,...] [-r RATE] [-s PAUSE] [-O] [-k]
#   -d DIR    시연 파일 위치 (기본 /var/tmp/samon_demo). tmpfs 금지, 디스크 위 디렉터리
#   -p LIST   실행할 단계 (기본 idle,p1,rand,p2,p3,p4,p5,mix)
#   -r RATE   순차 read/write 속도 제한, fio --rate 형식 (기본 64m, 256MiB가 약 4초).
#             0이면 제한 없이 dd로 읽는다 (verify_samon.sh와 같음, 화면에서는 한 순간에 지나감)
#   -s SEC    단계 사이 쉬는 시간 (기본 3)
#   -O        관측만: 조작 토글(samon_act_p1..p4, samon_opt_b)을 모두 0으로 둔다 (기본은 모두 1)
#   -k        끝난 뒤 kdamond를 켠 채로 둔다 (기본: 시작 전 상태로 되돌림)
#   -c        끝난 뒤 시연 파일을 지운다
#   -A        A/B 비교: 단계마다 토글 on(cgroup samon_on)으로 한 번, 토글 off(cgroup samon_off)로
#             한 번 실행한다. 두 cgroup은 시작할 때 새로 만들고(남아 있으면 지우고 다시 만듦),
#             끝난 뒤에도 남겨 둔다. 두 실행은 서로 다른 파일(demo_*_on, demo_*_off)을 써서
#             한쪽의 캐시 비우기가 다른 쪽 cgroup의 page를 없애지 않게 한다. -O는 무시한다.
#             대시보드의 "page cache 반영" 패널이 두 cgroup의 memory.stat을 나란히 보여 준다.
#             예: sudo bash demo/samon_demo_scenario.sh -A -p p2,p1
#
# 바꾸는 값과 복원: kdamond 0(saddr로 설정), monitoring_attrs sample_us/aggr_us, samon_q_len(8192),
# samon_max_entries(262144), samon_dbg_lba(1), samon_dev_major/minor(DIR의 디스크), 토글 5개. 정상 종료, 오류,
# Ctrl-C 모두 trap에서 시작 값으로 되돌린다(-k이면 kdamond 상태만 그대로 둔다).
# 토글을 켜면 시연 파일의 page에 실제로 folio_activate/deactivate/mark_accessed가 실행된다.
#
# 시험용 환경 변수(실제 시연에서는 쓰지 않음): SD_KD SD_PARM SD_DBG SD_PHASE_DIR SD_DROP은
# 경로를 가짜 트리로 바꾸고, SD_TEST=1은 root 검사를 건너뛰며, SD_DRY=1은 fio/dd 대신 명령만 출력한다.
set -u
set -o pipefail

DIR=/var/tmp/samon_demo
PHASES="idle,p1,rand,p2,p3,p4,p5,mix"
RATE=64m
PAUSE=3
ACT=1
KEEP=0
CLEAN=0
QLEN=8192
MAXENT=262144
SAMPLE_US=5000
AGGR_US=100000

KD=${SD_KD:-/sys/kernel/mm/damon/admin/kdamonds}
PARM=${SD_PARM:-/sys/module/saddr/parameters}
DBG=${SD_DBG:-/sys/kernel/debug/samon}
PHASE_DIR=${SD_PHASE_DIR:-/run/samon_demo}
DROP=${SD_DROP:-/proc/sys/vm/drop_caches}
LRUS=/sys/module/damon_lru_sort/parameters/enabled
TEST=${SD_TEST:-0}
DRY=${SD_DRY:-0}
PHASE_FILE=$PHASE_DIR/phase
ATTRS=$KD/0/contexts/0/monitoring_attrs/intervals

CGROOT=${SD_CGROOT:-/sys/fs/cgroup}
AB=0
AB_SIDES="on off"

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }
while getopts "d:p:r:s:OkcAh" o; do
	case $o in
	d) DIR=$OPTARG ;;
	p) PHASES=$OPTARG ;;
	r) RATE=$OPTARG ;;
	s) PAUSE=$OPTARG ;;
	O) ACT=0 ;;
	A) AB=1 ;;
	k) KEEP=1 ;;
	c) CLEAN=1 ;;
	h) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'samon_demo: %s\n' "$*" >&2; exit 2; }

for p in ${PHASES//,/ }; do
	case $p in idle|p1|rand|p2|p3|p4|p5|mix) ;; *) die "unknown phase '$p' (idle p1 rand p2 p3 p4 p5 mix)" ;; esac
done
[[ $PAUSE =~ ^[0-9]+$ ]] || die "-s needs whole seconds"
[[ $RATE == 0 || $RATE =~ ^[0-9]+[kKmMgG]?$ ]] || die "-r needs a fio rate such as 64m, or 0"

if [ "$TEST" != 1 ]; then
	[ "$(id -u)" = 0 ] || die "run as root: sudo bash $0"
fi
command -v fio >/dev/null || die "fio is required"
[ -e "$KD/nr_kdamonds" ] || die "no DAMON sysfs at $KD"
[ -d "$PARM" ] && [ -e "$PARM/samon_q_len" ] || die "no saddr parameters at $PARM (SAMON kernel #11 or later?)"
[ -r "$DBG/stats" ] || die "no $DBG/stats"
if [ -r "$LRUS" ] && [ "$TEST" != 1 ]; then
	case $(cat "$LRUS") in Y|y|1) die "DAMON_LRU_SORT is enabled; turn it off so that only SAMON acts (echo N > $LRUS)" ;; esac
fi
if [ "$AB" = 1 ]; then
	grep -qw memory "$CGROOT/cgroup.subtree_control" 2>/dev/null \
		|| die "-A needs the cgroup v2 memory controller enabled in $CGROOT/cgroup.subtree_control"
	[ "$ACT" = 1 ] || say "note: -O is ignored with -A"
	ACT=1
fi
mkdir -p "$DIR" || die "cannot create $DIR"
[ "$(findmnt -no FSTYPE -T "$DIR" 2>/dev/null)" != tmpfs ] || die "$DIR is tmpfs; choose a disk-backed directory"

# 대상 디스크: DIR이 있는 파티션의 whole disk (samon_bench.sh와 같은 방식)
SRC=$(findmnt -no SOURCE -T "$DIR")
PART=$(basename "$(readlink -f "$SRC")")
DISK=$PART
[ -e "/sys/class/block/$PART/partition" ] && DISK=$(basename "$(readlink -f "/sys/class/block/$PART/..")")
[ -r "/sys/class/block/$DISK/dev" ] || die "cannot find the disk of $DIR ($SRC)"
DMAJ=$(cut -d: -f1 "/sys/class/block/$DISK/dev"); DMIN=$(cut -d: -f2 "/sys/class/block/$DISK/dev")

# ---------------------------------------------------------------------------
# sysfs 도우미
# ---------------------------------------------------------------------------
rd() { local v; v=$(cat "$1" 2>/dev/null) || return 1; printf '%s' "$v"; }
# wr PATH VALUE: 쓰고 다시 읽어 확인 (bool 파라미터는 Y/N으로 읽힘)
wr() {
	local got
	{ printf '%s\n' "$2" > "$1"; } 2>/dev/null || { say "write failed: $2 > $1"; return 1; }
	got=$(rd "$1") || got="?"
	case "$2:$got" in 1:Y|0:N|Y:Y|N:N) return 0 ;; esac
	[ "$got" = "$2" ] || { say "read back '$got' from $1, expected '$2'"; return 1; }
}
wait_state() {
	local i
	for i in $(seq 1 50); do [ "$(rd "$KD/0/state")" = "$1" ] && return 0; sleep 0.2; done
	return 1
}
kd_off() { [ "$(rd "$KD/0/state")" = off ] && return 0; printf 'off\n' > "$KD/0/state" && wait_state off; }
kd_on()  { [ "$(rd "$KD/0/state")" = on ] && return 0;  printf 'on\n'  > "$KD/0/state" && wait_state on; }
# 표(Stream_Table, Loop_History, Reread_Table)와 큐, LBA 트리를 비운다
kd_restart() { kd_off && kd_on || die "kdamond restart failed"; }
set_toggles() { # 5자리 0/1: act_p1..p4, opt_b
	local i
	for i in 1 2 3 4; do wr "$PARM/samon_act_p$i" "${1:$((i - 1)):1}" || return 1; done
	wr "$PARM/samon_opt_b" "${1:4:1}"
}

# phase NAME DESC: 대시보드가 읽는 단계 파일. A/B 실행 중이면 이름 뒤에 [on]/[off]를 붙인다
PH_TAG=""
phase() {
	local name=$1
	case $1 in pause|setup|done) ;; *) name+=$PH_TAG ;; esac
	printf '%s\t%s\t%s\n' "$name" "$2" "$(date +%s.%N)" > "$PHASE_FILE.tmp" && mv -f "$PHASE_FILE.tmp" "$PHASE_FILE"
	[ "$1" = pause ] || say "== $name: $2"
}

# cgroup 이동: 이 셸($$)을 옮기면 이후 fio/dd도 그 cgroup에서 돈다
ORIG_CG=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup 2>/dev/null)
IN_CG=""
cg_enter() {
	{ echo $$ > "$CGROOT/$1/cgroup.procs"; } 2>/dev/null || die "cannot move into cgroup $1"
	IN_CG=$1
}
cg_leave() {
	[ -n "$IN_CG" ] || return 0
	{ echo $$ > "$CGROOT${ORIG_CG}/cgroup.procs"; } 2>/dev/null \
		|| say "WARNING: could not move back to $ORIG_CG (still in $IN_CG)"
	IN_CG=""
}
# 비어 있는 cgroup을 새로 만든다 (memory.stat 누적값을 0에서 시작)
cg_fresh() {
	local d=$CGROOT/$1
	if [ -d "$d" ]; then
		[ -z "$(cat "$d/cgroup.procs" 2>/dev/null)" ] || die "cgroup $1 still has processes; stop them first"
		rmdir "$d" 2>/dev/null || die "cannot remove old cgroup $1 (rmdir $d)"
	fi
	mkdir "$d" || die "cannot create cgroup $1"
}
pause() { phase pause "다음 단계 준비"; sleep "$PAUSE"; }

# ---------------------------------------------------------------------------
# 상태 저장과 복원
# ---------------------------------------------------------------------------
SAVED_PARAMS="samon_act_p1 samon_act_p2 samon_act_p3 samon_act_p4 samon_opt_b samon_q_len samon_max_entries samon_dbg_lba samon_dev_major samon_dev_minor"
declare -A SAVED=()
ORIG_NR=$(rd "$KD/nr_kdamonds") || die "cannot read $KD/nr_kdamonds"
ORIG_STATE=off; ORIG_OPS=""; ORIG_SAMPLE=""; ORIG_AGGR=""
if [ "$ORIG_NR" -ge 1 ] 2>/dev/null; then
	ORIG_STATE=$(rd "$KD/0/state") || ORIG_STATE=off
	ORIG_OPS=$(rd "$KD/0/contexts/0/operations") || ORIG_OPS=""
	ORIG_SAMPLE=$(rd "$ATTRS/sample_us") || ORIG_SAMPLE=""
	ORIG_AGGR=$(rd "$ATTRS/aggr_us") || ORIG_AGGR=""
	if [ "$ORIG_STATE" = on ] && [ -n "$ORIG_OPS" ] && [ "$ORIG_OPS" != saddr ]; then
		die "kdamond 0 is running with operations=$ORIG_OPS; stop it first (this script only drives a saddr kdamond)"
	fi
fi
for n in $SAVED_PARAMS; do SAVED[$n]=$(rd "$PARM/$n") || die "cannot read $PARM/$n"; done

RESTORED=0
restore() {
	local rc=$? n v
	[ "$RESTORED" = 1 ] && return
	RESTORED=1
	trap - EXIT INT TERM
	[ -n "${BGPID:-}" ] && { kill "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null; }
	cg_leave
	phase done "시나리오 끝" 2>/dev/null
	if [ "$KEEP" = 1 ]; then
		say "-k: kdamond를 켠 채로 둔다 (끌 때: echo off > $KD/0/state)"
	elif [ "$ORIG_STATE" != on ]; then
		kd_off || say "WARNING: kdamond did not stop"
	fi
	for n in $SAVED_PARAMS; do
		v=${SAVED[$n]}
		case "$n:$v" in samon_opt_b:Y) v=1 ;; samon_opt_b:N) v=0 ;; esac
		wr "$PARM/$n" "$v" || say "WARNING: could not restore $n=$v"
	done
	if [ "$KEEP" != 1 ] && [ "$(rd "$KD/0/state")" = off ]; then
		if [ "$ORIG_NR" = 0 ]; then
			# 이 스크립트가 만든 kdamond는 없앤다
			{ printf '0\n' > "$KD/nr_kdamonds"; } 2>/dev/null || say "WARNING: could not set nr_kdamonds back to 0"
		else
			[ -n "$ORIG_SAMPLE" ] && wr "$ATTRS/sample_us" "$ORIG_SAMPLE"
			[ -n "$ORIG_AGGR" ] && wr "$ATTRS/aggr_us" "$ORIG_AGGR"
		fi
	fi
	[ "$CLEAN" = 1 ] && rm -f "$DIR"/demo_seq256* "$DIR"/demo_rnd256* "$DIR"/demo_64* "$DIR"/demo_w256* "$DIR"/demo_hot*
	say "restored (samon_q_len, toggles, dev filter, max_entries$([ "$KEEP" = 1 ] || echo ', kdamond state'))"
	[ "$AB" = 1 ] && say "A/B cgroups kept: $CGROOT/samon_on, $CGROOT/samon_off (remove: sudo rmdir $CGROOT/samon_on $CGROOT/samon_off)"
	exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# 워크로드 도우미
# ---------------------------------------------------------------------------
# set_files SUFFIX: 시연 파일 이름 (A/B에서는 _on, _off)
set_files() {
	F_SEQ=$DIR/demo_seq256$1; F_RND=$DIR/demo_rnd256$1; F_64=$DIR/demo_64$1
	F_W=$DIR/demo_w256$1; F_HOT=$DIR/demo_hot$1
}
set_files ""
# 선택한 단계가 쓰는 파일만 만든다 (p4는 단계 안에서 새로 씀)
make_files() {
	local p need=" "
	for p in ${PHASES//,/ }; do
		case $p in
		p1|p3) need+="seq " ;; rand) need+="rnd " ;; p2) need+="64 " ;; p5) need+="hot " ;;
		mix) need+="seq rnd " ;;
		esac
	done
	[[ $need == *" seq "* ]] && make_file "$F_SEQ" 256
	[[ $need == *" rnd "* ]] && make_file "$F_RND" 256
	[[ $need == *" 64 "* ]] && make_file "$F_64" 64
	[[ $need == *" hot "* ]] && make_file "$F_HOT" 1
	return 0
}
x() { if [ "$DRY" = 1 ]; then echo "  + $*"; else "$@"; fi; }
size_mib() { echo $(( $(stat -c %s "$1") / 1048576 )); }

# 파일 단위 캐시 비우기 (verify_samon.sh drop_file_cache와 같은 순서)
drop_file() {
	sync
	dd if="$1" iflag=nocache count=0 status=none 2>/dev/null
	local left=?
	if command -v fincore >/dev/null; then
		left=$(fincore -n -o PAGES "$1" 2>/dev/null | tr -dc 0-9)
		[ "$left" = 0 ] && return 0
	fi
	if [ "$AB" = 1 ]; then
		# 전체 drop_caches는 다른 cgroup의 page도 비워 A/B 비교를 망친다
		say "WARNING: ${left:-?} pages of $(basename "$1") still cached (A/B mode does not use global drop_caches)"
		return 0
	fi
	echo 1 > "$DROP" 2>/dev/null || true
}
seq_read() {
	if [ "$RATE" = 0 ]; then
		x dd if="$1" of=/dev/null bs=1M status=none
	else
		x fio --name=demo_seq --filename="$1" --rw=read --bs=1M --direct=0 --ioengine=psync \
			--size="$(size_mib "$1")M" --rate="$RATE" --eta=never --output=/dev/null
	fi
}
rand_read() { # FILE SECS [fio args]
	local f=$1 secs=$2; shift 2
	x fio --name=demo_rand --filename="$f" --rw=randread --bs=4k --direct=0 --ioengine=psync \
		--size="$(size_mib "$f")M" --time_based --runtime="$secs" --eta=never --output=/dev/null "$@"
}
make_file() { # FILE MiB
	[ -f "$1" ] && [ "$(stat -c %s "$1")" = $(($2 * 1048576)) ] && return 0
	say "creating $(basename "$1") (${2} MiB)"
	rm -f "$1"
	x dd if=/dev/zero of="$1" bs=1M count="$2" conv=fsync status=none || die "cannot create $1"
	[ "$DRY" = 1 ] && truncate -s "$(($2 * 1048576))" "$1"
	return 0
}

# ---------------------------------------------------------------------------
# 단계
# ---------------------------------------------------------------------------
ph_idle() { phase idle "기준선: 시연 워크로드 없음 (백그라운드 I/O만)"; sleep 5; }

ph_p1() {
	kd_restart; drop_file "$F_SEQ"
	phase p1 "256MiB 순차 read → P1 (Stream_Table 칸 count ≥ samon_seq_min)"
	seq_read "$F_SEQ"; sleep 1
}
ph_rand() {
	drop_file "$F_RND"
	phase rand "256MiB 파일 4KiB 랜덤 read → P6, P1로 잡히지 않음"
	rand_read "$F_RND" 10
}
ph_p2() {
	drop_file "$F_64"
	phase p2-1 "64MiB 랜덤 read 1회차 (처음 읽는 LBA → 대부분 P6)"
	rand_read "$F_64" 4 --randrepeat=1
	drop_file "$F_64"
	phase p2-2 "같은 순서 2회차, samon_reread_ms(10s) 안의 재읽기 → P2"
	rand_read "$F_64" 4 --randrepeat=1
}
ph_p3() {
	local i
	kd_restart
	for i in 1 2 3; do
		drop_file "$F_SEQ"
		if [ "$i" = 1 ]; then phase p3-1 "loop 1회차: 처음 지나가는 순차 read (P1)"
		else phase "p3-$i" "loop ${i}회차: 같은 시작 sector에서 다시 읽음 → P3 (앞 50% promote, 뒤 demote)"; fi
		seq_read "$F_SEQ"
		sleep 1
	done
}
ph_p4() {
	rm -f "$F_W"; sync
	phase p4 "256MiB 순차 write, 16MiB마다 fdatasync → writeback 완료가 P4"
	if [ "$RATE" = 0 ]; then
		x dd if=/dev/zero of="$F_W" bs=1M count=256 status=none
		x sync
	else
		x fio --name=demo_w --filename="$F_W" --rw=write --bs=1M --size=256M --direct=0 --ioengine=psync \
			--fallocate=none --fdatasync=16 --rate="$RATE" --end_fsync=1 --eta=never --output=/dev/null
	fi
	sleep 1
}
ph_p5() {
	local end
	phase p5 "같은 32KiB를 동기 write로 반복 → 1초에 samon_hot_threshold(10)회 이상이면 P5"
	end=$(( $(date +%s) + 5 ))
	while [ "$(date +%s)" -lt "$end" ]; do
		x dd if=/dev/zero of="$F_HOT" bs=4k count=8 conv=notrunc oflag=sync status=none || break
		[ "$DRY" = 1 ] && break
	done
	sleep 1
}
ph_mix() {
	kd_restart; drop_file "$F_SEQ"; drop_file "$F_RND"
	phase mix "순차 read와 다른 파일 4KiB 랜덤 read 동시 → P1과 P6가 따로 잡힘"
	if [ "$DRY" = 1 ]; then
		rand_read "$F_RND" 600
	else
		fio --name=demo_bg --filename="$F_RND" --rw=randread --bs=4k --direct=0 --ioengine=psync \
			--size=256M --time_based --runtime=600 --eta=never --output=/dev/null >/dev/null 2>&1 &
		BGPID=$!
	fi
	seq_read "$F_SEQ"
	[ -n "${BGPID:-}" ] && { kill "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null; BGPID=""; }
	sleep 1
}

# ---------------------------------------------------------------------------
# 준비
# ---------------------------------------------------------------------------
mkdir -p "$PHASE_DIR" && chmod 755 "$PHASE_DIR" || die "cannot create $PHASE_DIR"
TOG=11111; [ "$ACT" = 1 ] || TOG=00000
say "disk $DISK ($DMAJ:$DMIN), dir $DIR, phases $PHASES, rate $RATE, toggles $TOG (p1 p2 p3 p4 opt_b)"
say "dashboard: sudo python3 $(dirname "$0")/samon_dashboard.py --record /tmp/samon_demo.csv"
[ "$(rd /sys/kernel/mm/lru_gen/enabled 2>/dev/null)" = 0x0000 ] \
	|| say "note: MGLRU (lru_gen) is on; promote/demote act on MGLRU generations"

phase setup "kdamond 설정과 시연 파일 준비"
if [ "$ORIG_NR" = 0 ]; then
	printf '1\n' > "$KD/nr_kdamonds" || die "cannot create kdamond"
fi
kd_off || die "kdamond did not stop"
[ "$(rd "$KD/0/contexts/nr_contexts")" -ge 1 ] 2>/dev/null || printf '1\n' > "$KD/0/contexts/nr_contexts"
wr "$KD/0/contexts/0/operations" saddr || die "cannot set operations=saddr"
[ "$(rd "$KD/0/contexts/0/targets/nr_targets")" -ge 1 ] 2>/dev/null || printf '1\n' > "$KD/0/contexts/0/targets/nr_targets"
# 큐는 sample 주기마다 비워진다. 길면 큐가 가득 차 유실(drop_queue)이 생긴다
wr "$ATTRS/sample_us" "$SAMPLE_US" || die "cannot set sample_us"
wr "$ATTRS/aggr_us" "$AGGR_US" || die "cannot set aggr_us"
wr "$PARM/samon_q_len" "$QLEN" || die "cannot set samon_q_len"           # kdamond 시작 때 적용
wr "$PARM/samon_max_entries" "$MAXENT" || die "cannot set samon_max_entries"
wr "$PARM/samon_dbg_lba" 1 || die "cannot set samon_dbg_lba"   # 0이면 LBA 트리가 안 자라 P5가 감지되지 않는다
wr "$PARM/samon_dev_major" "$DMAJ" && wr "$PARM/samon_dev_minor" "$DMIN" || die "cannot set the disk filter"
set_toggles 00000 || die "cannot set toggles"

if [ "$AB" = 1 ]; then
	for side in $AB_SIDES; do set_files "_$side"; make_files; done
	set_files ""
	for side in $AB_SIDES; do cg_fresh "samon_$side"; done
	say "A/B: fresh cgroups $CGROOT/samon_on, $CGROOT/samon_off"
else
	make_files
fi
sync
kd_on || die "kdamond did not start"
q_cap=$(awk -F= '$1=="q_cap"{print $2+0}' "$DBG/stats")
say "kdamond on (saddr), q_cap=${q_cap:-?}"
set_toggles "$TOG" || die "cannot set toggles $TOG"

# run_phase P: 일반 모드는 한 번, A/B 모드는 on/off cgroup에서 한 번씩 (idle은 한 번만)
run_phase() {
	local side
	if [ "$AB" != 1 ] || [ "$1" = idle ]; then
		"ph_$1"; return
	fi
	for side in $AB_SIDES; do
		if [ "$side" = on ]; then set_toggles 11111; else set_toggles 00000; fi || die "cannot set toggles for [$side]"
		set_files "_$side"; PH_TAG=" [$side]"
		cg_enter "samon_$side"
		"ph_$1"
		cg_leave
		PH_TAG=""; set_files ""
		[ "$side" = on ] && pause
	done
}

# ---------------------------------------------------------------------------
first=1
for p in ${PHASES//,/ }; do
	[ "$first" = 1 ] || pause
	first=0
	run_phase "$p"
done
set_toggles "$TOG" 2>/dev/null
say "done. 기록이 있으면: python3 $(dirname "$0")/samon_demo_plot.py /tmp/samon_demo.csv -o samon_demo.png"
