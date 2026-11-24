#!/usr/bin/env bash
# After a machine restart: bring the step 2 run back, in the right order. Safe to run at any time (idempotent):
# each part is skipped when it is already in place.
#   1. mount the compressed btrfs loop image on $RH_WORK (scripts/rh-optimise.sh storage-mount; it formats
#      only when the image file is missing, so the existing build tree is kept)
#   2. zram swap (scripts/rh-optimise.sh zram)
#   3. the step 2 build   (scripts/run-verification.sh step2; resumes from the oleans already in the tree)
#   4. the checkpoint loop (scripts/rh-checkpoint-loop.sh)
# The order matters: do not start the build before the image is mounted, or it would start from nothing on the
# root disk.
#
# usage: scripts/rh-recover.sh            (settings by environment variable, defaults below)
#   RH_WORK=/home/user/rh-verify   work directory (the image is $RH_WORK.btrfs.img)
#   RH_LEAN_THREADS=2              threads for Lean in the sandbox; 2 on a 15 GB machine (4 jobs thrash it)
#   RH_CPUS=2                      CPUs given to the build
#   RH_ZRAM=8G  RH_IMG_LEVEL=9  RH_IMG_SIZE=400G
#   RH_LOGS=/home/user/rh-logs     where the driver and loop logs are appended
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RH_WORK="${RH_WORK:-/home/user/rh-verify}"
LOGS="${RH_LOGS:-/home/user/rh-logs}"
mkdir -p "$LOGS"
cd "$REPO" || exit 1
say() { echo "[$(date -u +%FT%TZ)] rh-recover: $*"; }

if mountpoint -q "$RH_WORK"; then say "image already mounted at $RH_WORK"
else bash scripts/rh-optimise.sh storage-mount "${RH_IMG_LEVEL:-9}" "${RH_IMG_SIZE:-400G}" || { say "mount failed; not starting anything"; exit 1; }
fi
mountpoint -q "$RH_WORK" || { say "$RH_WORK is not a mount point; not starting anything (the build would use the root disk)"; exit 1; }

if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then say "zram swap already on"
else bash scripts/rh-optimise.sh zram "${RH_ZRAM:-8G}" lz4 || say "zram not available (continuing without it)"
fi

if pgrep -f 'run-verification.sh step2' >/dev/null; then say "build already running"
else
  RH_LEAN_THREADS="${RH_LEAN_THREADS:-2}" RH_OPTIMISE=1 RH_CPUS="${RH_CPUS:-2}" \
    setsid nohup bash scripts/run-verification.sh step2 >> "$LOGS/step2-driver.log" 2>&1 < /dev/null &
  say "build started"
fi
sleep 1
if pgrep -f '^bash scripts/rh-checkpoint-loop.sh' >/dev/null; then say "checkpoint loop already running"
else
  setsid nohup bash scripts/rh-checkpoint-loop.sh >> "$LOGS/ckpt-loop.log" 2>&1 < /dev/null &
  say "checkpoint loop started"
fi
sleep 5
pgrep -fa 'run-verification.sh step2|^bash scripts/rh-checkpoint-loop.sh' || say "WARNING: nothing is running"
