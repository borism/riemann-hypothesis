#!/usr/bin/env bash
# Watcher for the step 2 run: waits, then exits with ONE line of output, so that whoever started it (an agent
# running it in the background) is woken by that exit. Exits when:
#   STEP2 DONE        the run finished ($RH_WORK/state/step2.done exists)
#   DRIVER GONE       the build driver is not running (stopped, crashed, or the machine restarted)
#   REBOOT DETECTED   the machine restarted while this watcher was running
#   LOW DISK          less than RH_WATCH_MIN_GB GB free on /
#   NEW WAVE STATS    (only if RH_POOL_REPO is set) a new stats/<wave>.json appeared on origin/pool/verdicts
#   HEARTBEAT         none of the above for RH_WATCH_SECS seconds (default 3000 = 50 minutes)
# The heartbeat keeps a long session alive and in cache: re-run the watcher after every exit.
#
# usage (an agent must run it in the BACKGROUND with a timeout above RH_WATCH_SECS, never with a trailing "&"):
#   scripts/rh-watch.sh
#   RH_WATCH_SECS=3000  RH_WATCH_MIN_GB=8  RH_WORK=/home/user/rh-verify
#   RH_POOL_REPO=/home/user/wt-gh      a checkout used only to `git fetch origin pool/verdicts` (optional)
set -u
WORK="${RH_WORK:-/home/user/rh-verify}"
SECS="${RH_WATCH_SECS:-3000}"
MINGB="${RH_WATCH_MIN_GB:-8}"
POOL="${RH_POOL_REPO:-}"
end=$(( $(date +%s) + SECS ))
up0=$(cut -d. -f1 /proc/uptime)
nstats() { git -C "$POOL" ls-tree --name-only -r origin/pool/verdicts 2>/dev/null | grep -c 'stats/'; }
[ -n "$POOL" ] && known=$(nstats)
while [ "$(date +%s)" -lt "$end" ]; do
  [ -f "$WORK/state/step2.done" ] && { echo "STEP2 DONE"; exit 0; }
  [ "$(cut -d. -f1 /proc/uptime)" -lt "$up0" ] && { echo "REBOOT DETECTED: run scripts/rh-recover.sh"; exit 0; }
  pgrep -f 'run-verification.sh step2' >/dev/null || { echo "DRIVER GONE (stopped, failed, or the machine restarted): run scripts/rh-recover.sh"; exit 0; }
  free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  [ "${free:-0}" -lt "$MINGB" ] && { echo "LOW DISK: ${free}G free"; exit 0; }
  if [ -n "$POOL" ]; then
    git -C "$POOL" fetch -q origin pool/verdicts 2>/dev/null
    n=$(nstats); [ "$n" -gt "$known" ] && { echo "NEW WAVE STATS ($n stats files on origin/pool/verdicts)"; exit 0; }
  fi
  sleep 60
done
echo "HEARTBEAT: build running, free disk $(df -BG --output=avail / | tail -1 | tr -dc 0-9)G"
