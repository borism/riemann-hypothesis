#!/usr/bin/env bash
# Checkpoint the step 2 build outputs to a public Hugging Face dataset, so the run can continue on
# another machine if this container is lost (issue #1).
#
#   scripts/rh-checkpoint.sh push      upload the module outputs finished since the last push
#   scripts/rh-checkpoint.sh status    what has been uploaded so far
#   scripts/rh-checkpoint.sh pull      on a new machine: download, verify and unpack all shards
#
# What is stored: the files under $RH_WORK/build/.lake/build (.olean .ilean .trace .hash .c), in
# zstd-compressed tar shards, never *.setup.json. A manifest (path, size, sha256 of every file) goes
# next to each shard. Only the INDEX line (shard sha256 + manifest sha256) is committed to this git
# repository, in verification/checkpoints/step2/INDEX.tsv. Git is the trust anchor and the dataset is
# only storage: `pull` refuses any shard or manifest whose hash is not in the INDEX it was given.
#
# What this does NOT show: the shards are the output of the run that wrote them. Restoring them on
# another machine continues that run; it is not an independent rebuild. The later steps (export,
# three kernels, statement comparison) re-check every declaration regardless, and verification/NOTES.md
# explains why a tampered .olean should not be able to make a wrong proof pass, but an independent
# check of a restored tree means rebuilding the same modules on a second node and comparing hashes
# (issue #3). Builds must use the same absolute path: the .olean files record it.
#
# Setup: python3 -m venv /home/user/rh-tools-venv && /home/user/rh-tools-venv/bin/pip install huggingface_hub hf_xet
# The Hugging Face token comes from the environment (HF_TOKEN); on the cloud VM the network proxy injects
# the real one, so any placeholder works there.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RH_WORK:-/home/user/rh-verify}"
BUILD="$WORK/build"
HF_REPO="${RH_HF_REPO:-bmaryshev/riemann-hypothesis-build-checkpoints}"
PY="${RH_PY:-/home/user/rh-tools-venv/bin/python}"
INDEX="${RH_CKPT_INDEX:-$REPO/verification/checkpoints/step2/INDEX.tsv}"   # RH_CKPT_INDEX: keep it in another checkout
CK="$WORK/state/ckpt"                 # local bookkeeping
TMP="${RH_CKPT_TMP:-$WORK/../rh-ckpt-tmp}"   # staging for one shard on the root disk (not the loop image)
SETTLE_S="${RH_CKPT_SETTLE_S:-300}"   # ignore files younger than this (lake may still be writing them)
MIN_FILES="${RH_CKPT_MIN_FILES:-3000}"
export HF_TOKEN="${HF_TOKEN:-proxy-injected}" HF_HUB_DISABLE_TELEMETRY=1

die() { echo "rh-checkpoint: $*" >&2; exit 1; }
hf_py() { "$PY" - "$@"; }

cmd_status() {
  echo "dataset: https://huggingface.co/datasets/$HF_REPO"
  if [ -s "$INDEX" ]; then
    awk -F'\t' 'NR>1 {n++; f+=$3; b+=$4} END {printf "%d shards, %d files, %.1f GB raw\n", n, f, b/1e9}' "$INDEX"
    tail -n 3 "$INDEX"
  else echo "no shards uploaded yet"; fi
}

cmd_push() {
  [ -d "$BUILD/.lake/build" ] || die "no build tree at $BUILD/.lake/build"
  mkdir -p "$CK" "$TMP" "$(dirname "$INDEX")"
  local done_list="$CK/uploaded.list" seq now cand new
  touch "$done_list"
  seq=1; [ -s "$INDEX" ] && seq=$(( $(tail -n +2 "$INDEX" | wc -l) + 1 ))
  now="$(date -u +%Y%m%dT%H%M%SZ)"
  cand="$TMP/candidates.$now"; new="$TMP/new.$now"
  ( cd "$BUILD/.lake/build" && find . -type f ! -name '*.setup.json' -mmin +"$(( SETTLE_S / 60 ))" -print | LC_ALL=C sort ) > "$cand"
  LC_ALL=C comm -23 "$cand" <(LC_ALL=C sort "$done_list") > "$new"
  local n; n=$(wc -l < "$new")
  if [ "$n" -lt "$MIN_FILES" ]; then echo "only $n new files (< $MIN_FILES); not pushing yet"; rm -f "$cand" "$new"; return 0; fi

  local id; id="$(printf '%04d' "$seq")"
  local shard="$TMP/step2-shard-$id.tar.zst" man="$TMP/step2-manifest-$id.tsv"
  echo "shard $id: $n files"
  # manifest first (sha256 of each file), then the shard from the same list; nice so the build keeps its cores
  ( cd "$BUILD/.lake/build" && nice -n 19 xargs -d '\n' -a "$new" sha256sum | awk '{h=$1; $1=""; sub(/^ /,""); print $0 "\t" h}' ) > "$man.raw"
  ( cd "$BUILD/.lake/build" && while IFS= read -r p; do printf '%s\t%s\n' "$p" "$(stat -c %s "$p")"; done < "$new" ) | LC_ALL=C sort > "$man.sizes"
  LC_ALL=C join -t $'\t' <(LC_ALL=C sort "$man.sizes") <(LC_ALL=C sort "$man.raw") | LC_ALL=C sort > "$man"
  rm -f "$man.raw" "$man.sizes"
  tar -C "$BUILD/.lake/build" --null -T <(tr '\n' '\0' < "$new") -cf - | nice -n 19 zstd -3 -T1 -q -o "$shard"
  local ssha msha raw; ssha="$(sha256sum "$shard" | cut -d' ' -f1)"; msha="$(sha256sum "$man" | cut -d' ' -f1)"
  raw=$(awk -F'\t' '{b+=$2} END {print b}' "$man")
  echo "  $(du -h "$shard" | cut -f1) compressed from $(( raw / 1000000 )) MB"

  hf_py "$HF_REPO" "$shard" "$man" "step2/$(basename "$shard")" "step2/$(basename "$man")" <<'PYEOF'
import sys
from huggingface_hub import HfApi
repo, shard, man, rshard, rman = sys.argv[1:6]
api = HfApi()
api.create_repo(repo, repo_type="dataset", private=False, exist_ok=True)
api.upload_file(path_or_fileobj=man, path_in_repo=rman, repo_id=repo, repo_type="dataset", commit_message="manifest " + rman)
api.upload_file(path_or_fileobj=shard, path_in_repo=rshard, repo_id=repo, repo_type="dataset", commit_message="shard " + rshard)
print("uploaded", rshard)
PYEOF

  [ -s "$INDEX" ] || printf 'seq\tutc\tfiles\traw_bytes\tshard_sha256\tmanifest_sha256\tbuild_path\tdataset_path\n' > "$INDEX"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tstep2/step2-shard-%s.tar.zst\n' "$id" "$now" "$n" "$raw" "$ssha" "$msha" "$BUILD" "$id" >> "$INDEX"
  cat "$new" >> "$done_list"
  rm -f "$cand" "$new" "$shard" "$man"
  echo "shard $id uploaded; INDEX updated at $INDEX (commit and push it to the branch)"
}

cmd_pull() {
  # pull [INDEX_FILE]: INDEX_FILE defaults to the one in this checkout. Refuse anything that does not match it.
  local idx="${1:-$INDEX}"; [ -s "$idx" ] || die "no INDEX at $idx"
  mkdir -p "$TMP" "$BUILD/.lake/build"
  local want; want="$(awk -F'\t' 'NR==1 && $7!="" {next} {print $7; exit}' "$idx")"
  [ "$want" = "$BUILD" ] || echo "WARNING: shards were built at $want but BUILD is $BUILD; modules that record the path will not match" >&2
  tail -n +2 "$idx" | while IFS=$'\t' read -r id utc files raw ssha msha bpath dpath; do
    echo "shard $id ($files files)"
    hf_py "$HF_REPO" "step2/step2-shard-$id.tar.zst" "step2/step2-manifest-$id.tsv" "$TMP" <<'PYEOF'
import sys
from huggingface_hub import hf_hub_download
repo, rs, rm, out = sys.argv[1:5]
for f in (rm, rs):
    hf_hub_download(repo, f, repo_type="dataset", local_dir=out)
PYEOF
    local shard="$TMP/step2/step2-shard-$id.tar.zst" man="$TMP/step2/step2-manifest-$id.tsv"
    [ "$(sha256sum "$shard" | cut -d' ' -f1)" = "$ssha" ] || die "shard $id: sha256 differs from INDEX (refusing)"
    [ "$(sha256sum "$man" | cut -d' ' -f1)" = "$msha" ] || die "manifest $id: sha256 differs from INDEX (refusing)"
    zstd -dc "$shard" | tar -C "$BUILD/.lake/build" -xf -
    ( cd "$BUILD/.lake/build" && awk -F'\t' '{print $3 "  " $1}' "$man" | sha256sum -c --quiet - ) || die "shard $id: unpacked files differ from manifest"
    rm -rf "$TMP/step2"
  done
  echo "restored; re-run: scripts/run-verification.sh step2 (Lake rebuilds anything whose trace does not match)"
}

case "${1:-}" in
  push) cmd_push ;;
  status) cmd_status ;;
  pull) shift; cmd_pull "$@" ;;
  *) sed -n 2,6p "$0"; exit 2 ;;
esac
