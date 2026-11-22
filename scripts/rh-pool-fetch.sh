#!/usr/bin/env bash
# Fetch the accepted batches of pool waves to a local directory, for rh-pool-merge.sh (issue #9).
# Read-only network use: git fetch of the pool/verdicts branch, then plain HTTPS downloads of public
# prerelease assets (github.com -> release-assets.githubusercontent.com). Writes only into OUT_DIR.
#
#   rh-pool-fetch.sh OUT_DIR WAVE...     e.g. rh-pool-fetch.sh /home/user/pool-scratch/in pilot2
# For each wave: OUT_DIR/<wave>/verdict.tsv (from git, the trust anchor) and the tar + manifest of every
# accepted job, each checked against that verdict (the merge script checks them again).
set -euo pipefail
OUT="${1:?out dir}"; shift
REPO_URL="${RH_POOL_REPO:-https://github.com/borism/riemann-hypothesis}"
GITDIR="${RH_POOL_GIT:-/home/user/wt-gh}"
die() { echo "rh-pool-fetch: $*" >&2; exit 1; }
git -C "$GITDIR" fetch -q origin pool/verdicts
REF="$(git -C "$GITDIR" rev-parse FETCH_HEAD)"
echo "pool/verdicts at $REF"
for w in "$@"; do
  d="$OUT/$w"; mkdir -p "$d"
  git -C "$GITDIR" show "$REF:verdicts/$w.tsv" > "$d/verdict.tsv" || die "no verdict for wave $w in git"
  while IFS=$'\t' read -r wave job files tsha msha sm ss v; do
    [ "$wave" = wave ] && continue
    [ "$v" = accepted ] || { echo "$w job $job: $v, skipped"; continue; }
    for f in "$wave-job-$job.tar.zst:$tsha" "$wave-job-$job-manifest.tsv:$msha"; do
      n="${f%%:*}"; want="${f##*:}"
      curl -fsSL --retry 4 -o "$d/$n" "$REPO_URL/releases/download/pool-$w/$n" || die "download failed: $n"
      [ "$(sha256sum "$d/$n" | cut -d' ' -f1)" = "$want" ] || die "$n: sha256 differs from the verdict in git (refusing)"
    done
    echo "$w job $job: tar + manifest fetched, sha256 matches git ($files files)"
  done < "$d/verdict.tsv"
done
