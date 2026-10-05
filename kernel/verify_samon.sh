#!/bin/bash
# SAMON saddr verification script.  Usage: sudo bash verify_samon.sh [dir-on-disk]
# The directory must live on a real block-device filesystem (not tmpfs).
set -u
DIR=${1:-/var/tmp/samon_verify}
DBG=/sys/kernel/debug/samon
KD=/sys/kernel/mm/damon/admin/kdamonds
PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
st_get() { awk -F= -v k="$1" '$1==k{print $2+0}' $DBG/stats; }

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
mkdir -p "$DIR"
DEV=$(findmnt -no SOURCE -T "$DIR"); FST=$(findmnt -no FSTYPE -T "$DIR")
[ "$FST" = tmpfs ] && { echo "$DIR is tmpfs; choose a disk-backed dir"; exit 2; }
PART=$(basename "$(readlink -f "$DEV")")
START=$(cat /sys/class/block/$PART/start 2>/dev/null || echo 0)
BS=$(stat -f -c %S "$DIR")
echo "dev=$DEV fs=$FST partition_start=$START fs_block=$BS"

# kdamond on (tracepoint is registered when kdamond starts)
if [ "$(cat $KD/0/state 2>/dev/null)" != on ]; then
  echo 1 > $KD/nr_kdamonds; echo 1 > $KD/0/contexts/nr_contexts
  echo saddr > $KD/0/contexts/0/operations
  echo 1 > $KD/0/contexts/0/targets/nr_targets
  echo on > $KD/0/state; sleep 1
fi
[ "$(cat $KD/0/state)" = on ] && ok "kdamond on" || { bad "kdamond not on"; exit 1; }
[ -r $DBG/stats ] && ok "stats file present" || { bad "no stats file (old kernel?)"; exit 1; }

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


PARM=/sys/module/saddr/parameters
BASEDIR=$(dirname "$(readlink -f "$0")")
wait_state() { for _ in $(seq 1 50); do [ "$(cat $KD/0/state)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
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
DM0=$(dmesg | wc -l); FIRST=""; LAST=""; LEAK=0
for c in $(seq 1 10); do
  echo off > $KD/0/state; wait_state off || { bad "kdamond did not stop (cycle $c)"; break; }
  E=$(awk -F'[= ]' '/^entries=/{print $2}' $DBG/stats)
  [ "$E" -eq 0 ] || { LEAK=1; echo "cycle $c: entries=$E after off"; }
  echo on > $KD/0/state; wait_state on || { bad "kdamond did not restart (cycle $c)"; break; }
  G0=$(st_get seg_buffered)
  dd if=/dev/zero of=$DIR/cyc bs=4k count=1024 conv=fsync status=none; sync; sleep 0.5
  D=$(( $(st_get seg_buffered) - G0 ))
  [ -z "$FIRST" ] && FIRST=$D; LAST=$D
done
echo "cycle test: seg_buffered delta first=$FIRST last=$LAST (10 off/on cycles)"
[ "$LEAK" -eq 0 ] && ok "rbtree emptied on every kdamond stop" || bad "entries left after stop"
[ -n "$FIRST" ] && [ "$LAST" -le $((FIRST*2+200)) ] && ok "per-I/O count stable across cycles (probe not duplicated)" || bad "count grew across cycles"
NEWWARN=$(dmesg | tail -n +$((DM0+1)) | grep -ciE 'BUG:|WARNING:|Oops|KASAN|lockdep|RCU stall|soft lockup')
[ "$NEWWARN" -eq 0 ] && ok "no kernel warnings during tests" || bad "kernel warnings in dmesg ($NEWWARN)"

echo "stats:"; cat $DBG/stats
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
