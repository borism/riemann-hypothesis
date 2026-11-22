#!/usr/bin/env bash
# Experiment for issue #9, run on a GitHub-hosted runner only (never on the VM that runs the live build).
# Restores step 2 checkpoint shards from the public Hugging Face dataset at the live run's absolute path,
# checks whether Lake accepts them as up to date, then rebuilds a small sample of shallow leaf modules and
# compares the new bytes with the VM's manifest hashes. Needs no secrets.
#
#   exp-gh-restore-test.sh setup     toolchain (pinned sha256) + Mathlib from the official cache
#   exp-gh-restore-test.sh restore   download shards, verify against INDEX + manifests, unpack
#   exp-gh-restore-test.sh uptodate  lake build --no-build / lake build over all restored modules
#   exp-gh-restore-test.sh determinism   delete outputs of N shallow leaves, rebuild, compare hashes
set -euo pipefail

WORK=/home/user/rh-verify
BUILD="$WORK/build"
TC="$WORK/toolchains/v4.33.1"
OUT="${EXP_OUT:-$GITHUB_WORKSPACE/exp-out}"
HF="https://huggingface.co/datasets/bmaryshev/riemann-hypothesis-build-checkpoints/resolve/main"
SHARDS="${EXP_SHARDS:-0001 0002}"
SAMPLE_N="${EXP_SAMPLE_N:-200}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT"
export PATH="$TC/bin:$PATH" LEAN_ABORT_ON_PANIC=1 LAKE_ARTIFACT_CACHE=false MATHLIB_CACHE_GET_URL=https://cache.mathlib.org/mathlib4
say() { echo "== $(date -u +%H:%M:%S) $*" | tee -a "$OUT/summary.txt"; }

# Same shape as sandbox_cmd in scripts/run-verification.sh: no network, empty env, HOME in a tmpfs.
# Falls back to env -i when bubblewrap cannot create namespaces here; the summary says which was used.
sbx() {
  if [ "${SBX_MODE:-}" = bwrap ]; then
    bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv \
      --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
      --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp --ro-bind "$TC" "$TC" --bind "$BUILD" "$BUILD" \
      --setenv HOME /tmp/home --setenv PATH "$TC/bin:/usr/bin:/bin" \
      --setenv LEAN_ABORT_ON_PANIC 1 --setenv LAKE_ARTIFACT_CACHE false --setenv LANG C.UTF-8 \
      --chdir "$BUILD" bash -c 'mkdir -p "$HOME"; exec "$@"' _ "$@"
  else
    mkdir -p /tmp/exp-home; ( cd "$BUILD" && env -i HOME=/tmp/exp-home PATH="$TC/bin:/usr/bin:/bin" LEAN_ABORT_ON_PANIC=1 LAKE_ARTIFACT_CACHE=false LANG=C.UTF-8 "$@" )
  fi
}
pick_sbx() {
  if bwrap --unshare-all --die-with-parent --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --proc /proc --dev /dev true 2>/dev/null; then
    echo bwrap; else echo env; fi
}

cmd_setup() {
  sudo mkdir -p "$WORK" && sudo chown "$(id -u):$(id -g)" "$WORK"
  mkdir -p "$WORK/dl" "$TC"
  local t="$WORK/dl/lean-4.33.1-linux.tar.zst"
  curl -fsSL --retry 4 -o "$t" https://github.com/leanprover/lean4/releases/download/v4.33.1/lean-4.33.1-linux.tar.zst
  local want; want="$(awk '$2=="lean-4.33.1-linux.tar.zst" {print $1}' "$HERE/toolchain-sha256.txt")"
  local got; got="$(sha256sum "$t" | cut -d' ' -f1)"
  [ -n "$want" ] && [ "$got" = "$want" ] || { say "toolchain sha256 MISMATCH: got $got want $want"; exit 1; }
  say "toolchain sha256 OK $got"
  tar --zstd -xf "$t" -C "$TC" --strip-components=1; rm -f "$t"
  lean --version | tee -a "$OUT/summary.txt"
  [ -d "$BUILD/src" ] || { say "build clone missing at $BUILD"; exit 1; }
  say "build clone commit $(git -C "$BUILD" rev-parse HEAD)"
  local t0=$SECONDS
  ( cd "$BUILD" && lake exe mathlib/cache get ) > "$OUT/cache-get.log" 2>&1 || { tail -20 "$OUT/cache-get.log"; say "mathlib/cache get FAILED"; exit 1; }
  tail -3 "$OUT/cache-get.log" | tee -a "$OUT/summary.txt"
  say "mathlib cache get done in $((SECONDS-t0)) s; disk: $(df -BG --output=avail / | tail -1) free on /"
}

cmd_restore() {
  local idx="$OUT/INDEX.tsv"; [ -s "$idx" ] || { say "no INDEX at $idx"; exit 1; }
  mkdir -p "$BUILD/.lake/build" "$WORK/dl"
  : > "$OUT/restored-manifest.tsv"
  for id in $SHARDS; do
    local line ssha msha bpath
    line="$(awk -F'\t' -v id="$id" '$1==id' "$idx")"; [ -n "$line" ] || { say "shard $id not in INDEX"; exit 1; }
    ssha="$(cut -f5 <<<"$line")"; msha="$(cut -f6 <<<"$line")"; bpath="$(cut -f7 <<<"$line")"
    [ "$bpath" = "$BUILD" ] || { say "shard $id built at $bpath, not $BUILD"; exit 1; }
    local s="$WORK/dl/step2-shard-$id.tar.zst" m="$WORK/dl/step2-manifest-$id.tsv" t0=$SECONDS
    curl -fsSL --retry 4 -o "$m" "$HF/step2/step2-manifest-$id.tsv"
    curl -fsSL --retry 4 -o "$s" "$HF/step2/step2-shard-$id.tar.zst"
    [ "$(sha256sum "$s" | cut -d' ' -f1)" = "$ssha" ] || { say "shard $id sha256 differs from INDEX (refusing)"; exit 1; }
    [ "$(sha256sum "$m" | cut -d' ' -f1)" = "$msha" ] || { say "manifest $id sha256 differs from INDEX (refusing)"; exit 1; }
    say "shard $id: $(du -h "$s" | cut -f1) downloaded in $((SECONDS-t0)) s, shard+manifest sha256 match INDEX"
    zstd -dc "$s" | tar -C "$BUILD/.lake/build" -xf -
    ( cd "$BUILD/.lake/build" && awk -F'\t' '{print $3 "  " $1}' "$m" | sha256sum -c --quiet - ) || { say "shard $id: unpacked files differ from manifest"; exit 1; }
    say "shard $id: $(wc -l < "$m") files unpacked, all match manifest"
    cat "$m" >> "$OUT/restored-manifest.tsv"; rm -f "$s"
  done
  say "restored $(grep -c '\.olean	' "$OUT/restored-manifest.tsv") modules; disk: $(df -BG --output=avail / | tail -1) free on /"
  sleep 2; touch "$OUT/restore.stamp"
  grep '\.olean	' "$OUT/restored-manifest.tsv" | cut -f1 | sed 's|^\./lib/lean/||; s|\.olean$||; s|/|.|g' | LC_ALL=C sort > "$OUT/restored-modules.txt"
}

lake_counts() {  # lake_counts LOG : count Lake's per-job result lines
  local f="$1"
  printf 'Built=%s Replayed=%s Fetched=%s errors=%s lines=%s\n' \
    "$(grep -c ' Built ' "$f" || true)" "$(grep -c ' Replayed ' "$f" || true)" "$(grep -c ' Fetched ' "$f" || true)" \
    "$(grep -cE '^(✖|error)' "$f" || true)" "$(wc -l < "$f")"
}

cmd_uptodate() {
  SBX_MODE="$(pick_sbx)"; export SBX_MODE; say "sandbox for lake: $SBX_MODE"
  sbx lake build --help > "$OUT/lake-build-help.txt" 2>&1 || true
  local -a tg; mapfile -t tg < <(sed 's/^/+/' "$OUT/restored-modules.txt")
  local t0=$SECONDS rc=0
  sbx lake build --no-build "${tg[@]}" > "$OUT/nobuild.log" 2>&1 || rc=$?
  say "lake build --no-build over ${#tg[@]} restored modules: rc=$rc in $((SECONDS-t0)) s; $(lake_counts "$OUT/nobuild.log")"
  tail -15 "$OUT/nobuild.log" | tee -a "$OUT/summary.txt"
  t0=$SECONDS; rc=0
  timeout 20m /usr/bin/time -v -o "$OUT/build-all.time" bash -c "$(declare -f sbx); SBX_MODE=$SBX_MODE BUILD=$BUILD TC=$TC sbx lake build -v \"\$@\"" _ "${tg[@]}" > "$OUT/build-all.log" 2>&1 || rc=$?
  say "lake build -v over the same modules: rc=$rc in $((SECONDS-t0)) s; $(lake_counts "$OUT/build-all.log"); peak RSS $(awk -F': ' '/Maximum resident/ {print $2}' "$OUT/build-all.time" 2>/dev/null) kB"
  grep ' Built ' "$OUT/build-all.log" | head -20 | tee -a "$OUT/summary.txt" || true
  tail -8 "$OUT/build-all.log" | tee -a "$OUT/summary.txt"
  # did Lake touch any restored file?
  ( cd "$BUILD/.lake/build" && awk -F'\t' '{print $3 "  " $1}' "$OUT/restored-manifest.tsv" | sha256sum -c --quiet - 2>/dev/null ) > "$OUT/after-build-diff.txt" 2>&1 || true
  say "restored files changed or missing after lake build: $(grep -c ': FAILED' "$OUT/after-build-diff.txt" || true)"
  say "output files written after the restore (find -newer): olean=$(find "$BUILD/.lake/build" -name '*.olean' -newer "$OUT/restore.stamp" | wc -l) total=$(find "$BUILD/.lake/build" -type f -newer "$OUT/restore.stamp" | wc -l)"
  find "$BUILD/.lake/build" -type f -newer "$OUT/restore.stamp" | head -20 | tee -a "$OUT/summary.txt"
}

cmd_determinism() {
  SBX_MODE="$(pick_sbx)"; export SBX_MODE; say "sandbox for lake: $SBX_MODE"
  # shallow leaves of the restored set whose project imports are all restored
  python3 -I "$HERE/exp-pick-sample.py" "$BUILD/src" "$OUT/restored-modules.txt" "$SAMPLE_N" > "$OUT/sample.txt" 2> "$OUT/sample-stats.txt"
  cat "$OUT/sample-stats.txt" | tee -a "$OUT/summary.txt"
  local n; n=$(wc -l < "$OUT/sample.txt"); [ "$n" -gt 0 ] || { say "empty sample"; exit 1; }
  : > "$OUT/sample-files.txt"
  while read -r mod; do
    local p="${mod//.//}"
    for f in "lib/lean/$p.olean" "lib/lean/$p.olean.hash" "lib/lean/$p.ilean" "lib/lean/$p.ilean.hash" "lib/lean/$p.trace" "ir/$p.c" "ir/$p.c.hash"; do
      echo "./$f" >> "$OUT/sample-files.txt"; rm -f "$BUILD/.lake/build/$f"
    done
  done < "$OUT/sample.txt"
  say "deleted outputs of $n sample modules ($(wc -l < "$OUT/sample-files.txt") files)"
  local -a tg; mapfile -t tg < <(sed 's/^/+/' "$OUT/sample.txt")
  local t0=$SECONDS rc=0
  timeout 45m /usr/bin/time -v -o "$OUT/sample-build.time" bash -c "$(declare -f sbx); SBX_MODE=$SBX_MODE BUILD=$BUILD TC=$TC sbx lake build -v \"\$@\"" _ "${tg[@]}" > "$OUT/sample-build.log" 2>&1 || rc=$?
  say "rebuild of sample: rc=$rc in $((SECONDS-t0)) s; $(lake_counts "$OUT/sample-build.log"); peak RSS $(awk -F': ' '/Maximum resident/ {print $2}' "$OUT/sample-build.time" 2>/dev/null) kB"
  tail -5 "$OUT/sample-build.log" | tee -a "$OUT/summary.txt"
  # compare with the VM's manifest hashes
  LC_ALL=C sort "$OUT/sample-files.txt" > "$OUT/sf.sorted"
  LC_ALL=C sort -t $'\t' -k1,1 "$OUT/restored-manifest.tsv" | LC_ALL=C join -t $'\t' "$OUT/sf.sorted" - > "$OUT/sample-manifest.tsv"
  : > "$OUT/sample-compare.tsv"
  while IFS=$'\t' read -r path size want; do
    local f="$BUILD/.lake/build/${path#./}" got=MISSING
    [ -f "$f" ] && got="$(sha256sum "$f" | cut -d' ' -f1)"
    printf '%s\t%s\t%s\t%s\n' "$path" "$want" "$got" "$([ "$got" = "$want" ] && echo same || echo DIFF)" >> "$OUT/sample-compare.tsv"
  done < "$OUT/sample-manifest.tsv"
  say "byte comparison with the VM build, per file type (same / differ / missing):"
  awk -F'\t' '{n=$1; sub(/.*\//,"",n); e=n; sub(/^[^.]*/,"",e); t[e]++; if($4=="same") s[e]++; else if($3=="MISSING") m[e]++; else d[e]++}
    END {for (k in t) printf "  %-12s %d / %d / %d  (of %d)\n", k, s[k], d[k], m[k], t[k]}' "$OUT/sample-compare.tsv" | sort | tee -a "$OUT/summary.txt"
  grep -P '\tDIFF$' "$OUT/sample-compare.tsv" | head -20 | tee -a "$OUT/summary.txt" || true
}

case "${1:-}" in
  setup) cmd_setup ;; restore) cmd_restore ;; uptodate) cmd_uptodate ;; determinism) cmd_determinism ;;
  *) sed -n 2,11p "$0"; exit 2 ;;
esac
