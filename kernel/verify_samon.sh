#!/bin/bash
# SAMON saddr verification script.
# Usage: sudo bash verify_samon.sh [-d dir-on-disk | dir-on-disk]
# The directory must live on a real block-device filesystem (not tmpfs).
set -u

# ---- judgment thresholds and test settings (R9.6, appendix A) -------------
P1_MIN_PCT=50          # P1: det_p1 >= (file pages) * P1_MIN_PCT / 100
RAND_MAX_PCT=5         # random read: det_p1 < det_p6 * RAND_MAX_PCT / 100
P2_PASS_S=4            # P2: runtime of one fio pass, seconds
Q_WAIT_S=5             # max wait for q_cur == 0, seconds
IDLE_HOLD_MS=600000    # samon_stream_idle_ms during the in-range random test;
                       # must exceed the whole duration of that test

# ---- module parameter defaults (R9.1; = the SAMON_DEF_* constants of
# kernel/saddr.c, appendix A confirmed values).  Written at start-up, in this
# order, before the first kdamond off->on.
# Exception: samon_q_len=8192 (User decision 2026-10-18, kernel/samon_qlen_sweep.sh
# on #12) while SAMON_DEF_Q_LEN in saddr.c stays 1024; this script writes it.
DEFAULTS="samon_act_p1=0 samon_act_p2=0 samon_act_p3=0 samon_act_p4=0 samon_opt_b=1
samon_dev_major=0 samon_dev_minor=0 samon_dbg_lba=1
samon_q_len=8192 samon_q_max_ms=100 samon_stream_slots=16 samon_loop_slots=16
samon_reread_slots=65536 samon_seq_min=4 samon_stream_new_kb=64 samon_stream_gap_req=2
samon_stream_idle_ms=1000 samon_loop_min_kb=8192 samon_loop_protect_pct=50
samon_reread_ms=10000"

# kernel messages that count as a warning (R13.5)
WARN_RE='BUG:|WARNING:|Oops|KASAN|lockdep|RCU stall|soft lockup'

DIR=/var/tmp/samon_verify
while [ $# -gt 0 ]; do
  case "$1" in
    -d) [ -n "${2:-}" ] || { echo "usage: $0 [-d dir-on-disk | dir-on-disk]"; exit 2; }
        DIR=$2; shift 2 ;;
    -h|--help) echo "usage: $0 [-d dir-on-disk | dir-on-disk]"; exit 0 ;;
    -*) echo "usage: $0 [-d dir-on-disk | dir-on-disk]"; exit 2 ;;
    *)  DIR=$1; shift ;;
  esac
done
DBG=/sys/kernel/debug/samon
KD=/sys/kernel/mm/damon/admin/kdamonds
PARM=/sys/module/saddr/parameters
PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
info() { echo "info: $*"; }
st_get() { awk -F= -v k="$1" '$1==k{print $2+0}' $DBG/stats; }

# ---- helpers for the pattern tests (design T4) ----------------------------
# Number of page-cache pages of a file; empty/non-numeric output is returned
# as "?" so that callers treat it as "not zero".
fincore_pages() {
  local n
  n=$(fincore -n -o PAGES "$1" 2>/dev/null | tr -dc 0-9)
  echo "${n:-?}"
}
# Per-file cache drop (R9.8).  Sets DROP_HOW (nocache | drop_caches | failed)
# and DROP_RESID (pages left after the last attempt); callers print DROP_HOW in
# their item output.  Returns 1 when pages remain after drop_caches too.
DROP_HOW=; DROP_RESID=
drop_file_cache() {
  sync; dd if="$1" iflag=nocache count=0 status=none 2>/dev/null
  DROP_RESID=$(fincore_pages "$1")
  [ "$DROP_RESID" = 0 ] && { DROP_HOW=nocache; return 0; }
  echo 1 > /proc/sys/vm/drop_caches
  DROP_RESID=$(fincore_pages "$1")
  [ "$DROP_RESID" = 0 ] && { DROP_HOW=drop_caches; return 0; }
  DROP_HOW=failed
  return 1
}
# Wait until the deferred queue is empty (R9.9): 0.2 s steps, at most Q_WAIT_S s.
wait_q0() {
  local i
  for i in $(seq 1 $((Q_WAIT_S*5))); do
    [ "$(st_get q_cur)" = 0 ] && return 0
    sleep 0.2
  done
  return 1
}
# snap NAME: read $DBG/stats into the global associative array NAME
# (lines "key=value ..."; only the first value of a line is kept, so
# "entries=N max_entries=M" gives entries=N).
snap() {
  declare -gA "$1"
  local -n __snap_ref=$1
  local k v
  __snap_ref=()
  while IFS='=' read -r k v; do
    [ -n "$v" ] && __snap_ref[$k]=${v%% *}
  done < $DBG/stats
}
# d A B KEY: value of KEY in snapshot B minus snapshot A (A/B are array names).
# A key missing from either snapshot is reported on stderr and counted as 0.
d() {
  local -n __d_a=$1 __d_b=$2
  if [ -z "${__d_a[$3]+x}" ] || [ -z "${__d_b[$3]+x}" ]; then
    echo "d: stat '$3' missing in snapshot" >&2
    echo 0; return
  fi
  echo $(( ${__d_b[$3]} - ${__d_a[$3]} ))
}
# set_toggles pppp b : five 0/1 digits for samon_act_p1..p4 and samon_opt_b
# (opt_b is a bool parameter: it reads back as Y/N but accepts 1/0).
set_toggles() {
  local t=$1 i
  [[ $t =~ ^[01]{5}$ ]] || { echo "set_toggles: bad pattern '$t'" >&2; return 1; }
  for i in 1 2 3 4; do echo "${t:$((i-1)):1}" > $PARM/samon_act_p$i; done
  echo "${t:4:1}" > $PARM/samon_opt_b
}
# get_toggles: current toggles as the same five digits (opt_b Y/N -> 1/0).
get_toggles() {
  local i s= b
  for i in 1 2 3 4; do s+=$(cat $PARM/samon_act_p$i); done
  b=$(cat $PARM/samon_opt_b)
  case "$b" in Y|y|1) s+=1 ;; *) s+=0 ;; esac
  echo "$s"
}
# Write every DEFAULTS entry and read it back; names that failed to write or
# read back differently are collected in WD_FAIL.  opt_b reads back as Y/N.
WD_FAIL=
write_defaults() {
  local kv name val got
  WD_FAIL=
  for kv in $DEFAULTS; do
    name=${kv%%=*}; val=${kv#*=}
    { echo "$val" > $PARM/$name; } 2>/dev/null || { WD_FAIL+=" $name"; continue; }
    got=$(cat $PARM/$name 2>/dev/null)
    if [ "$name" = samon_opt_b ]; then
      case "$got" in Y|y) got=1 ;; N|n) got=0 ;; esac
    fi
    [ "$got" = "$val" ] || WD_FAIL+=" $name"
  done
}
# kdamond state helpers: each transition waits at most 10 s (50 x 0.2 s).
wait_state() { for _ in $(seq 1 50); do [ "$(cat $KD/0/state)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
# kd_restart: off -> on.  On failure KD_ERR names the step and 1 is returned.
# It empties Stream_Table, Loop_History, Reread_Table, Deferred_Queue and
# SAMON_Map.  NOTE: the pattern tests (20.3/20.4) also call this outside the
# measurement window before every test that reads pat_seq256 from offset 0
# (P1, in-range random, P1 + random interference, P3 and the toggle-0 re-runs
# of P1 and P3), so that an earlier read of the same start sector cannot turn
# the next read into P3.  This goes beyond R9 criterion 1 ("once at start");
# the User approved it (2026-10-18).  Items still queued are counted as
# drop_shutdown, so the accounting equality is unaffected.
KD_ERR=
kd_restart() {
  KD_ERR=
  echo off > $KD/0/state; wait_state off || { KD_ERR="kdamond did not stop for reset"; return 1; }
  echo on > $KD/0/state;  wait_state on  || { KD_ERR="kdamond did not restart after reset"; return 1; }
  return 0
}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
mkdir -p "$DIR"
DEV=$(findmnt -no SOURCE -T "$DIR"); FST=$(findmnt -no FSTYPE -T "$DIR")
[ "$FST" = tmpfs ] && { echo "$DIR is tmpfs; choose a disk-backed dir"; exit 2; }
PART=$(basename "$(readlink -f "$DEV")")
START=$(cat /sys/class/block/$PART/start 2>/dev/null || echo 0)
BS=$(stat -f -c %S "$DIR")
echo "dev=$DEV fs=$FST partition_start=$START fs_block=$BS"

# The pattern tests need fincore (util-linux-extra on Ubuntu 24.04).  Without
# it every pattern test is a [FAIL] (R9.8, R9.10); the 19 existing items still run.
if command -v fincore >/dev/null 2>&1; then FINCORE_OK=1; else
  FINCORE_OK=0; bad "fincore missing (install util-linux-extra); pattern tests cannot run"
fi

# kdamond on (tracepoint is registered when kdamond starts)
if [ "$(cat $KD/0/state 2>/dev/null)" != on ]; then
  echo 1 > $KD/nr_kdamonds; echo 1 > $KD/0/contexts/nr_contexts
  echo saddr > $KD/0/contexts/0/operations
  echo 1 > $KD/0/contexts/0/targets/nr_targets
  echo on > $KD/0/state; sleep 1
fi
[ "$(cat $KD/0/state)" = on ] && ok "kdamond on" || { bad "kdamond not on"; exit 1; }
[ -r $DBG/stats ] && ok "stats file present" || { bad "no stats file (old kernel?)"; exit 1; }

# Start from an empty tree and default parameters.  Leftover entries (e.g. from a
# benchmark run) can fill the tree up to samon_max_entries; new LBAs are then
# silently dropped (drop_full) and the checks below fail for that reason alone.
# R9.1: write all DEFAULTS (parameters read at kdamond start, such as the table
# sizes and samon_q_len, take effect with the restart that follows), then
# kdamond off->on (each transition waits at most 10 s).
write_defaults
kd_restart || { bad "$KD_ERR"; exit 1; }
DF0=$(awk -F= '$1=="drop_full"{print $2+0}' $DBG/stats)
if [ -z "$WD_FAIL" ]; then
  ok "restarted kdamond: empty tree, default parameters"
else
  bad "restarted kdamond, but default parameters could not be set:$WD_FAIL"
fi

# file sector set from filefrag (fs block -> 512B sector, + partition offset)
file_sectors() {
  filefrag -e "$1" | awk -v bs="$BS" -v st="$START" '
    /^ *[0-9]+:/ { gsub(/\.\./," "); gsub(/:/," ");
      n=split($0,a," "); phys=a[4]; len=a[6];
      for (b=0;b<len;b++) for (s=0;s<bs/512;s++) print (phys+b)*(bs/512)+s+st }'
}
dump_lbas() { grep -o 'lba=[0-9]*' $DBG/lba_page_map | cut -d= -f2 | sort -u; }

# 1. buffered write is observed, LBA matches filefrag
rm -f $DIR/buf $DIR/dio; sync
fio --name=b --rw=write --bs=4k --size=4M --filename=$DIR/buf --direct=0 --ioengine=sync --output=/dev/null
sync; sleep 1
file_sectors $DIR/buf | sort -u > /tmp/samon_buf.sec
dump_lbas > /tmp/samon_all.lba
# bio start sectors are 4K aligned; compare at 4K granularity (every 8th sector)
BUFSTART=$(awk -v s=$((BS/512)) -v st=$START '(($1-st)%s)==0' /tmp/samon_buf.sec | wc -l)
BUFHIT=$(awk -v s=$((BS/512)) -v st=$START '(($1-st)%s)==0' /tmp/samon_buf.sec | sort -u | comm -12 - /tmp/samon_all.lba | wc -l)
echo "buffered file: $BUFHIT / $BUFSTART block start sectors present in lba_page_map"
[ "$BUFHIT" -eq "$BUFSTART" ] && [ "$BUFSTART" -gt 0 ] \
  && ok "filefrag LBA == recorded LBA (all blocks)" || bad "filefrag LBA mismatch"

# 2. direct write must not appear
SKIP0=$(st_get skip_pinned); ANON0=$(st_get skip_anon); SEG0=$(st_get seg_buffered)
fio --name=d --rw=write --bs=4k --size=4M --filename=$DIR/dio --direct=1 --ioengine=sync --output=/dev/null
sync; sleep 1
file_sectors $DIR/dio | sort -u > /tmp/samon_dio.sec
dump_lbas > /tmp/samon_all2.lba
DHIT=$(comm -12 /tmp/samon_dio.sec /tmp/samon_all2.lba | wc -l)
SKIPPED=$(( $(st_get skip_anon) - ANON0 + $(st_get skip_pinned) - SKIP0 ))
echo "direct file: $DHIT sectors in map, skip counters +$SKIPPED, buffered segs +$(( $(st_get seg_buffered) - SEG0 ))"
[ "$DHIT" -eq 0 ] && ok "direct I/O sectors absent from lba_page_map" || bad "direct I/O leaked into map ($DHIT)"
[ "$SKIPPED" -gt 0 ] && ok "direct I/O segments counted as skipped" || bad "no skip counter increase for direct I/O"

# 3. hot detection and window
THR=$(cat /sys/module/saddr/parameters/samon_hot_threshold 2>/dev/null || echo 10)
for i in $(seq 1 $((THR+5))); do
  dd if=/dev/zero of=$DIR/hot bs=4k count=1 conv=notrunc oflag=sync status=none
done
sync; sleep 0.2
HOT=$(grep -c 'hot_w=1' $DBG/lba_page_map)
[ "$HOT" -gt 0 ] && ok "hot_w=1 reached after >=$THR writes ($HOT entries)" || bad "no hot_w entry"
sleep 2   # window (default 1000 ms) expires
dd if=/dev/zero of=$DIR/hot bs=4k count=1 conv=notrunc oflag=sync status=none; sync; sleep 0.2
HSEC=$(file_sectors $DIR/hot | head -1)
W=$(grep "lba=$HSEC " $DBG/lba_page_map | grep -o 'writes=[0-9]*' | cut -d= -f2)
echo "after window expiry writes=$W for lba=$HSEC"
[ -n "$W" ] && [ "$W" -lt "$THR" ] && ok "window reset clears counter" || bad "window reset not observed"


BASEDIR=$(dirname "$(readlink -f "$0")")
hot_loop() { for i in $(seq 1 $((THR+5))); do dd if=/dev/zero of="$1" bs=4k count=1 conv=notrunc oflag=sync status=none; done; sync; sleep 0.3; }

# 4. DMA-pinned path: O_DIRECT write whose source is a file-backed mmap page
if command -v gcc >/dev/null; then
  gcc -O2 -o $DIR/test_pinned "$BASEDIR/test_pinned.c" 2>/dev/null
  P0=$(st_get skip_pinned)
  $DIR/test_pinned $DIR/pin_src $DIR/pin_dst $((1<<20)); sync; sleep 1
  PD=$(( $(st_get skip_pinned) - P0 ))
  file_sectors $DIR/pin_dst | sort -u > /tmp/samon_pin.sec
  dump_lbas > /tmp/samon_all3.lba
  PHIT=$(comm -12 /tmp/samon_pin.sec /tmp/samon_all3.lba | wc -l)
  echo "pinned test: skip_pinned +$PD (1MiB = 256 pages), dst sectors in map: $PHIT"
  [ "$PD" -ge 230 ] && ok "skip_pinned path exercised (mmap-backed O_DIRECT)" || bad "skip_pinned did not increase ($PD)"
  [ "$PHIT" -eq 0 ] && ok "pinned direct-write destination not recorded" || bad "pinned dst leaked ($PHIT)"
else
  echo "[SKIP] gcc not found: skip_pinned test"
fi

# 5. Option B toggle
echo 0 > $PARM/samon_opt_b
M0=$(st_get mark_accessed); hot_loop $DIR/hot_off
MOFF=$(( $(st_get mark_accessed) - M0 ))
echo 1 > $PARM/samon_opt_b
M0=$(st_get mark_accessed); hot_loop $DIR/hot_on
MON=$(( $(st_get mark_accessed) - M0 ))
echo "opt_b off: mark_accessed +$MOFF, on: +$MON"
[ "$MOFF" -eq 0 ] && ok "samon_opt_b=0 suppresses folio_mark_accessed" || bad "mark_accessed called with opt_b=0 ($MOFF)"
[ "$MON" -gt 0 ] && ok "samon_opt_b=1 calls folio_mark_accessed on hot writes" || bad "no mark_accessed with opt_b=1"

# 6. target disk filter
DISK=$(basename "$(readlink -f /sys/class/block/$PART/..)")
DMAJ=$(cut -d: -f1 /sys/class/block/$DISK/dev); DMIN=$(cut -d: -f2 /sys/class/block/$DISK/dev)
echo $DMAJ > $PARM/samon_dev_major; echo $((DMIN+16)) > $PARM/samon_dev_minor   # a disk that is not ours
R0=$(st_get rq_seen); S0=$(st_get skip_dev)
dd if=/dev/zero of=$DIR/filt1 bs=4k count=256 status=none; sync; sleep 0.5
RD=$(( $(st_get rq_seen) - R0 )); SD=$(( $(st_get skip_dev) - S0 ))
echo "filter=other disk: rq_seen +$RD, skip_dev +$SD"
[ "$RD" -eq 0 ] && [ "$SD" -gt 0 ] && ok "device filter excludes non-target disk" || bad "filter (other disk) rq=$RD skip=$SD"
echo $DMIN > $PARM/samon_dev_minor
R0=$(st_get rq_seen)
dd if=/dev/zero of=$DIR/filt2 bs=4k count=256 status=none; sync; sleep 0.5
RD=$(( $(st_get rq_seen) - R0 ))
[ "$RD" -gt 0 ] && ok "device filter passes target disk ($DISK $DMAJ:$DMIN)" || bad "filter (target disk) saw nothing"
echo 0 > $PARM/samon_dev_major; echo 0 > $PARM/samon_dev_minor

# 7. kdamond off/on cycling: tree freed, probe not duplicated, no kernel warnings
# Duplicate-probe check: a block written once must show writes=1 in the map.
# (A second registered probe would count the same completion twice -> writes=2.)
DM0=$(dmesg | wc -l); LEAK=0; MAXW=0; NOHIT=0
for c in $(seq 1 10); do
  echo off > $KD/0/state; wait_state off || { bad "kdamond did not stop (cycle $c)"; break; }
  E=$(awk -F'[= ]' '/^entries=/{print $2}' $DBG/stats)
  [ "$E" -eq 0 ] || { LEAK=1; echo "cycle $c: entries=$E after off"; }
  echo on > $KD/0/state; wait_state on || { bad "kdamond did not restart (cycle $c)"; break; }
  rm -f $DIR/cyc; sync
  dd if=/dev/zero of=$DIR/cyc bs=4k count=1024 conv=fsync status=none; sync; sleep 0.5
  file_sectors $DIR/cyc | sort -u > /tmp/samon_cyc.sec
  W=$(awk 'NR==FNR{s[$1]=1;next} /^lba=/{split($1,a,"=");if(a[2] in s){for(i=1;i<=NF;i++)if($i~/^writes=/){split($i,b,"=");if(b[2]>m)m=b[2];n++}}} END{print m+0, n+0}' /tmp/samon_cyc.sec $DBG/lba_page_map)
  CW=${W% *}; CN=${W#* }
  [ "$CW" -gt "$MAXW" ] && MAXW=$CW
  [ "$CN" -gt 0 ] || NOHIT=1
done
echo "cycle test: max writes per file LBA over 10 off/on cycles = $MAXW"
[ "$LEAK" -eq 0 ] && ok "rbtree emptied on every kdamond stop" || bad "entries left after stop"
[ "$NOHIT" -eq 0 ] && [ "$MAXW" -eq 1 ] && ok "each block counted once after repeated restarts (probe not duplicated)" || bad "writes per block = $MAXW (hit-missing=$NOHIT)"
NEWWARN=$(dmesg | tail -n +$((DM0+1)) | grep -ciE "$WARN_RE")
[ "$NEWWARN" -eq 0 ] && ok "no kernel warnings during tests" || bad "kernel warnings in dmesg ($NEWWARN)"

# 8. skip_nomap breakdown.  The four classes must add up to skip_nomap
#    (counter consistency).  What the segments actually are is reported, not
#    asserted: the "journal I/O" hypothesis was tested and rejected (fsync
#    workload produced no nomap_meta / nomap_write growth).
NM_SUM() { echo $(( $(st_get nomap_slab) + $(st_get nomap_flagged) + $(st_get nomap_meta) + $(st_get nomap_other) )); }
[ "$(NM_SUM)" -eq "$(st_get skip_nomap)" ] && ok "nomap classes sum to skip_nomap ($(st_get skip_nomap))" || bad "nomap classes ($(NM_SUM)) != skip_nomap ($(st_get skip_nomap))"
NM0=$(st_get nomap_meta); NO0=$(st_get nomap_other); NW0=$(st_get nomap_write); SB0=$(st_get seg_buffered)
for i in $(seq 1 50); do dd if=/dev/zero of=$DIR/fs$i bs=4k count=1 conv=fsync status=none; done; sync; sleep 0.5
echo "info: fsync x50 -> seg_buffered +$(( $(st_get seg_buffered) - SB0 )) (journal/data writes seen as buffered), nomap_meta +$(( $(st_get nomap_meta) - NM0 )), nomap_other +$(( $(st_get nomap_other) - NO0 )), nomap_write +$(( $(st_get nomap_write) - NW0 ))"
echo "info: nomap breakdown: slab=$(st_get nomap_slab) flagged=$(st_get nomap_flagged) meta=$(st_get nomap_meta) other=$(st_get nomap_other) write=$(st_get nomap_write) (of $(st_get skip_nomap))"

DFD=$(( $(st_get drop_full) - DF0 ))
[ "$DFD" -eq 0 ] && ok "tree never saturated during the run (drop_full +0)" || bad "tree saturated: drop_full +$DFD, earlier results may be invalid"

# ===== end of the 19 existing items (judgments unchanged) ===================
# Items below are added by S3 (R9).  Order: S1 items, pattern tests, toggle-0
# re-runs, final accounting.  All of them run with samon_dbg_lba=1 and the
# DEFAULTS parameters except for the toggles each test sets itself.

# --- INSERT 20.2: S1 items -------------------------------------------------
# (a) ctx_hardirq + ctx_softirq + ctx_task == rq_seen (up to 3 re-reads)
# (b) skip_passthru grows during 10 s without I/O if /sys/class/block/sr* exists, else [SKIP]
S1_IDLE_S=10           # (b): seconds without I/O (R9.2)
S1_RETRIES=3           # (a): re-reads after the first read (R9.2)

# (a) R9.2(a): after sync + 1 s, read the stats once; if the three ctx counters
# do not add up to rq_seen, re-read up to S1_RETRIES more times at 1 s
# intervals.  PASS if any read matches.
s1_ctx_sum_check() {
  local try=0 h s t rq sum=0 last_h= last_s= last_t= last_rq= last_sum=
  sync; sleep 1
  while :; do
    snap S1_CTX
    h=${S1_CTX[ctx_hardirq]:-}; s=${S1_CTX[ctx_softirq]:-}
    t=${S1_CTX[ctx_task]:-};    rq=${S1_CTX[rq_seen]:-}
    if ! [[ $h =~ ^[0-9]+$ && $s =~ ^[0-9]+$ && $t =~ ^[0-9]+$ && $rq =~ ^[0-9]+$ ]]; then
      bad "ctx counters missing in stats (ctx_hardirq='$h' ctx_softirq='$s' ctx_task='$t' rq_seen='$rq'); S1 kernel not loaded?"
      return
    fi
    sum=$((h+s+t))
    last_h=$h; last_s=$s; last_t=$t; last_rq=$rq; last_sum=$sum
    if [ "$sum" -eq "$rq" ]; then
      ok "ctx_hardirq+ctx_softirq+ctx_task == rq_seen (measured sum=$sum [hardirq=$h softirq=$s task=$t], reference rq_seen=$rq, read $((try+1)) of $((S1_RETRIES+1)))"
      return
    fi
    [ "$try" -ge "$S1_RETRIES" ] && break
    try=$((try+1)); sleep 1
  done
  bad "ctx sum != rq_seen after $((S1_RETRIES+1)) reads (measured sum=$last_sum [hardirq=$last_h softirq=$last_s task=$last_t], reference rq_seen=$last_rq)"
}
s1_ctx_sum_check

# (b) R9.2(b): optical drives (sr*) poll with passthrough requests by
# themselves, so skip_passthru must grow while this script issues no I/O.
# Without any sr* device the item is [SKIP] (not counted as FAIL).
s1_passthru_check() {
  local srs dp
  srs=$(ls -d /sys/class/block/sr* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
  if [ -z "$srs" ]; then
    echo "[SKIP] skip_passthru growth: no /sys/class/block/sr* device (measured n/a, reference >= 1)"
    return
  fi
  sync
  snap S1_PT_A
  info "skip_passthru idle test: waiting ${S1_IDLE_S}s without I/O (sr devices: ${srs% })"
  sleep "$S1_IDLE_S"
  snap S1_PT_B
  if [ -z "${S1_PT_A[skip_passthru]+x}" ] || [ -z "${S1_PT_B[skip_passthru]+x}" ]; then
    bad "skip_passthru missing in stats (measured n/a, reference >= 1 in ${S1_IDLE_S}s); S1 kernel not loaded?"
    return
  fi
  dp=$(d S1_PT_A S1_PT_B skip_passthru)
  if [ "$dp" -ge 1 ]; then
    ok "skip_passthru grew without script I/O (measured +$dp in ${S1_IDLE_S}s, reference >= 1; sr devices: ${srs% })"
  else
    bad "skip_passthru did not grow without script I/O (measured +$dp in ${S1_IDLE_S}s, reference >= 1; sr devices: ${srs% })"
  fi
}
s1_passthru_check

# --- INSERT 20.3: pattern tests --------------------------------------------
# P1 -> in-range random -> P1 + random interference -> P2 -> P3 -> P4 -> random control
# (kd_restart before the tests that read pat_seq256 from offset 0 and before P3;
#  samon_stream_idle_ms is restored to its DEFAULTS value unconditionally at the
#  end of the in-range random test function)
#
# Measurement window (R9.9): drop cache -> wait_q0 -> snap A -> workload
# (-> sync for writes) -> wait_q0 -> snap B.  Deltas are B - A.
# NOTE: the kd_restart calls made by P1, the in-range random test, P1 + random
# interference and P3 (and by their toggle-0 re-runs in 20.4) go beyond R9
# criterion 1 ("once at start").  The User approved them on 2026-10-18 (design
# T4 "표 초기화"); they happen outside the measurement window.
# Precondition failures (R9.10) are [FAIL] lines with the reason in
# parentheses: residual pages, queue wait exceeded, P2 time exceeded, ...
# Within the toggle-on tests the preparation reads (outside the window) run with
# all toggles 0, so that the deferred queue holds no folio reference that could
# keep a page in the cache when it is dropped; the test toggle is set after the
# last cache drop, right before the window opens.

PT_SEQ=$DIR/pat_seq256; PT_RND=$DIR/pat_rand256; PT_64=$DIR/pat_64; PT_W=$DIR/pat_w256
PT_NAME=; PT_RES=fail; PT_MSG=; PT_DROPS=; PT_HAVE=0; PT_PREP_ERR=

# default_of NAME: value of NAME in DEFAULTS
default_of() {
  local kv
  for kv in $DEFAULTS; do
    [ "${kv%%=*}" = "$1" ] && { echo "${kv#*=}"; return 0; }
  done
  return 1
}
# pt_fail WHY: this test failed on a precondition (R9.10)
pt_fail() { PT_RES=fail; PT_MSG="$PT_NAME: precondition failed ($1)"; }
# pt_verdict 0|1 TEXT: judged result; TEXT carries measured and reference values
pt_verdict() {
  [ "$1" = 1 ] && PT_RES=pass || PT_RES=fail
  PT_MSG="$PT_NAME ($2; cache drop:${PT_DROPS:- n/a})"
}
# pt_tg PATTERN: set the toggles and verify them by reading them back
pt_tg() {
  if set_toggles "$1" 2>/dev/null && [ "$(get_toggles)" = "$1" ]; then return 0; fi
  pt_fail "cannot set toggles $1"; return 1
}
# pt_restart: all toggles 0, kdamond off -> on (outside the window), 1 s settle
pt_restart() {
  pt_tg 00000 || return 1
  kd_restart || { pt_fail "$KD_ERR"; return 1; }
  sleep 1
}
# pt_drop FILE: per-file cache drop (R9.8); remembers the method used
pt_drop() {
  if drop_file_cache "$1"; then
    PT_DROPS+=" $(basename "$1")=$DROP_HOW"; return 0
  fi
  pt_fail "residual pages: $DROP_RESID left in $(basename "$1") after nocache and drop_caches"
  return 1
}
# window edges (R9.9): wait for q_cur == 0, then read the stats
pt_open() {
  wait_q0 || { pt_fail "queue wait exceeded: q_cur != 0 for ${Q_WAIT_S}s before the window"; return 1; }
  snap PT_A
}
pt_close() {
  wait_q0 || { pt_fail "queue wait exceeded: q_cur != 0 for ${Q_WAIT_S}s after the workload"; return 1; }
  snap PT_B; PT_HAVE=1
}
pt_need() {
  local f
  for f in "$@"; do
    case "$PT_PREP_ERR" in
      *" $f"*) pt_fail "test file $(basename "$f") could not be created"; return 1 ;;
    esac
  done
}
pt_dd_read() { dd if="$1" of=/dev/null bs=1M status=none 2>/dev/null; }
pt_fio_rand() {   # NAME FILE [extra fio args]: buffered 4k randread over the whole file
  local n=$1 f=$2; shift 2
  fio --name="$n" --filename="$f" --rw=randread --bs=4k --direct=0 --ioengine=sync \
      --size="$(( $(stat -c %s "$f") / 1048576 ))M" --output=/dev/null "$@" >/dev/null 2>&1
}
pt_pct() { awk -v a="$1" -v p="$2" 'BEGIN{printf "%.2f", a*p/100}'; }   # a * p / 100

# info lines for the window: values that are not judged (R9.6)
pt_info() {
  local k s ds=0
  [ "$PT_HAVE" = 1 ] || return 0
  for k in 1 2 3 4 5 6; do ds=$((ds + $(d PT_A PT_B det_p$k))); done
  info "$PT_NAME: det_sum=$ds seg_buffered=$(d PT_A PT_B seg_buffered)"
  s=; for k in 1 2 3 4 5 6; do s+=" det_p$k=+$(d PT_A PT_B det_p$k)"; done
  info "$PT_NAME:$s"
  s=; for k in 1 2 3 4 5; do s+=" req_p$k=+$(d PT_A PT_B req_p$k) exec_p$k=+$(d PT_A PT_B exec_p$k)"; done
  info "$PT_NAME:$s"
  s=
  for k in stream_r_extend stream_r_prepend stream_r_fill stream_r_restart stream_r_new_slot stream_r_evict \
           stream_w_extend stream_w_prepend stream_w_fill stream_w_restart stream_w_new_slot stream_w_evict; do
    s+=" ${k#stream_}=+$(d PT_A PT_B "$k")"
  done
  info "$PT_NAME: Stream_Counters$s"
}
# pt_run NAME FUNCTION: run one test, print info lines and one verdict line.
# Toggles are put back to 00000 afterwards whatever the result was.
pt_run() {
  PT_NAME=$1; PT_RES=fail; PT_MSG="$1: no result"; PT_DROPS=; PT_HAVE=0
  "$2"
  pt_info
  set_toggles 00000 2>/dev/null
  if [ "$PT_RES" = pass ]; then ok "$PT_MSG"; else bad "$PT_MSG"; fi
}

# Test files: created and synced with all toggles 0, before the first test.
pt_make_one() {
  rm -f "$1"
  dd if=/dev/zero of="$1" bs=1M count="$2" conv=fsync status=none 2>/dev/null \
    && [ "$(stat -c %s "$1")" = $(($2 * 1048576)) ]
}
pt_make_files() {
  set_toggles 00000 2>/dev/null
  pt_make_one "$PT_SEQ" 256 || PT_PREP_ERR+=" $PT_SEQ"
  pt_make_one "$PT_RND" 256 || PT_PREP_ERR+=" $PT_RND"
  pt_make_one "$PT_64"   64 || PT_PREP_ERR+=" $PT_64"
  sync
  [ -z "$PT_PREP_ERR" ] || info "pattern test files could not be created:$PT_PREP_ERR"
}

# P1: one dd pass over pat_seq256.  Also the threshold for P1 + interference.
pt_p1_thr() { echo $(( $(stat -c %s "$PT_SEQ") / 4096 * P1_MIN_PCT / 100 )); }

pt_t_p1() {
  local thr dp ep
  pt_need "$PT_SEQ" || return
  pt_restart || return
  pt_drop "$PT_SEQ" || return
  pt_tg 10000 || return
  pt_open || return
  pt_dd_read "$PT_SEQ" || { pt_fail "dd of pat_seq256 failed"; return; }
  pt_close || return
  thr=$(pt_p1_thr)
  dp=$(d PT_A PT_B det_p1); ep=$(d PT_A PT_B exec_p1)
  if [ "$dp" -ge "$thr" ] && [ "$ep" -ge 1 ]; then pt_verdict 1 "measured det_p1=+$dp, reference >= $thr; exec_p1=+$ep, reference >= 1"
  else pt_verdict 0 "measured det_p1=+$dp, reference >= $thr; exec_p1=+$ep, reference >= 1"; fi
}

# In-range random: a live 256MiB read slot (kept alive by IDLE_HOLD_MS) and
# a 4KiB random read over the same range.  The window holds fio only.
pt_t_inrange_steps() {
  local dp1 dp6 rs ref
  pt_need "$PT_SEQ" || return
  pt_restart || return
  { echo "$IDLE_HOLD_MS" > $PARM/samon_stream_idle_ms; } 2>/dev/null \
    || { pt_fail "cannot write samon_stream_idle_ms"; return; }
  pt_drop "$PT_SEQ" || return
  pt_dd_read "$PT_SEQ" || { pt_fail "dd of pat_seq256 failed"; return; }
  pt_drop "$PT_SEQ" || return
  pt_tg 10000 || return
  pt_open || return
  pt_fio_rand sr "$PT_SEQ" || { pt_fail "fio sr failed"; return; }
  pt_close || return
  dp1=$(d PT_A PT_B det_p1); dp6=$(d PT_A PT_B det_p6); rs=$(d PT_A PT_B stream_r_restart)
  ref=$(pt_pct "$dp6" "$RAND_MAX_PCT")
  if [ $((dp1 * 100)) -lt $((dp6 * RAND_MAX_PCT)) ] && [ "$rs" -ge 1 ]; then
    pt_verdict 1 "measured det_p1=+$dp1, reference < det_p6(+$dp6) x $RAND_MAX_PCT/100 = $ref; stream_r_restart=+$rs, reference >= 1"
  else
    pt_verdict 0 "measured det_p1=+$dp1, reference < det_p6(+$dp6) x $RAND_MAX_PCT/100 = $ref; stream_r_restart=+$rs, reference >= 1"
  fi
}
pt_t_inrange() {
  local def got
  pt_t_inrange_steps
  # Unconditional: put samon_stream_idle_ms back to its DEFAULTS value, also
  # when the steps above failed or returned early.
  def=$(default_of samon_stream_idle_ms)
  { echo "$def" > $PARM/samon_stream_idle_ms; } 2>/dev/null
  got=$(cat $PARM/samon_stream_idle_ms 2>/dev/null)
  if [ "$got" != "$def" ]; then
    PT_RES=fail
    PT_MSG="$PT_MSG; could not restore samon_stream_idle_ms to $def (reads '$got')"
  fi
}

# P1 + random interference: background fio randread on another file while dd runs.
pt_t_interf() {
  local thr dp ep fp rc
  pt_need "$PT_SEQ" "$PT_RND" || return
  pt_restart || return
  pt_drop "$PT_SEQ" || return
  pt_drop "$PT_RND" || return
  pt_tg 10000 || return
  pt_open || return
  # started directly (not through a function) so that $! is fio itself
  fio --name=bg --filename="$PT_RND" --rw=randread --bs=4k --direct=0 --ioengine=sync \
      --size=256M --time_based --runtime=600 --output=/dev/null >/dev/null 2>&1 &
  fp=$!
  pt_dd_read "$PT_SEQ"; rc=$?
  kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
  [ "$rc" = 0 ] || { pt_fail "dd of pat_seq256 failed"; return; }
  pt_close || return
  thr=$(pt_p1_thr)
  dp=$(d PT_A PT_B det_p1); ep=$(d PT_A PT_B exec_p1)
  info "$PT_NAME: exec_p1=+$ep (not judged, background I/O)"
  if [ "$dp" -ge "$thr" ]; then pt_verdict 1 "measured det_p1=+$dp, reference >= $thr"
  else pt_verdict 0 "measured det_p1=+$dp, reference >= $thr"; fi
}

# P2: two identical randread passes on pat_64, second pass within samon_reread_ms.
pt_p2_pass() { pt_fio_rand p2 "$PT_64" --randrepeat=1 --time_based --runtime="$P2_PASS_S"; }
pt_t_p2() {
  local t1 t2 dt lim dp ep
  pt_need "$PT_64" || return
  pt_tg 00000 || return
  pt_drop "$PT_64" || return
  pt_tg 01000 || return
  pt_open || return
  t1=$(date +%s%3N)
  pt_p2_pass || { pt_fail "fio p2 (pass 1) failed"; return; }
  pt_drop "$PT_64" || return          # no queue wait between the passes (R9.9)
  t2=$(date +%s%3N)
  pt_p2_pass || { pt_fail "fio p2 (pass 2) failed"; return; }
  pt_close || return
  lim=$(cat $PARM/samon_reread_ms 2>/dev/null); lim=${lim:-$(default_of samon_reread_ms)}
  dt=$((t2 - t1))
  if [ "$dt" -gt "$lim" ]; then
    pt_fail "P2 time exceeded: pass 2 started ${dt} ms after pass 1, reference <= ${lim} ms"; return
  fi
  dp=$(d PT_A PT_B det_p2); ep=$(d PT_A PT_B exec_p2)
  if [ "$dp" -ge 1 ] && [ "$ep" -ge 1 ]; then pt_verdict 1 "measured det_p2=+$dp, reference >= 1; exec_p2=+$ep, reference >= 1; pass start interval ${dt} ms, reference <= ${lim} ms"
  else pt_verdict 0 "measured det_p2=+$dp, reference >= 1; exec_p2=+$ep, reference >= 1; pass start interval ${dt} ms, reference <= ${lim} ms"; fi
}

# P3: pass 1 outside the window, cache drop, pass 2 is the window.
pt_t_p3() {
  local dp ep
  pt_need "$PT_64" || return
  pt_restart || return
  pt_drop "$PT_64" || return
  pt_dd_read "$PT_64" || { pt_fail "dd of pat_64 (pass 1) failed"; return; }
  pt_drop "$PT_64" || return
  pt_tg 00100 || return
  pt_open || return
  pt_dd_read "$PT_64" || { pt_fail "dd of pat_64 (pass 2) failed"; return; }
  pt_close || return
  dp=$(d PT_A PT_B det_p3); ep=$(d PT_A PT_B exec_p3)
  if [ "$dp" -ge 1 ] && [ "$ep" -ge 1 ]; then pt_verdict 1 "measured det_p3=+$dp, reference >= 1; exec_p3=+$ep, reference >= 1"
  else pt_verdict 0 "measured det_p3=+$dp, reference >= 1; exec_p3=+$ep, reference >= 1"; fi
}

# P4: fresh 256MiB buffered write, sync inside the window.
pt_t_p4() {
  local dp ep
  pt_tg 00000 || return
  rm -f "$PT_W"; sync
  pt_tg 00010 || return
  pt_open || return
  dd if=/dev/zero of="$PT_W" bs=1M count=256 status=none 2>/dev/null \
    || { pt_fail "dd write of pat_w256 failed"; return; }
  sync
  pt_close || return
  dp=$(d PT_A PT_B det_p4); ep=$(d PT_A PT_B exec_p4)
  if [ "$dp" -ge 1 ] && [ "$ep" -ge 1 ]; then pt_verdict 1 "measured det_p4=+$dp, reference >= 1; exec_p4=+$ep, reference >= 1"
  else pt_verdict 0 "measured det_p4=+$dp, reference >= 1; exec_p4=+$ep, reference >= 1"; fi
}

# Random control: all toggles 0, only det is judged.
pt_t_rctl() {
  local dp1 dp6 ref
  pt_need "$PT_RND" || return
  pt_tg 00000 || return
  pt_drop "$PT_RND" || return
  pt_open || return
  pt_fio_rand rc "$PT_RND" || { pt_fail "fio rc failed"; return; }
  pt_close || return
  dp1=$(d PT_A PT_B det_p1); dp6=$(d PT_A PT_B det_p6)
  ref=$(pt_pct "$dp6" "$RAND_MAX_PCT")
  if [ $((dp1 * 100)) -lt $((dp6 * RAND_MAX_PCT)) ]; then
    pt_verdict 1 "measured det_p1=+$dp1, reference < det_p6(+$dp6) x $RAND_MAX_PCT/100 = $ref"
  else
    pt_verdict 0 "measured det_p1=+$dp1, reference < det_p6(+$dp6) x $RAND_MAX_PCT/100 = $ref"
  fi
}

PT_TESTS=("P1:pt_t_p1" "in-range random:pt_t_inrange" "P1 + random interference:pt_t_interf"
          "P2:pt_t_p2" "P3:pt_t_p3" "P4:pt_t_p4" "random control:pt_t_rctl")
if [ "$FINCORE_OK" = 1 ]; then
  pt_make_files
  for t in "${PT_TESTS[@]}"; do pt_run "${t%%:*}" "${t#*:}"; done
else
  # R9.8 / R9.10: without fincore every pattern test is a [FAIL]
  for t in "${PT_TESTS[@]}"; do
    bad "${t%%:*}: precondition failed (fincore missing, install util-linux-extra; test not run)"
  done
fi

# --- 20.4: toggle-0 re-runs, final accounting, post-stop checks -------------
# R9 criterion 4: P1..P4 are run again with samon_act_p1..p4 and samon_opt_b
# all 0, same procedure as above (cache drop, measurement window, P2 time
# condition).  In every window req_pN and exec_pN (N = 1..5) must stay +0 and
# the target pattern's det_pN must grow by >= 1.
# NOTE: like the original P1 and P3, the re-runs of P1 and P3 call kd_restart
# (through pt_restart) before the test, outside the window; this goes beyond
# R9 criterion 1 ("once at start") and was approved by the User (2026-10-18).
# Queued items dropped by the restart are counted as drop_shutdown, so the
# accounting equality below is unaffected.

# pt_zero_check: judge req_pN/exec_pN (N = 1..5) of the window PT_A..PT_B.
# Sets PT_ZERO_OK (1/0) and PT_ZERO_STR (measured values for the verdict line).
PT_ZERO_OK=1; PT_ZERO_STR=
pt_zero_check() {
  local k dr de
  PT_ZERO_OK=1; PT_ZERO_STR=
  for k in 1 2 3 4 5; do
    if [ -z "${PT_A[req_p$k]+x}" ] || [ -z "${PT_B[req_p$k]+x}" ] ||
       [ -z "${PT_A[exec_p$k]+x}" ] || [ -z "${PT_B[exec_p$k]+x}" ]; then
      PT_ZERO_OK=0; PT_ZERO_STR+=" req_p$k/exec_p$k=missing"; continue
    fi
    dr=$(d PT_A PT_B req_p$k); de=$(d PT_A PT_B exec_p$k)
    PT_ZERO_STR+=" req_p$k=+$dr exec_p$k=+$de"
    { [ "$dr" -eq 0 ] && [ "$de" -eq 0 ]; } || PT_ZERO_OK=0
  done
}
# pt_rerun_verdict N [EXTRA]: req/exec +0 for N = 1..5 and det_pN >= 1
pt_rerun_verdict() {
  local n=$1 dp ok=1
  pt_zero_check
  dp=$(d PT_A PT_B det_p$n)
  [ "$PT_ZERO_OK" = 1 ] && [ "$dp" -ge 1 ] || ok=0
  pt_verdict $ok "measured$PT_ZERO_STR; det_p$n=+$dp; reference req_pN=+0 exec_pN=+0 (N=1..5), det_p$n >= 1${2:+; $2}"
}

pt_r_p1() {
  pt_need "$PT_SEQ" || return
  pt_restart || return
  pt_drop "$PT_SEQ" || return
  pt_tg 00000 || return
  pt_open || return
  pt_dd_read "$PT_SEQ" || { pt_fail "dd of pat_seq256 failed"; return; }
  pt_close || return
  pt_rerun_verdict 1
}
pt_r_p2() {
  local t1 t2 dt lim
  pt_need "$PT_64" || return
  pt_tg 00000 || return
  pt_drop "$PT_64" || return
  pt_open || return
  t1=$(date +%s%3N)
  pt_p2_pass || { pt_fail "fio p2 (pass 1) failed"; return; }
  pt_drop "$PT_64" || return          # no queue wait between the passes (R9.9)
  t2=$(date +%s%3N)
  pt_p2_pass || { pt_fail "fio p2 (pass 2) failed"; return; }
  pt_close || return
  lim=$(cat $PARM/samon_reread_ms 2>/dev/null); lim=${lim:-$(default_of samon_reread_ms)}
  dt=$((t2 - t1))
  if [ "$dt" -gt "$lim" ]; then
    pt_fail "P2 time exceeded: pass 2 started ${dt} ms after pass 1, reference <= ${lim} ms"; return
  fi
  pt_rerun_verdict 2 "pass start interval ${dt} ms, reference <= ${lim} ms"
}
pt_r_p3() {
  pt_need "$PT_64" || return
  pt_restart || return
  pt_drop "$PT_64" || return
  pt_dd_read "$PT_64" || { pt_fail "dd of pat_64 (pass 1) failed"; return; }
  pt_drop "$PT_64" || return
  pt_tg 00000 || return
  pt_open || return
  pt_dd_read "$PT_64" || { pt_fail "dd of pat_64 (pass 2) failed"; return; }
  pt_close || return
  pt_rerun_verdict 3
}
pt_r_p4() {
  pt_tg 00000 || return
  rm -f "$PT_W"; sync
  pt_open || return
  dd if=/dev/zero of="$PT_W" bs=1M count=256 status=none 2>/dev/null \
    || { pt_fail "dd write of pat_w256 failed"; return; }
  sync
  pt_close || return
  pt_rerun_verdict 4
}

PT_RERUNS=("toggle-0 re-run P1:pt_r_p1" "toggle-0 re-run P2:pt_r_p2"
           "toggle-0 re-run P3:pt_r_p3" "toggle-0 re-run P4:pt_r_p4")
if [ "$FINCORE_OK" = 1 ]; then
  for t in "${PT_RERUNS[@]}"; do pt_run "${t%%:*}" "${t#*:}"; done
else
  for t in "${PT_RERUNS[@]}"; do
    bad "${t%%:*}: precondition failed (fincore missing, install util-linux-extra; test not run)"
  done
fi

# Final accounting (R9 criterion 5, R4 criteria 3/4/7).
# acct_check SNAP: for N = 1..5, req_pN == exec_pN + drop_{queue,stale,
# revalidate,toggle,shutdown}_pN, using the absolute (cumulative since boot)
# values of the snapshot.  Sets ACC_OK (1/0) and ACC_STR (measured values).
ACC_OK=1; ACC_STR=
acct_check() {
  local -n __ac=$1
  local n key v req sum
  ACC_OK=1; ACC_STR=
  for n in 1 2 3 4 5; do
    req=${__ac[req_p$n]:-}
    if ! [[ $req =~ ^[0-9]+$ ]]; then
      ACC_OK=0; ACC_STR+=" p$n: req_p$n missing"; continue
    fi
    sum=0
    for key in exec_p$n drop_queue_p$n drop_stale_p$n drop_revalidate_p$n drop_toggle_p$n drop_shutdown_p$n; do
      v=${__ac[$key]:-}
      if ! [[ $v =~ ^[0-9]+$ ]]; then
        ACC_OK=0; ACC_STR+=" p$n: $key missing"; continue 2
      fi
      sum=$((sum + v))
    done
    ACC_STR+=" p$n: req=$req exec+drops=$sum"
    [ "$req" -eq "$sum" ] || ACC_OK=0
  done
}
# acct_judge SNAP LABEL: the equality item and the direct_ops item for one snapshot
acct_judge() {
  local dop
  acct_check "$1"
  if [ "$ACC_OK" = 1 ]; then
    ok "$2: req_pN == exec_pN + drop_queue + drop_stale + drop_revalidate + drop_toggle + drop_shutdown for N=1..5 (measured$ACC_STR; reference req == exec+drops)"
  else
    bad "$2: accounting equality broken or counters missing (measured$ACC_STR; reference req == exec+drops)"
  fi
  local -n __aj=$1
  dop=${__aj[direct_ops]:-}
  if [[ $dop =~ ^[0-9]+$ ]] && [ "$dop" -eq 0 ]; then
    ok "$2: direct_ops == 0 (measured $dop, reference 0)"
  else
    bad "$2: direct_ops != 0 (measured '${dop:-missing}', reference 0)"
  fi
}
final_accounting() {
  local qc
  set_toggles 00000 2>/dev/null
  if [ "$(get_toggles)" != 00000 ]; then
    bad "final accounting: precondition failed (cannot set toggles 00000)"
  fi
  if wait_q0; then
    snap FIN_A
    acct_judge FIN_A "after wait_q0 (kdamond on)"
  else
    snap FIN_A
    bad "after wait_q0 (kdamond on): precondition failed (queue wait exceeded: q_cur=${FIN_A[q_cur]:-?} != 0 for ${Q_WAIT_S}s)"
  fi
  echo off > $KD/0/state
  if wait_state off; then
    snap FIN_B
    qc=${FIN_B[q_cur]:-}
    if [[ $qc =~ ^[0-9]+$ ]] && [ "$qc" -eq 0 ]; then
      ok "after kdamond off: q_cur == 0 (measured $qc, reference 0)"
    else
      bad "after kdamond off: q_cur != 0 (measured '${qc:-missing}', reference 0)"
    fi
    acct_judge FIN_B "after kdamond off"
  else
    bad "after kdamond off: precondition failed (kdamond did not stop within 10s)"
  fi
}
final_accounting

echo "stats:"; cat $DBG/stats
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
