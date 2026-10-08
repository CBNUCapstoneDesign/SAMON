#!/bin/bash
# SAMON measurement harness (dev-step.md step 13).
#
# Compares: off (kdamond stopped, no probe) / off2 (second baseline, gives the
# run-to-run noise) / on_noB (probe on, folio_mark_accessed disabled) /
# on_B (probe on, option B enabled), under a cgroup v2 memory limit.
#
# Workload "mixed": a zipf randrw hot set (the job we report) runs together
# with a sequential-read scan of a larger file (cache pollution), as in
# plan.md section 8.  Workload "zipf": hot set only.
#
# usage: sudo bash samon_bench.sh [-d DIR] [-s hot_size] [-S scan_size]
#                                 [-m mem_max] [-t secs] [-n reps] [-w mixed|zipf]
#                                 [-o outdir] [-r ramp_secs] [-E max_entries] [-D]
#   -D  dry run: no root needed, no cgroup/kdamond/params, only fio + CSV
#       pipeline (for testing the harness itself; the numbers mean nothing)
set -u
DIR=/var/tmp/samon_bench; HOT=1G; SCAN=2G; MEM=768M; SECS=60; REPS=5; WL=mixed
OUT=""; DRY=0; RAMP=10; MAXENT=2097152
while getopts "d:s:S:m:t:n:w:o:r:E:D" o; do case $o in
  d) DIR=$OPTARG;; s) HOT=$OPTARG;; S) SCAN=$OPTARG;; m) MEM=$OPTARG;;
  t) SECS=$OPTARG;; n) REPS=$OPTARG;; w) WL=$OPTARG;; o) OUT=$OPTARG;; r) RAMP=$OPTARG;; E) MAXENT=$OPTARG;; D) DRY=1;;
  *) exit 2;; esac; done

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results/$(date +%Y%m%d-%H%M%S)}
KD=/sys/kernel/mm/damon/admin/kdamonds
PARM=/sys/module/saddr/parameters
DBG=/sys/kernel/debug/samon
CG=/sys/fs/cgroup/samon_bench
MODES="off off2 on_noB on_B"

if [ $DRY = 0 ]; then
  [ "$(id -u)" = 0 ] || { echo "run as root (or use -D for a dry run)"; exit 2; }
  [ "$(findmnt -no FSTYPE -T "$DIR" 2>/dev/null || echo x)" != tmpfs ] || { echo "$DIR is tmpfs"; exit 2; }
  [ -r $DBG/stats ] || { echo "no $DBG/stats: SAMON kernel not running?"; exit 2; }
  grep -q memory /sys/fs/cgroup/cgroup.controllers || { echo "cgroup v2 memory controller missing"; exit 2; }
fi
mkdir -p "$DIR" "$OUT"
CSV=$OUT/runs.csv

st_get() { awk -F= -v k="$1" '$1==k{print $2+0}' $DBG/stats 2>/dev/null || echo 0; }
vm_get() { awk -v k="$1" '$1==k{print $2}' /proc/vmstat; }
VMKEYS="pgpgin pgpgout pgsteal_file pgsteal_kswapd pgsteal_direct pgscan_kswapd pgscan_direct pgactivate pgdeactivate workingset_refault_file workingset_activate_file"
STKEYS="rq_seen seg_buffered mark_accessed skip_dev skip_anon skip_nomap skip_pinned drop_full drop_nomem"
CGKEYS="pgscan pgsteal pgactivate pgdeactivate workingset_refault_file workingset_activate_file"

wait_state() { for _ in $(seq 1 50); do [ "$(cat $KD/0/state)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
set_mode() {
  [ $DRY = 1 ] && return 0
  case $1 in
    off|off2)
      # writing "off" to an already stopped kdamond fails with EPERM; only stop if running
      [ "$(cat $KD/0/state)" = off ] || { echo off > $KD/0/state; wait_state off || { echo "kdamond stop failed"; exit 1; }; } ;;
    on_noB|on_B)
      # restart every run so each starts with an empty LBA tree; leftovers from the
      # previous run would otherwise saturate samon_max_entries (drop_full) and bias results
      [ "$(cat $KD/0/state)" = off ] || { echo off > $KD/0/state; wait_state off || { echo "kdamond stop failed"; exit 1; }; }
      echo on > $KD/0/state; wait_state on || { echo "kdamond start failed"; exit 1; }
      [ $1 = on_B ] && echo 1 > $PARM/samon_opt_b || echo 0 > $PARM/samon_opt_b
      echo $DMAJ > $PARM/samon_dev_major; echo $DMIN > $PARM/samon_dev_minor ;;
  esac
}
restore() {
  [ $DRY = 1 ] && return
  echo 65536 > $PARM/samon_max_entries 2>/dev/null; echo 1 > $PARM/samon_opt_b 2>/dev/null; echo 0 > $PARM/samon_dev_major 2>/dev/null; echo 0 > $PARM/samon_dev_minor 2>/dev/null
  rmdir $CG 2>/dev/null
}
trap restore EXIT

if [ $DRY = 0 ]; then
  SRC=$(findmnt -no SOURCE -T "$DIR"); PART=$(basename "$(readlink -f "$SRC")")
  DISK=$(basename "$(readlink -f /sys/class/block/$PART/..)")
  [ -e /sys/class/block/$PART/partition ] || DISK=$PART
  DMAJ=$(cut -d: -f1 /sys/class/block/$DISK/dev); DMIN=$(cut -d: -f2 /sys/class/block/$DISK/dev)
  echo "target disk $DISK ($DMAJ:$DMIN), mem_max=$MEM, hot=$HOT scan=$SCAN, ${SECS}s x $REPS reps, workload=$WL"
  AVAIL=$(df --output=avail -BM "$DIR" | tail -1 | tr -dc 0-9)
  [ "$AVAIL" -gt 8000 ] || { echo "need >8GB free in $DIR"; exit 2; }
fi

# prefill outside the cgroup so the files exist on disk
echo "prefill..."
fio --name=fill_hot --filename=$DIR/hot.dat --size=$HOT --rw=write --bs=1M --direct=0 --end_fsync=1 --eta=never --output=/dev/null
[ "$WL" = mixed ] && fio --name=fill_scan --filename=$DIR/scan.dat --size=$SCAN --rw=write --bs=1M --direct=0 --end_fsync=1 --eta=never --output=/dev/null

jobfile() {
  cat <<JOB
[global]
ioengine=psync
direct=0
time_based
runtime=$SECS
ramp_time=$RAMP
[hot]
group_reporting
filename=$DIR/hot.dat
size=$HOT
rw=randrw
rwmixread=50
bs=4k
random_distribution=zipf:1.2
numjobs=2
fdatasync=32
JOB
  if [ "$WL" = mixed ]; then cat <<JOB
[scan]
new_group
group_reporting
filename=$DIR/scan.dat
size=$SCAN
rw=read
bs=128k
numjobs=1
JOB
  fi
}

[ $DRY = 0 ] && echo $MAXENT > $PARM/samon_max_entries   # data set (hot+scan) has far more 4KB LBAs than the default cap
echo "run,mode,rep,hot_r_iops,hot_w_iops,hot_r_p99_us,hot_w_p99_us,scan_bw_kib,$(echo $VMKEYS | tr ' ' ','),$(echo $STKEYS | tr ' ' ','),$(for k in $CGKEYS; do printf 'cg_%s,' $k; done | sed 's/,$//')" > $CSV
RUN=0
for rep in $(seq 1 $REPS); do
  for mode in $(echo $MODES | tr ' ' '\n' | shuf); do
    RUN=$((RUN+1)); echo "[run $RUN] rep=$rep mode=$mode"
    set_mode $mode
    sync; [ $DRY = 0 ] && echo 3 > /proc/sys/vm/drop_caches
    declare -A V0 S0
    for k in $VMKEYS; do V0[$k]=$(vm_get $k); done
    [ $DRY = 0 ] && [ "${mode#on}" != "$mode" ] && for k in $STKEYS; do S0[$k]=$(st_get $k); done
    jobfile > $OUT/job.fio
    if [ $DRY = 1 ]; then
      fio $OUT/job.fio --output-format=json --output=$OUT/run$RUN.json >/dev/null 2>&1
    else
      mkdir -p $CG; echo $MEM > $CG/memory.max; echo 0 > $CG/memory.swap.max
      bash -c "echo \$\$ > $CG/cgroup.procs; exec fio $OUT/job.fio --output-format=json --output=$OUT/run$RUN.json" >/dev/null 2>&1
      # global pgscan/pgsteal do not count memcg-limit reclaim, so read the cgroup's own counters
      CGD=""; for k in $CGKEYS; do CGD="$CGD,$(awk -v k=$k '$1==k{print $2}' $CG/memory.stat)"; done
      rmdir $CG 2>/dev/null
    fi
    ROW=$(python3 - "$OUT/run$RUN.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
jobs={j['jobname']:j for j in d['jobs']}
def g(job,rw,key):
    j=jobs.get(job); 
    if not j: return 0
    return j[rw].get(key,0)
def p99(job,rw):
    j=jobs.get(job)
    if not j: return 0
    p=j[rw].get('clat_ns',{}).get('percentile',{})
    return round(p.get('99.000000',0)/1000,1)
print(",".join(str(x) for x in [round(g('hot','read','iops'),1),round(g('hot','write','iops'),1),p99('hot','read'),p99('hot','write'),round(g('scan','read','bw'),1) if 'scan' in jobs else 0]))
PY
)
    VD=""; for k in $VMKEYS; do VD="$VD,$(( $(vm_get $k) - ${V0[$k]} ))"; done
    SD=""; for k in $STKEYS; do
      if [ $DRY = 0 ] && [ "${mode#on}" != "$mode" ]; then SD="$SD,$(( $(st_get $k) - ${S0[$k]} ))"; else SD="$SD,0"; fi; done
    [ $DRY = 1 ] && CGD=",0,0,0,0,0,0"
    if [ $DRY = 0 ] && [ "${mode#on}" != "$mode" ]; then
      DFD=$(( $(st_get drop_full) - ${S0[drop_full]} ))
      [ "$DFD" -gt 0 ] && echo "  WARNING: LBA tree saturated in this run (drop_full +$DFD); raise -E, results are biased"
    fi
    echo "$RUN,$mode,$rep,$ROW$VD$SD$CGD" >> $CSV
  done
done
python3 "$HERE/summarize.py" "$CSV" | tee "$OUT/summary.md"
echo "results: $OUT"
