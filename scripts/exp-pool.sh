#!/usr/bin/env bash
# Experiment for issue #9: pool of GitHub-hosted runners building slices of step 2 (runner side only).
# Uses exp-gh-restore-test.sh for toolchain/Mathlib setup and verified shard restore. No secrets.
#
#   exp-pool.sh sampler            start a background RAM/swap/lean-RSS sampler (5 s)
#   exp-pool.sh dag                static import DAG of $BUILD/src -> $OUT/dag.tsv
#   exp-pool.sh build LIST TAG     lake build +M for every module in LIST (bwrap, no network), log per module
#   exp-pool.sh pack LIST NAME     manifest + tar.zst of the 7 output files of every module in LIST
#   exp-pool.sh compare LIST MANIFEST...   sha256 of the 7 files of LIST vs the given manifests
#   exp-pool.sh redo LIST          delete outputs of LIST (they must be restored), rebuild, compare with VM
#   exp-pool.sh importall          one `lean` process importing Mathlib + every restored module (RAM probe)
#   exp-pool.sh resources          summarise the sampler
set -euo pipefail
WORK=/home/user/rh-verify; BUILD="$WORK/build"; TC="$WORK/toolchains/v4.33.1"
OUT="${EXP_OUT:?}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$TC/bin:$PATH"
say() { echo "== $(date -u +%H:%M:%S) $*" | tee -a "$OUT/summary.txt"; }
EXTS=(olean olean.hash ilean ilean.hash trace c c.hash)
files_of() {  # module -> its 7 output paths relative to .lake/build, with ./ prefix like the manifests
  local p="${1//.//}"
  printf './lib/lean/%s.%s\n' "$p" olean "$p" olean.hash "$p" ilean "$p" ilean.hash "$p" trace
  printf './ir/%s.%s\n' "$p" c "$p" c.hash
}
sbx_lake() {  # same shape as sandbox_cmd in scripts/run-verification.sh
  bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp --ro-bind "$TC" "$TC" --bind "$BUILD" "$BUILD" \
    --setenv HOME /tmp/home --setenv PATH "$TC/bin:/usr/bin:/bin" \
    --setenv LEAN_ABORT_ON_PANIC 1 --setenv LAKE_ARTIFACT_CACHE false --setenv LANG C.UTF-8 \
    --chdir "$BUILD" bash -c 'mkdir -p "$HOME"; exec lake "$@"' _ "$@"
}

cmd_sampler() {
  nohup bash -c '
    while sleep 5; do
      used=$(free -m | awk "/Mem/ {print \$3}"); sw=$(free -m | awk "/Swap/ {print \$3}")
      top=$(ps -C lean -o rss=,args= --sort=-rss 2>/dev/null | head -1)
      n=$(ps -C lean -o pid= 2>/dev/null | wc -l)
      sum=$(ps -C lean -o rss= 2>/dev/null | awk "{s+=\$1} END {print s+0}")
      mod=$(sed -n "s|.* /home/user/rh-verify/build/src/\([^ ]*\)\.lean .*|\1|p" <<<"$top" | tr / .)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(date -u +%H:%M:%S)" "$used" "$sw" "$n" "$(awk "{print \$1+0}" <<<"$top")" "$sum" "${mod:--}"
    done' > "$OUT/sampler.tsv" 2>/dev/null &
  echo "sampler started (time, used MB, swap MB, lean procs, max lean RSS kB, sum lean RSS kB, module of max)"
}

cmd_resources() {
  local r="$OUT/sampler.tsv"; [ -s "$r" ] || { echo "no samples"; return 0; }
  say "resources: peak used RAM $(cut -f2 "$r" | sort -n | tail -1) MB, peak swap used $(cut -f3 "$r" | sort -n | tail -1) MB, peak single lean RSS $(( $(cut -f5 "$r" | sort -n | tail -1) / 1024 )) MB ($(sort -t$'\t' -k5,5n "$r" | tail -1 | cut -f7)), peak sum lean RSS $(( $(cut -f6 "$r" | sort -n | tail -1) / 1024 )) MB, min MemAvailable n/a; disk free now $(df -BG --output=avail / | tail -1)"
}

cmd_dag() { python3 -I "$HERE/exp-dag.py" "$BUILD/src" "$OUT/dag.tsv" 2>&1 | tee -a "$OUT/summary.txt"; }

cmd_build() {  # build LIST TAG
  local list="$1" tag="$2" rc=0 t0=$SECONDS
  local -a tg; mapfile -t tg < <(sed 's/^/+/' "$list")
  timeout "${EXP_BUILD_TIMEOUT:-75m}" bash -c "$(declare -f sbx_lake); BUILD=$BUILD TC=$TC sbx_lake build -v \"\$@\"" _ "${tg[@]}" > "$OUT/build-$tag.log" 2>&1 || rc=$?
  local built; built=$(grep -cE '\] Built ' "$OUT/build-$tag.log" || true)
  say "build $tag: ${#tg[@]} targets, rc=$rc, $((SECONDS-t0)) s wall, $built modules Built; $(tail -1 "$OUT/build-$tag.log")"
  # per-module times, from Lake's "Built X (12s)" lines
  grep -oE '\] Built [^ ]+ \([0-9.]+m?s\)' "$OUT/build-$tag.log" | sed -E 's/\] Built ([^ ]+) \(([0-9.]+)(m?s)\)/\1\t\2\3/' > "$OUT/times-$tag.tsv" || true
  awk -F'\t' '{v=$2; if (v ~ /ms$/) {sub(/ms/,"",v); v/=1000} else sub(/s/,"",v); v+=0; s+=v; if (v>m) {m=v; mm=$1}} END {if (NR) printf "  per-module elaboration: n=%d, total %.0f s, mean %.1f s, max %.0f s (%s)\n", NR, s, s/NR, m, mm}' "$OUT/times-$tag.tsv" | tee -a "$OUT/summary.txt"
  return $rc
}

cmd_pack() {  # pack LIST NAME : manifest (path, size, sha256 like rh-checkpoint.sh) + tar.zst
  local list="$1" name="$2" d="$OUT/pack"; mkdir -p "$d"
  while read -r m; do files_of "$m"; done < "$list" | LC_ALL=C sort > "$d/$name.files"
  ( cd "$BUILD/.lake/build" && while IFS= read -r p; do [ -f "$p" ] || { echo "MISSING $p" >&2; exit 1; }; printf '%s\t%s\t%s\n' "$p" "$(stat -c %s "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"; done < "$d/$name.files" ) > "$d/$name-manifest.tsv"
  tar -C "$BUILD/.lake/build" --null -T <(tr '\n' '\0' < "$d/$name.files") -cf - | zstd -3 -T0 -q -o "$d/$name.tar.zst"
  rm -f "$d/$name.files"
  printf '%s\t%s\t%s\t%s\n' "$name" "$(wc -l < "$d/$name-manifest.tsv")" "$(sha256sum "$d/$name.tar.zst" | cut -d' ' -f1)" "$(sha256sum "$d/$name-manifest.tsv" | cut -d' ' -f1)" | tee "$d/$name.hashes"
  say "pack $name: $(wc -l < "$d/$name-manifest.tsv") files, $(du -h "$d/$name.tar.zst" | cut -f1) compressed"
}

cmd_compare() {  # compare LIST MANIFEST... : rebuilt files of LIST vs the given manifests (first match wins)
  local list="$1"; shift
  local ref="$OUT/compare-ref.tsv"; cat "$@" | LC_ALL=C sort -t$'\t' -k1,1 -u > "$ref"
  : > "$OUT/compare.tsv"
  while read -r m; do
    files_of "$m" | while read -r p; do
      local want got=MISSING
      want="$(awk -F'\t' -v p="$p" '$1==p {print $3; exit}' "$ref")"
      [ -f "$BUILD/.lake/build/$p" ] && got="$(sha256sum "$BUILD/.lake/build/$p" | cut -d' ' -f1)"
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$p" "${want:-NOREF}" "$got" "$([ -n "$want" ] && [ "$got" = "$want" ] && echo same || echo DIFF)"
    done
  done < "$list" >> "$OUT/compare.tsv"
  say "compare: $(grep -c $'\tsame$' "$OUT/compare.tsv" || true) same, $(grep -c $'\tDIFF$' "$OUT/compare.tsv" || true) differ, of $(wc -l < "$OUT/compare.tsv") files"
  awk -F'\t' '{n=$2; sub(/.*\//,"",n); e=n; sub(/^[^.]*/,"",e); t[e]++; if($5=="same") s[e]++} END {for (k in t) printf "  %-12s %d / %d same\n", k, s[k], t[k]}' "$OUT/compare.tsv" | sort | tee -a "$OUT/summary.txt"
  grep $'\tDIFF$' "$OUT/compare.tsv" | head -10 | tee -a "$OUT/summary.txt" || true
  ! grep -q $'\tDIFF$' "$OUT/compare.tsv"
}

cmd_redo() {  # redo LIST : delete outputs of restored modules, rebuild, compare with the VM's manifests
  local list="$1"
  while read -r m; do files_of "$m" | while read -r p; do rm -f "$BUILD/.lake/build/$p"; done; done < "$list"
  say "redo: deleted outputs of $(wc -l < "$list") restored modules"
  cmd_build "$list" redo || true
  cmd_compare "$list" "$OUT/restored-manifest.tsv" || say "redo: MISMATCH against the VM's manifests"
}

cmd_importall() {
  { echo "import Mathlib"; sed 's/^/import /' "$OUT/restored-modules.txt"; } > "$OUT/ImportAll.lean"
  local rc=0
  ( cd "$BUILD" && env -i HOME=/tmp/exp-home PATH="$TC/bin:/usr/bin:/bin" LAKE_ARTIFACT_CACHE=false \
      /usr/bin/time -v lake env lean "$OUT/ImportAll.lean" ) > "$OUT/importall.log" 2>&1 || rc=$?
  local olean_mb; olean_mb=$(awk -F'\t' '$1 ~ /\.olean$/ {s+=$2} END {printf "%d", s/1e6}' "$OUT/restored-manifest.tsv")
  say "importall: one lean process importing Mathlib + $(wc -l < "$OUT/restored-modules.txt") project modules ($olean_mb MB of project .olean): rc=$rc, max RSS $(( $(awk -F': ' '/Maximum resident/ {print $2}' "$OUT/importall.log") / 1024 )) MB, wall $(awk -F': ' '/Elapsed/ {print $2}' "$OUT/importall.log")"
}

case "${1:-}" in
  sampler) cmd_sampler ;; resources) cmd_resources ;; dag) cmd_dag ;;
  build) cmd_build "$2" "$3" ;; pack) cmd_pack "$2" "$3" ;; compare) shift; cmd_compare "$@" ;;
  redo) cmd_redo "$2" ;; importall) cmd_importall ;;
  *) sed -n 2,13p "$0"; exit 2 ;;
esac
