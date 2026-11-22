#!/usr/bin/env bash
# Merge accepted runner-built module outputs (issue #9 pool) into the live step 2 tree.
# PROPOSAL / EXPERIMENT: run by hand, only while `lake build Main` is stopped (at a planned restart).
# Dry-run by default: it checks everything and prints what it would do, and writes nothing.
#
#   rh-pool-merge.sh WAVE_INDEX.tsv BATCH_DIR            dry run
#   rh-pool-merge.sh WAVE_INDEX.tsv BATCH_DIR --apply    really extract into $RH_WORK/build/.lake/build
#
# WAVE_INDEX.tsv is the spot-check job's verdict.tsv, committed to git (git is the trust anchor):
#   wave job files tar_sha256 manifest_sha256 spot_modules spot_same_files verdict
# BATCH_DIR holds <wave>-job-<j>.tar.zst and <wave>-job-<j>-manifest.tsv as downloaded from the artifacts.
# A batch is merged only if: verdict is "accepted"; tar and manifest sha256 equal the committed index;
# every manifest path is a relative regular file under lib/lean/ or ir/ with one of the 7 output
# extensions; the tar holds exactly the manifest's files and nothing else (no links, no ..); every
# unpacked file matches its manifest sha256; and no file already in the live tree differs (an existing
# identical file is skipped, a different one aborts the whole batch).
set -euo pipefail
IDX="$(realpath "${1:?wave index}")"; DIR="$(realpath "${2:?batch dir}")"; APPLY=0; [ "${3:-}" = --apply ] && APPLY=1
WORK="${RH_WORK:-/home/user/rh-verify}"; DEST="$WORK/build/.lake/build"
die() { echo "rh-pool-merge: $*" >&2; exit 1; }
[ -d "$DEST" ] || die "no live tree at $DEST"
if [ "$APPLY" = 1 ] && pgrep -f 'lake build Main' >/dev/null; then die "lake build Main is running; stop it first (merging under a running build is not allowed)"; fi
SCR="$(mktemp -d "${TMPDIR:-/tmp}/rh-pool-merge.XXXXXX")"; trap 'rm -rf "$SCR"' EXIT
total=0; merged=0; skipped=0
while IFS=$'\t' read -r wave job files tsha msha spotm spots verdict; do
  [ "$wave" = wave ] && continue
  name="$wave-job-$job"; tar="$DIR/$name.tar.zst"; man="$DIR/$name-manifest.tsv"
  echo "batch $name: verdict=$verdict files=$files spot=$spotm modules ($spots files same)"
  [ "$verdict" = accepted ] || { echo "  SKIP: not accepted"; continue; }
  [ -f "$tar" ] && [ -f "$man" ] || die "$name: tar or manifest missing in $DIR"
  [ "$(sha256sum "$tar" | cut -d' ' -f1)" = "$tsha" ] || die "$name: tar sha256 differs from the index (refusing)"
  [ "$(sha256sum "$man" | cut -d' ' -f1)" = "$msha" ] || die "$name: manifest sha256 differs from the index (refusing)"
  [ "$(wc -l < "$man")" = "$files" ] || die "$name: manifest has $(wc -l < "$man") lines, index says $files"
  awk -F'\t' 'NF!=3 || $1 !~ /^\.\/(lib\/lean|ir)\/[A-Za-z0-9_.\/]+\.(olean|olean\.hash|ilean|ilean\.hash|trace|c|c\.hash)$/ || $1 ~ /\.\./ || $3 !~ /^[0-9a-f]{64}$/ {print "bad line: " $0; bad=1} END {exit bad}' "$man" || die "$name: manifest has unexpected entries"
  # the tar must list exactly the manifest's paths, all regular files
  zstd -dc "$tar" | tar -tvf - | awk '$1 !~ /^-/ {print "non-regular: " $0; bad=1} END {exit bad}' || die "$name: tar has non-regular entries"
  diff <(zstd -dc "$tar" | tar -tf - | sed 's|^\./||; s|^|./|' | LC_ALL=C sort) <(cut -f1 "$man" | LC_ALL=C sort) >/dev/null || die "$name: tar contents differ from manifest"
  u="$SCR/$name"; mkdir -p "$u"; zstd -dc "$tar" | tar -C "$u" --no-same-owner -xf -
  ( cd "$u" && awk -F'\t' '{print $3 "  " $1}' "$man" | sha256sum -c --quiet - ) || die "$name: unpacked files differ from manifest"
  n_new=0; n_same=0
  while IFS=$'\t' read -r p size h; do
    if [ -e "$DEST/$p" ]; then
      [ "$(sha256sum "$DEST/$p" | cut -d' ' -f1)" = "$h" ] || die "$name: $p exists in the live tree with different content (refusing the batch)"
      n_same=$((n_same+1))
    else n_new=$((n_new+1)); fi
  done < "$man"
  total=$((total+files)); skipped=$((skipped+n_same))
  echo "  verified: $files files, $n_new new, $n_same already present and identical"
  if [ "$APPLY" = 1 ]; then
    while IFS=$'\t' read -r p size h; do
      [ -e "$DEST/$p" ] && continue
      mkdir -p "$(dirname "$DEST/$p")"; cp -p "$u/$p" "$DEST/$p.rh-merge" && mv "$DEST/$p.rh-merge" "$DEST/$p"
    done < "$man"
    ( cd "$DEST" && awk -F'\t' '{print $3 "  " $1}' "$man" | sha256sum -c --quiet - ) || die "$name: live tree check after merge failed"
    merged=$((merged+n_new)); echo "  merged $n_new files"
  else
    echo "  DRY RUN: would copy $n_new files into $DEST"
  fi
  rm -rf "$u"
done < "$IDX"
echo "total: $total files in accepted batches, $skipped already present; $([ "$APPLY" = 1 ] && echo "merged $merged" || echo "dry run, nothing written")"
[ "$APPLY" = 1 ] && echo "next: restart step 2 (scripts/run-verification.sh step2); Lake re-checks every trace and rebuilds anything that does not match"
