#!/usr/bin/env bash
# Checks after a pool merge (issue #9). Read-only.
#   rh-pool-postcheck.sh STAMP MERGED_LIST BATCH_DIR...
# STAMP: a file touched right before the merge. Checks that
#  1. every file changed since STAMP (by ctime: creation or rename) is in MERGED_LIST, and vice versa,
#     i.e. the merge created exactly the listed files and rewrote nothing else;
#  2. every listed file still has the sha256 its batch manifest gives (and is in a manifest).
# Prints the merged module names to MERGED_LIST.modules (for the Lake --no-build check).
set -euo pipefail
STAMP="${1:?stamp}"; LIST="${2:?merged list}"; shift 2
WORK="${RH_WORK:-/home/user/rh-verify}"; DEST="$WORK/build/.lake/build"
die() { echo "rh-pool-postcheck: FAIL: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( cd "$DEST" && find . -type f -cnewer "$STAMP" | LC_ALL=C sort ) > "$T/changed"
LC_ALL=C sort -u "$LIST" > "$T/listed"
extra=$(LC_ALL=C comm -23 "$T/changed" "$T/listed" | wc -l); missing=$(LC_ALL=C comm -13 "$T/changed" "$T/listed" | wc -l)
echo "files changed since the stamp: $(wc -l < "$T/changed"); merged list: $(wc -l < "$T/listed"); changed but not merged: $extra; merged but not changed: $missing"
[ "$extra" = 0 ] || { LC_ALL=C comm -23 "$T/changed" "$T/listed" | head -5; die "files outside the merge list changed (the live build or something else wrote to the tree)"; }
[ "$missing" = 0 ] || die "listed files that were not created"
for d in "$@"; do cat "$d"/*-manifest.tsv; done | LC_ALL=C sort -t$'\t' -k1,1 -u > "$T/man"
LC_ALL=C join -t $'\t' "$T/listed" "$T/man" | awk -F'\t' '{print $3 "  " $1}' > "$T/sums"
[ "$(wc -l < "$T/sums")" = "$(wc -l < "$T/listed")" ] || die "some merged files are in no manifest"
[ ! -s "$T/sums" ] || ( cd "$DEST" && sha256sum -c --quiet "$T/sums" ) || die "a merged file differs from its manifest"
echo "sha256 of all $(wc -l < "$T/listed") merged files match their manifests"
grep -E '^\./lib/lean/.*\.olean$' "$T/listed" | sed 's|^\./lib/lean/||; s|\.olean$||; s|/|.|g' > "$LIST.modules"
echo "merged modules: $(wc -l < "$LIST.modules") (listed in $LIST.modules)"
echo "OK"
