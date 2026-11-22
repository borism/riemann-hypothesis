#!/usr/bin/env bash
# Kill switch for the runner pool chain (issue #9): adds the file STOP to the pool/verdicts branch.
# Every wave checks it at the start (plan job) and before dispatching the next wave (chain job).
# A wave already running finishes and publishes normally; no new wave starts.
#   rh-pool-stop.sh "reason"      set the switch
#   rh-pool-stop.sh --clear       remove it (then dispatch a new chain by hand)
set -euo pipefail
cd "${RH_POOL_GIT:-/home/user/wt-gh}"
git fetch -q origin pool/verdicts
P=$(git rev-parse FETCH_HEAD)
if [ "${1:-}" = --clear ]; then
  git rev-parse -q --verify "$P:STOP" >/dev/null || { echo "no STOP file"; exit 0; }
  T=$(git ls-tree "$P" | grep -v $'\tSTOP$' | git mktree); MSG="pool: clear the kill switch"
else
  B=$(printf 'stop requested %s: %s\n' "$(date -u +%FT%TZ)" "${1:-no reason given}" | git hash-object -w --stdin)
  T=$( { git ls-tree "$P" | grep -v $'\tSTOP$'; printf '100644 blob %s\tSTOP\n' "$B"; } | git mktree); MSG="pool: kill switch (STOP)"
fi
C=$(git -c user.name=pool-operator -c user.email= commit-tree "$T" -p "$P" -m "$MSG")
git push -q origin "$C:refs/heads/pool/verdicts"
echo "pool/verdicts is now $C ($MSG)"
