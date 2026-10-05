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

echo "stats:"; cat $DBG/stats
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
