# shellcheck shell=bash
# SAMON 워크로드 정의 (S0 수집과 S4 하네스가 함께 source한다).
#
# 같은 워크로드 모양을 S0 trace 수집(bench/samon_s0_capture.sh)과
# 측정 하네스(bench/samon_bench.sh)가 쓰도록 한 곳에 둔다(design T1, T6).
# source할 때는 함수만 정의하며 변수 설정, 파일 생성, I/O를 하지 않는다.
#
# 워크로드 두 형태:
#   R11 형태(요구사항 11): mixed reread loop seqwrite
#     fio job 생성(swl_jobfile), loop pass 실행기(swl_loop_passes),
#     prefill(swl_prefill, cgroup 밖, fsync).
#     cgroup 안에서 실행하는 것은 호출자 책임이다(swl_exec_in_cgroup 도우미 제공).
#   R9.3 형태(요구사항 9 기준 3): p1 p1rand p2 p3 p4 rand
#     Verify_Script와 같은 명령(dd bs=1M buffered, fio --bs=4k --direct=0
#     --ioengine=sync)과 read pass 직전 파일 단위 캐시 비움. cgroup 없이 실행.
#     "스캔 범위 안 랜덤" 시험은 커널 파라미터(samon_stream_idle_ms) 조작이
#     필요한 Verify_Script 전용 시험이라 여기 두지 않는다.
#
# 파라미터(환경 변수, 비어 있으면 swl_defaults가 기본값을 채움. 요구사항 11 기준 2,
# 부록 A 제안 값):
#   SWL_MEM=768M           memory.max (reread 크기 기본값 계산용)
#   SWL_HOT_SIZE=1G        mixed·seqwrite hot 파일 크기
#   SWL_HOT_ZIPF=1.2       hot zipf 지수
#   SWL_SCAN_SIZE=2G       mixed scan 파일 크기
#   SWL_REREAD_SIZE=       reread 파일 크기, 비면 ⌈SWL_MEM × 1.3⌉ MiB
#   SWL_REREAD_ZIPF=0.8    reread zipf 지수
#   SWL_LOOP_SIZE=1G       loop 파일 크기(memory.max보다 커야 함, 검사는 호출자)
#   SWL_LOOP_BS=128k       loop pass bs
#   SWL_WRITER_SIZE=2G     seqwrite writer 파일 크기
#   SWL_WRITER_BS=1M       seqwrite writer bs
#   SWL_P2_PASS_S=4        R9.3 P2 pass 길이(초, Verify_Script P2_PASS_S와 같은 값)
#   SWL_BG_RUNTIME=600     R9.3 p1rand 배경 fio의 time_based 상한(초)
#
# 공개 함수(반환 0 = 성공):
#   swl_defaults                         비어 있는 SWL_* 변수에 기본값을 채움
#   swl_validate                         크기·zipf 형식 확인(swl_defaults가 호출), 틀리면 반환 1
#   swl_describe                         적용값과 memory.max 대비 파일 크기 비율을 이름=값으로 출력
#   swl_loop_larger_than_mem             SWL_LOOP_SIZE > SWL_MEM이면 0(요구사항 11 기준 6(c))
#   swl_r11_names / swl_r93_names        워크로드 이름 목록(공백 구분) 출력
#   swl_kind NAME                        r11 | r93 출력, 모르는 이름이면 반환 1
#   swl_files NAME DIR                   워크로드가 읽거나 쓰는 파일 경로를 한 줄씩 출력
#                                        (S0 ranges.txt 생성용. p4의 pat_w256은
#                                        워크로드가 만든 뒤에야 extent가 생김)
#   swl_prefill NAME DIR                 워크로드 파일 생성(cgroup 밖, fsync).
#                                        같은 크기의 파일이 이미 있으면 건너뜀
#   swl_jobfile NAME DIR SECS RAMP       mixed·reread·seqwrite fio job 파일을 stdout으로
#   swl_loop_passes DIR SECS RAMP CSV    loop pass 반복, CSV에 idx,start_ns,end_ns,rc,io_bytes.
#                                        같은 이름 .meta 파일에 t0_ns, ramp_s, secs, file_bytes
#   swl_run_r11 NAME DIR SECS RAMP PFX   R11 워크로드 1회 실행(현재 프로세스에서).
#                                        fio json = PFX.json(job 파일 PFX.fio),
#                                        loop는 PFX.passes.csv. 반환값 = fio 종료 코드
#   swl_run_r93 NAME DIR                 R9.3 워크로드 1회 실행(캐시 비움 포함)
#   swl_exec_in_cgroup CGDIR CMD...      CGDIR/cgroup.procs에 자기 PID를 쓰고 CMD 실행
#                                        (자식 bash에서 이 파일을 다시 source함)
#   swl_drop_file_cache FILE             파일 단위 캐시 비움(sync → nocache → 필요 시
#                                        drop_caches=1). SWL_DROP_HOW에 nocache |
#                                        drop_caches | unchecked(fincore 없음) 기록.
#                                        SWL_DROP_FN에 함수 이름을 넣으면 그것으로 대체

# 이 파일의 절대 경로(swl_exec_in_cgroup가 자식 셸에서 다시 source할 때 씀)
SWL_SELF=${SWL_SELF:-$(readlink -f "${BASH_SOURCE[0]}")}

swl_log() { echo "swl: $*" >&2; }

swl_defaults() {
	: "${SWL_MEM:=768M}"
	: "${SWL_HOT_SIZE:=1G}"
	: "${SWL_HOT_ZIPF:=1.2}"
	: "${SWL_SCAN_SIZE:=2G}"
	: "${SWL_REREAD_ZIPF:=0.8}"
	: "${SWL_LOOP_SIZE:=1G}"
	: "${SWL_LOOP_BS:=128k}"
	: "${SWL_WRITER_SIZE:=2G}"
	: "${SWL_WRITER_BS:=1M}"
	: "${SWL_P2_PASS_S:=4}"
	: "${SWL_BG_RUNTIME:=600}"
	if [ -z "${SWL_REREAD_SIZE:-}" ]; then
		# ⌈memory.max × 1.3⌉ MiB (요구사항 11 기준 2)
		local b
		b=$(swl_bytes "$SWL_MEM") || return 1
		SWL_REREAD_SIZE="$(( (b * 13 + 10 * 1048576 - 1) / (10 * 1048576) ))M"
	fi
	swl_validate
}

# 크기·zipf 지수·bs 형식 확인(요구사항 11 기준 2). 형식이 틀리면 이름을 출력하고 반환 1.
swl_validate() {
	local v
	for v in SWL_MEM SWL_HOT_SIZE SWL_SCAN_SIZE SWL_REREAD_SIZE SWL_LOOP_SIZE \
		SWL_LOOP_BS SWL_WRITER_SIZE SWL_WRITER_BS; do
		swl_bytes "${!v}" >/dev/null 2>&1 || { swl_log "bad $v: ${!v}"; return 1; }
	done
	for v in SWL_HOT_ZIPF SWL_REREAD_ZIPF; do
		case "${!v}" in
		''|*[!0-9.]*|.*|*.|*.*.*) swl_log "bad $v: ${!v}"; return 1 ;;
		esac
		awk -v z="${!v}" 'BEGIN{exit !(z > 0)}' || { swl_log "bad $v: ${!v} (must be > 0)"; return 1; }
	done
	return 0
}

# 실제 적용한 값과 memory.max 대비 파일 크기 비율을 한 줄씩 출력(환경 정보용, 요구사항 11 기준 2).
# 형식: 이름=값 또는 이름_bytes=바이트, 이름_over_mem=비율(소수 셋째 자리)
swl_describe() {
	local v mem b
	swl_defaults || return 1
	mem=$(swl_bytes "$SWL_MEM") || return 1
	for v in SWL_MEM SWL_HOT_SIZE SWL_HOT_ZIPF SWL_SCAN_SIZE SWL_REREAD_SIZE \
		SWL_REREAD_ZIPF SWL_LOOP_SIZE SWL_LOOP_BS SWL_WRITER_SIZE SWL_WRITER_BS; do
		echo "$v=${!v}"
	done
	for v in SWL_HOT_SIZE SWL_SCAN_SIZE SWL_REREAD_SIZE SWL_LOOP_SIZE SWL_WRITER_SIZE; do
		b=$(swl_bytes "${!v}") || return 1
		echo "${v}_bytes=$b"
		awk -v b="$b" -v m="$mem" -v n="${v}_over_mem" 'BEGIN{printf "%s=%.3f\n", n, b / m}'
	done
}

# loop 파일이 memory.max보다 큰지(요구사항 11 기준 6(c)). 아니면 반환 1.
swl_loop_larger_than_mem() {
	local l m
	swl_defaults || return 1
	l=$(swl_bytes "$SWL_LOOP_SIZE") && m=$(swl_bytes "$SWL_MEM") || return 1
	[ "$l" -gt "$m" ]
}

# IEC 크기 문자열(1G, 768M, 128k)을 바이트로
swl_bytes() {
	numfmt --from=iec "$(echo "$1" | tr 'a-z' 'A-Z')" 2>/dev/null \
		|| { swl_log "bad size: $1"; return 1; }
}

swl_now_ns() { date +%s%N; }

swl_r11_names() { echo "mixed reread loop seqwrite"; }
swl_r93_names() { echo "p1 p1rand p2 p3 p4 rand"; }

swl_kind() {
	case "${1:-}" in
	mixed|reread|loop|seqwrite) echo r11 ;;
	p1|p1rand|p2|p3|p4|rand) echo r93 ;;
	*) return 1 ;;
	esac
}

# R9.3 시험 파일(Verify_Script T4와 같은 이름과 크기)
swl_r93_file() {	# $1 = seq256 | rand256 | 64 | w256, $2 = DIR
	echo "$2/pat_$1"
}

swl_files() {
	local n=$1 d=$2
	swl_defaults || return 1
	case "$n" in
	mixed)    echo "$d/hot.dat"; echo "$d/scan.dat" ;;
	reread)   echo "$d/reread.dat" ;;
	loop)     echo "$d/loop.dat" ;;
	seqwrite) echo "$d/hot.dat"; echo "$d/writer.dat" ;;
	p1)       swl_r93_file seq256 "$d" ;;
	p1rand)   swl_r93_file seq256 "$d"; swl_r93_file rand256 "$d" ;;
	p2|p3)    swl_r93_file 64 "$d" ;;
	p4)       swl_r93_file w256 "$d" ;;
	rand)     swl_r93_file rand256 "$d" ;;
	*) swl_log "unknown workload: $n"; return 1 ;;
	esac
}

# 파일 하나 생성: 크기가 같으면 건너뜀. 순차 buffered write 후 fsync(요구사항 11 기준 1(c))
swl_prefill_file() {	# $1 = path, $2 = size(IEC)
	local f=$1 want have
	want=$(swl_bytes "$2") || return 1
	have=$(stat -c %s "$f" 2>/dev/null || echo -1)
	if [ "$have" = "$want" ]; then
		swl_log "prefill skip $f ($2 exists)"
		return 0
	fi
	swl_log "prefill $f ($2)"
	rm -f "$f"
	fio --name=prefill --filename="$f" --size="$2" --rw=write --bs=1M \
		--direct=0 --ioengine=psync --end_fsync=1 --eta=never \
		--output=/dev/null || { swl_log "prefill failed: $f"; return 1; }
}

swl_prefill() {
	local n=$1 d=$2
	swl_defaults || return 1
	mkdir -p "$d" || return 1
	case "$n" in
	mixed)
		swl_prefill_file "$d/hot.dat" "$SWL_HOT_SIZE" &&
		swl_prefill_file "$d/scan.dat" "$SWL_SCAN_SIZE" ;;
	reread)   swl_prefill_file "$d/reread.dat" "$SWL_REREAD_SIZE" ;;
	loop)     swl_prefill_file "$d/loop.dat" "$SWL_LOOP_SIZE" ;;
	seqwrite)
		# writer.dat도 미리 만든다: 측정 중 쓰기는 기존 파일 덮어쓰기(offset 0부터 반복)
		swl_prefill_file "$d/hot.dat" "$SWL_HOT_SIZE" &&
		swl_prefill_file "$d/writer.dat" "$SWL_WRITER_SIZE" ;;
	p1)       swl_prefill_file "$(swl_r93_file seq256 "$d")" 256M ;;
	p1rand)
		swl_prefill_file "$(swl_r93_file seq256 "$d")" 256M &&
		swl_prefill_file "$(swl_r93_file rand256 "$d")" 256M ;;
	p2|p3)    swl_prefill_file "$(swl_r93_file 64 "$d")" 64M ;;
	p4)       return 0 ;;	# P4는 워크로드가 매번 새로 쓴다
	rand)     swl_prefill_file "$(swl_r93_file rand256 "$d")" 256M ;;
	*) swl_log "unknown workload: $n"; return 1 ;;
	esac
}

# fio job 파일(mixed, reread, seqwrite). design T6 워크로드 표, 기존 하네스 잡과 같은 모양
swl_jobfile() {
	local n=$1 d=$2 secs=$3 ramp=$4
	swl_defaults || return 1
	cat <<JOB
[global]
ioengine=psync
direct=0
time_based
runtime=$secs
ramp_time=$ramp
JOB
	case "$n" in
	mixed|seqwrite)
		cat <<JOB
[hot]
group_reporting
filename=$d/hot.dat
size=$SWL_HOT_SIZE
rw=randrw
rwmixread=50
bs=4k
random_distribution=zipf:$SWL_HOT_ZIPF
numjobs=2
fdatasync=32
JOB
		;;
	reread)
		cat <<JOB
[hot]
group_reporting
filename=$d/reread.dat
size=$SWL_REREAD_SIZE
rw=randread
bs=4k
random_distribution=zipf:$SWL_REREAD_ZIPF
numjobs=1
JOB
		;;
	*) swl_log "no fio job file for workload: $n"; return 1 ;;
	esac
	case "$n" in
	mixed)
		cat <<JOB
[scan]
new_group
group_reporting
filename=$d/scan.dat
size=$SWL_SCAN_SIZE
rw=read
bs=128k
numjobs=1
JOB
		;;
	seqwrite)
		cat <<JOB
[writer]
new_group
group_reporting
filename=$d/writer.dat
size=$SWL_WRITER_SIZE
rw=write
bs=$SWL_WRITER_BS
numjobs=1
JOB
		;;
	esac
}

# fio json에서 첫 잡의 read.io_bytes(실패하면 0)
swl_json_read_bytes() {
	python3 - "$1" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    print(int(json.load(open(sys.argv[1]))["jobs"][0]["read"]["io_bytes"]))
except Exception:
    print(0)
PY
}

# loop pass 실행기(요구사항 11 기준 7, design T6).
# T0 = 시작 시각, 마감 = T0 + RAMP + SECS. 남은 시간 동안 pass를 하나씩
# timeout --signal=INT로 실행하고 pass마다 CSV에 한 줄 쓴다.
# 완주 판정(start_ns ≥ T0 + RAMP, rc = 0, io_bytes = 파일 크기)은 읽는 쪽이 한다.
swl_loop_passes() {
	local d=$1 secs=$2 ramp=$3 csv=$4
	local f t0 dl now rem start end rc bytes fsize tmp i=0
	swl_defaults || return 1
	f="$d/loop.dat"
	fsize=$(stat -c %s "$f" 2>/dev/null) || { swl_log "missing $f"; return 1; }
	tmp=$(mktemp /tmp/swl_loop.XXXXXX.json) || return 1
	t0=$(swl_now_ns)
	dl=$(( t0 + (ramp + secs) * 1000000000 ))
	printf 't0_ns=%s\nramp_s=%s\nsecs=%s\nfile_bytes=%s\n' \
		"$t0" "$ramp" "$secs" "$fsize" > "${csv%.csv}.meta"
	echo "idx,start_ns,end_ns,rc,io_bytes" > "$csv"
	while :; do
		now=$(swl_now_ns)
		rem=$(( dl - now ))
		# 남은 시간이 1ms 미만이면 끝낸다(timeout 0은 "제한 없음"이라 막아야 함)
		[ "$rem" -ge 1000000 ] || break
		i=$((i + 1))
		start=$now
		rc=0
		timeout --signal=INT "$(awk -v r="$rem" 'BEGIN{printf "%.3f", r/1e9}')" \
			fio --name=loop --filename="$f" --size="$SWL_LOOP_SIZE" --rw=read \
			--bs="$SWL_LOOP_BS" --direct=0 --ioengine=psync --loops=1 \
			--eta=never --output-format=json --output="$tmp" >/dev/null 2>&1 || rc=$?
		end=$(swl_now_ns)
		bytes=$(swl_json_read_bytes "$tmp")
		echo "$i,$start,$end,$rc,$bytes" >> "$csv"
		: > "$tmp"
	done
	rm -f "$tmp"
	return 0
}

swl_run_r11() {
	local n=$1 d=$2 secs=$3 ramp=$4 pfx=$5 rc=0
	swl_defaults || return 1
	case "$n" in
	loop)
		swl_loop_passes "$d" "$secs" "$ramp" "$pfx.passes.csv" ;;
	mixed|reread|seqwrite)
		swl_jobfile "$n" "$d" "$secs" "$ramp" > "$pfx.fio" || return 1
		fio "$pfx.fio" --eta=never --output-format=json --output="$pfx.json" || rc=$?
		return "$rc" ;;
	*) swl_log "not an R11 workload: $n"; return 1 ;;
	esac
}

# 자식 bash를 cgroup에 넣고 이 파일을 source한 뒤 CMD 실행.
# 예: swl_exec_in_cgroup /sys/fs/cgroup/samon_s0 swl_run_r11 mixed /var/tmp/w 120 10 /dev/shm/x/run
swl_exec_in_cgroup() {
	local cg=$1
	shift
	SWL_SELF="$SWL_SELF" bash -c '
		echo $$ > "$1/cgroup.procs" || exit 125
		shift
		. "$SWL_SELF"
		"$@"' swl "$cg" "$@"
}

# 파일 단위 캐시 비움(요구사항 9 기준 8과 같은 방법).
# fincore가 없으면 잔존 확인 없이 nocache만 하고 SWL_DROP_HOW=unchecked.
swl_fincore_pages() { fincore -n -o PAGES "$1" 2>/dev/null | tr -dc 0-9; }
swl_drop_file_cache() {
	local f=$1
	if [ -n "${SWL_DROP_FN:-}" ]; then
		"$SWL_DROP_FN" "$f"
		return
	fi
	sync
	dd if="$f" iflag=nocache count=0 status=none || return 1
	if ! command -v fincore >/dev/null 2>&1; then
		SWL_DROP_HOW=unchecked
		return 0
	fi
	if [ "$(swl_fincore_pages "$f")" = 0 ]; then
		SWL_DROP_HOW=nocache
		return 0
	fi
	echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || { swl_log "drop_caches failed (root?)"; return 1; }
	if [ "$(swl_fincore_pages "$f")" = 0 ]; then
		SWL_DROP_HOW=drop_caches
		return 0
	fi
	swl_log "page cache of $f not empty after drop"
	return 1
}

# Verify_Script와 같은 명령(design T4 표)
swl_dd_read() { dd if="$1" of=/dev/null bs=1M status=none; }
swl_fio_randread() {	# $1 = name, $2 = file, $3 = size, 나머지 = 추가 옵션
	local name=$1 f=$2 sz=$3
	shift 3
	fio --name="$name" --filename="$f" --rw=randread --bs=4k --direct=0 \
		--ioengine=sync --size="$sz" --eta=never --output=/dev/null "$@"
}

swl_run_r93() {
	local n=$1 d=$2 seq rnd f64 fw bg rc=0
	swl_defaults || return 1
	seq=$(swl_r93_file seq256 "$d")
	rnd=$(swl_r93_file rand256 "$d")
	f64=$(swl_r93_file 64 "$d")
	fw=$(swl_r93_file w256 "$d")
	case "$n" in
	p1)	# 256MiB 순차 read 1회
		swl_drop_file_cache "$seq" || return 1
		swl_dd_read "$seq" || rc=$? ;;
	p1rand)	# 배경 randread를 띄운 채 P1과 같은 dd, dd가 끝나면 배경 종료
		swl_drop_file_cache "$rnd" || return 1
		swl_drop_file_cache "$seq" || return 1
		swl_fio_randread bg "$rnd" 256M --time_based --runtime="$SWL_BG_RUNTIME" &
		bg=$!
		swl_dd_read "$seq" || rc=$?
		kill "$bg" 2>/dev/null
		wait "$bg" 2>/dev/null ;;
	p2)	# 같은 offset 순서(randrepeat=1)의 64MiB randread 두 pass, 사이에 캐시 비움
		swl_drop_file_cache "$f64" || return 1
		swl_fio_randread p2 "$f64" 64M --randrepeat=1 --time_based \
			--runtime="$SWL_P2_PASS_S" || rc=$?
		swl_drop_file_cache "$f64" || return 1
		swl_fio_randread p2 "$f64" 64M --randrepeat=1 --time_based \
			--runtime="$SWL_P2_PASS_S" || rc=$? ;;
	p3)	# 64MiB 순차 read 두 pass, 둘 다 잔존 page 0에서 offset 0부터
		swl_drop_file_cache "$f64" || return 1
		swl_dd_read "$f64" || rc=$?
		swl_drop_file_cache "$f64" || return 1
		swl_dd_read "$f64" || rc=$? ;;
	p4)	# 지운 뒤 256MiB 새로 buffered write, sync
		rm -f "$fw"
		sync
		dd if=/dev/zero of="$fw" bs=1M count=256 status=none || rc=$?
		sync ;;
	rand)	# 256MiB 전체 randread, 각 4KB 블록 1회(randommap 기본값)
		swl_drop_file_cache "$rnd" || return 1
		swl_fio_randread rc "$rnd" 256M || rc=$? ;;
	*) swl_log "not an R9.3 workload: $n"; return 1 ;;
	esac
	return "$rc"
}
