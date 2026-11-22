#!/usr/bin/env bash
# Every RH_CKPT_EVERY_MIN minutes: upload new build outputs (scripts/rh-checkpoint.sh push), then commit
# and push the INDEX line to the branch. Stops when step2.done exists (after one last push).
# Run detached:  setsid nohup scripts/rh-checkpoint-loop.sh > /home/user/rh-logs/ckpt-loop.log 2>&1 < /dev/null &
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RH_WORK:-/home/user/rh-verify}"
EVERY="${RH_CKPT_EVERY_MIN:-120}"
BRANCH="${RH_CKPT_BRANCH:-ccr-bdb3a003-2b6l4u}"
IDX=verification/checkpoints/step2/INDEX.tsv
one() {
  bash "$REPO/scripts/rh-checkpoint.sh" push 2>&1 | grep -v -E 'it/s|MB/s|%\|' | tail -5
  cd "$REPO" || return
  if ! git diff --quiet -- "$IDX" 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard -- "$IDX")" ]; then
    git add "$IDX" && git commit -q -m "Checkpoint index: step 2 build shards on Hugging Face ($(tail -n1 "$IDX" | cut -f1,3))" -- "$IDX"
    for i in 1 2 3 4; do
      git push -q origin "HEAD:$BRANCH" && { echo "index pushed"; return; }
      git fetch -q origin "$BRANCH" && git merge -q --no-edit FETCH_HEAD; sleep $((i*5))
    done
    echo "WARNING: could not push the index; it is committed locally"
  fi
}
while true; do
  echo "[$(date -u +%FT%TZ)] checkpoint"
  one
  [ -f "$WORK/state/step2.done" ] && { echo "step2 done; final push finished"; exit 0; }
  pgrep -f 'run-verification.sh step2' >/dev/null || { echo "driver not running; stopping"; exit 0; }
  sleep $((EVERY*60))
done
