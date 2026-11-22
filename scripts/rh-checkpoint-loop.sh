#!/usr/bin/env bash
# Every RH_CKPT_EVERY_MIN minutes: upload new build outputs (scripts/rh-checkpoint.sh push), record a
# progress line, then commit and push the checkpoint INDEX and the progress log to the branch.
# Stops when step2.done exists (after one last push).
# Run detached:  RH_CKPT_EVERY_MIN=60 setsid nohup scripts/rh-checkpoint-loop.sh > /home/user/rh-logs/ckpt-loop.log 2>&1 < /dev/null &
#
# Pushed to the branch, next to the INDEX (verification/runs/<RUN>/):
#   progress.tsv        one line per loop pass: time, modules built, rate, free disk, memory, zram, shards
#   monitor-step2.tsv   the driver's 1-minute resource samples (append-only; old header, see the audit)
#   build-tail.log      the last 200 lines of the lake build log (rewritten each pass)
#   driver-tail.log     the last 50 lines of the driver log
# The full build log is not pushed: it grows to many MB and git would keep a copy of every version.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RH_WORK:-/home/user/rh-verify}"
EVERY="${RH_CKPT_EVERY_MIN:-60}"
BRANCH="${RH_CKPT_BRANCH:-ccr-bdb3a003-2b6l4u}"
RUN="${RH_CKPT_RUN:-20261122-step2-live}"
DRIVER_LOG="${RH_DRIVER_LOG:-/home/user/rh-logs/step2-driver.log}"
IDX=verification/checkpoints/step2/INDEX.tsv
RUNDIR="verification/runs/$RUN"
PROG="$REPO/$RUNDIR/progress.tsv"

progress_line() {
  local now mods prev_mods prev_t rate free mem zr shards
  now=$(date +%s)
  mods=$(find "$WORK/build/.lake/build" -name '*.olean' 2>/dev/null | wc -l)
  rate="-"
  if [ -s "$PROG" ]; then
    prev_mods=$(tail -n1 "$PROG" | cut -f3); prev_t=$(tail -n1 "$PROG" | cut -f2)
    [ -n "$prev_t" ] && [ "$now" -gt "$prev_t" ] && rate=$(awk -v a="$mods" -v b="$prev_mods" -v dt=$((now-prev_t)) 'BEGIN {printf "%.1f", (a-b)*60/dt}')
  fi
  free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  mem=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  zr=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print int((t-f)/1024)}' /proc/meminfo)
  shards=$(tail -n +2 "$REPO/$IDX" 2>/dev/null | wc -l)
  mkdir -p "$(dirname "$PROG")"
  [ -s "$PROG" ] || printf 'utc\tepoch\toleans\tmodules_per_min\tfree_disk_gb\tmem_avail_mb\tswap_used_mb\tshards\n' > "$PROG"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$now" "$mods" "$rate" "$free" "$mem" "$zr" "$shards" >> "$PROG"
}

one() {
  bash "$REPO/scripts/rh-checkpoint.sh" push 2>&1 | grep -v -E 'it/s|MB/s|%\|' | tail -5
  cd "$REPO" || return
  progress_line
  [ -f "$WORK/logs/monitor-step2.tsv" ] && cp "$WORK/logs/monitor-step2.tsv" "$RUNDIR/monitor-step2.tsv"
  [ -f "$WORK/logs/step2-build.log" ] && tail -n 200 "$WORK/logs/step2-build.log" | cut -c1-300 > "$RUNDIR/build-tail.log"
  [ -f "$DRIVER_LOG" ] && tail -n 50 "$DRIVER_LOG" | cut -c1-400 > "$RUNDIR/driver-tail.log"
  git add -- "$IDX" "$RUNDIR" 2>/dev/null
  if ! git diff --cached --quiet -- "$IDX" "$RUNDIR"; then
    git commit -q -m "Step 2 progress and checkpoint index ($(tail -n1 "$PROG" | cut -f3) modules, $(tail -n +2 "$IDX" | wc -l) shards)" -- "$IDX" "$RUNDIR"
    for i in 1 2 3 4; do
      git push -q origin "HEAD:$BRANCH" && { echo "pushed index and progress"; return; }
      git fetch -q origin "$BRANCH" && git merge -q --no-edit FETCH_HEAD; sleep $((i*5))
    done
    echo "WARNING: could not push; committed locally"
  fi
}
while true; do
  echo "[$(date -u +%FT%TZ)] checkpoint"
  one
  [ -f "$WORK/state/step2.done" ] && { echo "step2 done; final push finished"; exit 0; }
  pgrep -f 'run-verification.sh step2' >/dev/null || { echo "driver not running; stopping"; exit 0; }
  sleep $((EVERY*60))
done
