#!/bin/bash
# samon_q_len sweep: how often the Deferred_Queue overflows (drop_queue) in the
# sequential tests P1, P4 and P3, for several per-CPU queue sizes.
#
# Usage: sudo bash samon_qlen_sweep.sh [-d dir-on-disk] [-q "1024 4096 8192 16384"]
#
# For each samon_q_len value: write it, kdamond off -> on (the value is read at
# kdamond start; q_cap in stats confirms it), then run P1 (256MiB dd sequential
# read), P4 (256MiB dd sequential write + sync) and P3 (64MiB, 2nd pass of a
# 2-pass read) the same way verify_samon.sh does: only the test's toggle is 1,
# the file cache is dropped before the test, and the stats deltas are taken
# between two wait_q0 + snapshot points.  kdamond is restarted (toggles 0)
# before every test, outside the window, so q_max_delay_us (reset at kdamond
# start) is the maximum of that test alone.
#
# Unlike verify_samon.sh this script does not write the DEFAULTS: every other
# parameter keeps its current value (printed in the header).  On exit, also
# on error or Ctrl-C, samon_q_len and the five toggles are put back to the
# values they had at start and kdamond is turned off.
#
# The helper functions are taken from verify_samon.sh at run time (that file
# is not modified and not executed); see load_verify_helpers.
set -u

QLENS="1024 4096 8192 16384"
DIR=/var/tmp/samon_qlen_sweep
Q_WAIT_S=5             # wait_q0: max wait for q_cur == 0, seconds (as verify)

usage() { echo "usage: $0 [-d dir-on-disk] [-q \"QLEN ...\"]"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -d) [ -n "${2:-}" ] || { usage; exit 2; }; DIR=$2; shift 2 ;;
    -q) [ -n "${2:-}" ] || { usage; exit 2; }; QLENS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
for v in $QLENS; do
  [[ $v =~ ^[1-9][0-9]*$ ]] || { echo "bad q_len value '$v' (positive integers only)"; exit 2; }
done

DBG=/sys/kernel/debug/samon
KD=/sys/kernel/mm/damon/admin/kdamonds
PARM=/sys/module/saddr/parameters
VERIFY=$(dirname "$(readlink -f "$0")")/verify_samon.sh

# ---- helpers reused from verify_samon.sh ------------------------------------
# Each named function is cut out of verify_samon.sh and defined here.  A
# definition is either one line ("name() { ...; }") or runs from "name() {"
# to the first line that is exactly "}".  Globals they use (DBG, KD, PARM,
# Q_WAIT_S, DROP_HOW, DROP_RESID, KD_ERR) are set in this script.
VERIFY_FNS="st_get fincore_pages drop_file_cache wait_q0 snap d set_toggles get_toggles wait_state kd_restart"
DROP_HOW=; DROP_RESID=; KD_ERR=
extract_fn() {
  awk -v n="$1() {" '
    !inside && index($0, n) == 1 { print; if ($0 ~ /}[[:space:]]*$/) exit; inside = 1; next }
    inside { print; if ($0 == "}") exit }' "$VERIFY"
}
load_verify_helpers() {
  local f src
  [ -r "$VERIFY" ] || { echo "cannot read $VERIFY"; exit 2; }
  for f in $VERIFY_FNS; do
    src=$(extract_fn "$f")
    [ -n "$src" ] || { echo "helper $f() not found in $VERIFY"; exit 2; }
    # shellcheck disable=SC1090
    source <(printf '%s\n' "$src")
    declare -F "$f" >/dev/null || { echo "helper $f() could not be defined from $VERIFY"; exit 2; }
  done
}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
load_verify_helpers
command -v fincore >/dev/null 2>&1 || { echo "fincore missing (install util-linux-extra)"; exit 2; }
[ -w $PARM/samon_q_len ] || { echo "$PARM/samon_q_len missing (S1 kernel not running?)"; exit 2; }

mkdir -p "$DIR"
[ "$(findmnt -no FSTYPE -T "$DIR")" = tmpfs ] && { echo "$DIR is tmpfs; choose a disk-backed dir"; exit 2; }
F_SEQ=$DIR/pat_seq256; F_64=$DIR/pat_64; F_W=$DIR/pat_w256

# ---- remember and restore (armed before kdamond is touched) -----------------
ORIG_QLEN=$(cat $PARM/samon_q_len)
ORIG_TG=$(get_toggles)
restore() {
  local rc=$?
  trap - EXIT
  set_toggles "$ORIG_TG" 2>/dev/null
  echo "$ORIG_QLEN" > $PARM/samon_q_len 2>/dev/null
  echo off > $KD/0/state 2>/dev/null; wait_state off
  echo "restored: samon_q_len=$(cat $PARM/samon_q_len) toggles=$(get_toggles) kdamond=$(cat $KD/0/state)"
  exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT TERM

# ---- kdamond set-up (same layout as verify_samon.sh) ------------------------
if [ "$(cat $KD/0/state 2>/dev/null)" != on ]; then
  echo 1 > $KD/nr_kdamonds; echo 1 > $KD/0/contexts/nr_contexts
  echo saddr > $KD/0/contexts/0/operations
  echo 1 > $KD/0/contexts/0/targets/nr_targets
  echo on > $KD/0/state
  wait_state on || { echo "kdamond did not start"; exit 1; }
fi
[ "$(cat $KD/0/contexts/0/operations)" = saddr ] || { echo "kdamond 0 does not use operations=saddr"; exit 1; }
[ -n "$(st_get q_cap)" ] || { echo "stats has no q_cap line (S1 kernel not running?)"; exit 1; }

param() { cat "$PARM/$1" 2>/dev/null || echo '?'; }
echo "kernel: $(uname -r) $(uname -v)"
echo "dir=$DIR q_lens=\"$QLENS\" sample_us=$(cat $KD/0/contexts/0/monitoring_attrs/intervals/sample_us 2>/dev/null || echo '?') nproc=$(nproc)"
echo "start: samon_q_len=$ORIG_QLEN toggles=$ORIG_TG q_max_ms=$(param samon_q_max_ms) seq_min=$(param samon_seq_min) stream_new_kb=$(param samon_stream_new_kb) loop_min_kb=$(param samon_loop_min_kb) dev=$(param samon_dev_major):$(param samon_dev_minor) dbg_lba=$(param samon_dbg_lba)"

# ---- test files (created with all toggles 0) --------------------------------
make_file() {   # FILE MiB: create if missing or of the wrong size
  [ "$(stat -c %s "$1" 2>/dev/null)" = $(($2 * 1048576)) ] && return 0
  rm -f "$1"
  dd if=/dev/zero of="$1" bs=1M count="$2" conv=fsync status=none 2>/dev/null \
    && [ "$(stat -c %s "$1")" = $(($2 * 1048576)) ]
}
set_toggles 00000
make_file "$F_SEQ" 256 || { echo "cannot create $F_SEQ"; exit 1; }
make_file "$F_64" 64   || { echo "cannot create $F_64"; exit 1; }
sync

# ---- one test ---------------------------------------------------------------
# Every test sets R_ERR on a precondition failure, or R_REQ R_DQ R_EXEC R_QMAX.
CUR_Q=
R_ERR=; R_REQ=; R_DQ=; R_EXEC=; R_QMAX=
sw_err() { R_ERR=$1; return 1; }
sw_tg() { set_toggles "$1" 2>/dev/null && [ "$(get_toggles)" = "$1" ] || sw_err "cannot set toggles $1"; }
# toggles 0, kdamond off -> on, and q_cap must still be this run's q_len
sw_restart() {
  sw_tg 00000 || return 1
  kd_restart || sw_err "$KD_ERR" || return 1
  sleep 1
  [ "$(st_get q_cap)" = "$CUR_Q" ] || sw_err "q_cap=$(st_get q_cap) after restart, expected $CUR_Q"
}
sw_drop() {
  drop_file_cache "$1" || sw_err "residual pages: $DROP_RESID left in $(basename "$1")"
}
sw_open()  { wait_q0 || sw_err "q_cur != 0 for ${Q_WAIT_S}s before the window" || return 1; snap SW_A; }
sw_close() { wait_q0 || sw_err "q_cur != 0 for ${Q_WAIT_S}s after the workload" || return 1; snap SW_B; }
sw_result() {   # N: pattern number
  R_REQ=$(d SW_A SW_B "req_p$1"); R_DQ=$(d SW_A SW_B "drop_queue_p$1")
  R_EXEC=$(d SW_A SW_B "exec_p$1"); R_QMAX=${SW_B[q_max_delay_us]:-?}
}

sw_t_p1() {
  sw_restart || return
  sw_drop "$F_SEQ" || return
  sw_tg 10000 || return
  sw_open || return
  dd if="$F_SEQ" of=/dev/null bs=1M status=none 2>/dev/null || { sw_err "dd read of pat_seq256 failed"; return; }
  sw_close || return
  sw_result 1
}
sw_t_p4() {
  sw_restart || return
  rm -f "$F_W"; sync
  sw_tg 00010 || return
  sw_open || return
  dd if=/dev/zero of="$F_W" bs=1M count=256 status=none 2>/dev/null || { sw_err "dd write of pat_w256 failed"; return; }
  sync
  sw_close || return
  sw_result 4
}
sw_t_p3() {
  sw_restart || return
  sw_drop "$F_64" || return
  dd if="$F_64" of=/dev/null bs=1M status=none 2>/dev/null || { sw_err "dd of pat_64 (pass 1) failed"; return; }
  sw_drop "$F_64" || return
  sw_tg 00100 || return
  sw_open || return
  dd if="$F_64" of=/dev/null bs=1M status=none 2>/dev/null || { sw_err "dd of pat_64 (pass 2) failed"; return; }
  sw_close || return
  sw_result 3
}

pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b > 0) printf "%.2f", a * 100 / b; else printf "n/a" }'; }

# ---- sweep ------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
CSV=$DIR/qlen_sweep_$TS.csv
echo "q_len,pattern,req,drop_queue,drop_pct,exec,q_max_delay_us,error" > "$CSV"
declare -A RES
NERR=0
PATS="P1:sw_t_p1 P4:sw_t_p4 P3:sw_t_p3"

for CUR_Q in $QLENS; do
  if ! { echo "$CUR_Q" > $PARM/samon_q_len; } 2>/dev/null || [ "$(cat $PARM/samon_q_len)" != "$CUR_Q" ]; then
    echo "q_len=$CUR_Q: ERROR (cannot write samon_q_len)"; NERR=$((NERR+3))
    for t in $PATS; do RES[$CUR_Q,${t%%:*}]="ERR"; done
    continue
  fi
  for t in $PATS; do
    p=${t%%:*}; R_ERR=; R_REQ=; R_DQ=; R_EXEC=; R_QMAX=
    "${t#*:}"
    sw_tg 00000 2>/dev/null
    if [ -n "$R_ERR" ]; then
      echo "q_len=$CUR_Q $p: ERROR ($R_ERR)"
      echo "$CUR_Q,$p,,,,,,\"$R_ERR\"" >> "$CSV"
      RES[$CUR_Q,$p]="ERR"; NERR=$((NERR+1))
      continue
    fi
    pc=$(pct "$R_DQ" "$R_REQ")
    echo "q_len=$CUR_Q $p: req=+$R_REQ drop_queue=+$R_DQ drop=${pc}% exec=+$R_EXEC q_max_delay_us=$R_QMAX"
    echo "$CUR_Q,$p,$R_REQ,$R_DQ,$pc,$R_EXEC,$R_QMAX," >> "$CSV"
    RES[$CUR_Q,$p]="$R_REQ $R_DQ $pc $R_QMAX"
  done
done

# ---- summary ----------------------------------------------------------------
echo
echo "summary (drop = drop_queue / req; all<1% = every pattern has drop_queue x 100 < req)"
printf '%-7s | %-24s | %-24s | %-24s | %-6s\n' q_len "P1 req drop% qmax_us" "P4 req drop% qmax_us" "P3 req drop% qmax_us" "all<1%"
for q in $QLENS; do
  line=$(printf '%-7s' "$q"); any_no=0; any_na=0
  for p in P1 P4 P3; do
    r=${RES[$q,$p]:-ERR}
    if [ "$r" = ERR ]; then
      cell=ERROR; any_na=1
    else
      read -r req dq pc qm <<< "$r"
      cell="$req $pc $qm"
      if [ "$req" -eq 0 ]; then any_na=1     # nothing requested: cannot judge
      elif [ $((dq * 100)) -ge "$req" ]; then any_no=1
      fi
    fi
    line+=$(printf ' | %-24s' "$cell")
  done
  if [ "$any_no" = 1 ]; then all=no; elif [ "$any_na" = 1 ]; then all=n/a; else all=yes; fi
  printf '%s | %-6s\n' "$line" "$all"
done
echo "csv: $CSV"
echo "SWEEP_DONE errors=$NERR"
[ "$NERR" -eq 0 ]
