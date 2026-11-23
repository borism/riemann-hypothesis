#!/usr/bin/env bash
# Resumable driver for the README's "Checking it" steps, sized for a standard
# Claude cloud machine (4 cores, 15 GB RAM, no swap, ~59 GB disk, no elan, no
# podman, outbound network through an allow-list proxy).
#
#   scripts/run-verification.sh --help
#
# Read verification/RUN-ON-CLOUD.md before trusting any result of this script.
# In particular: a run that stops in step 2, 3 or 4 is NOT a verification, and a
# 4.33.1-only pass is limited evidence (see verification/NOTES.md#lean-version).

set -euo pipefail

# ---------------------------------------------------------------- configuration
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RH_WORK:-$(dirname "$REPO")/rh-verify}"        # big, disposable state
LEAN_BUILD_VER="${RH_LEAN_BUILD_VER:-4.33.1}"           # builds + exports
LEAN_JUDGE_VER="${RH_LEAN_JUDGE_VER:-4.36.0}"           # lake comparator
EXPORTER_URL="https://github.com/leanprover/lean4export.git"
EXPORTER_TAG="v4.33.0"
EXPORTER_COMMIT="15f6055e299ad5b89345e533cc2192f4cc00f659"
EXPECTED_CHALLENGE_SHA="bd484ac9886a96f26b1d9a7a59ebd45b7a70d102c015d4f31f9302bbdd6ab2b9"  # README
# sha256 of the release tarballs, pinned in scripts/toolchain-sha256.txt (see its header
# for how they were obtained and what that does and does not establish).
TOOLCHAIN_PINS="$REPO/scripts/toolchain-sha256.txt"
LEAN_RELEASE_BASE="https://github.com/leanprover/lean4/releases/download"
MATHLIB_CACHE_GET_URL="${MATHLIB_CACHE_GET_URL:-https://cache.mathlib.org/mathlib4}"

CPUS="${RH_CPUS:-$(nproc)}"                  # CPUs the build may use (taskset)
MEM_GB="${RH_MEM_GB:-}"                      # memory cap for sandboxed steps; default: MemTotal - 2 GB
MIN_FREE_GB="${RH_MIN_FREE_GB:-3}"           # abort a step when free disk drops below this
STEP_TIMEOUT_MIN="${RH_STEP_TIMEOUT_MIN:-0}" # 0 = none. Steps 2 and 3 resume where they stopped.
DRY_RUN="${RH_DRY_RUN:-0}"
ATTEMPT_ANYWAY="${RH_ATTEMPT_ANYWAY:-0}"     # run steps 2-4 although preflight says they cannot fit

TOOLS="$WORK/toolchains"; DL="$WORK/dl"; STATE="$WORK/state"; LOGS="$WORK/logs"; RES="$WORK/results"
CLEAN="$WORK/clean"        # step 1 clone (never compiles submission code)
BUILD="$WORK/build"        # step 2/3 clone (submission code is compiled here, in a sandbox)
EXPORTER="$WORK/lean4export"
OUTDIR="$WORK/solution-out"
JUDGE_DIR="$WORK/judge"
TC_BUILD="$TOOLS/v$LEAN_BUILD_VER"; TC_JUDGE="$TOOLS/v$LEAN_JUDGE_VER"

# Rough costs of a full run, from verification/NOTES.md and README (not measured here).
NEED_DISK_STEP2_GB=110    # ~99 GB of .olean/.ilean for 175,187 modules, plus C and traces
NEED_DISK_STEP3_GB=65     # solution.export reported at 61.6 GB
NEED_MEM_STEP3_GB=165     # exporter peak reported at 163 GB
NEED_MEM_STEP4_GB=150     # notes' estimate for Lean's kernel and the hardened build

usage() {
  cat <<'EOF'
Usage: scripts/run-verification.sh [options] <command>

Commands (run in this order by `all`; each is skipped if its checkpoint exists):
  tools     download Lean toolchains from GitHub releases (no elan), build lean4export
  step1     export the challenge from a clean clone (Lean 4.33.1, Mathlib official cache)
  step2     build Main in a second clone inside a bubblewrap sandbox with no network
  step3     export the solution inside the sandbox (build tree read-only)
  step4     judge with `lake comparator` (Lean 4.36.0) from an empty directory
  all       tools, preflight, step1..step4
  preflight compare this machine with what the steps need; no changes made
  status    show checkpoints and the last lines of each log
  report    (re)write results/SUMMARY.md
  checkpoint  copy small logs/summary into verification/runs/<id>/ and commit+push them
  reset STEP  remove the checkpoint of STEP (tools|step1|step2|step3|step4)

Options (or the RH_* environment variables in brackets):
  --work DIR           [RH_WORK]            big working directory (default: sibling "rh-verify")
  --cpus N             [RH_CPUS]            CPUs the build may use (default: all)
  --mem-gb N           [RH_MEM_GB]          memory cap for sandboxed steps (default: RAM - 2)
  --min-free-gb N      [RH_MIN_FREE_GB]     stop a step when free disk is below N GB (default 3)
  --timeout-min N      [RH_STEP_TIMEOUT_MIN] stop step2/3 after N minutes (they resume next time)
  --attempt-anyway     [RH_ATTEMPT_ANYWAY=1] run steps 2-4 even if preflight says they cannot fit
  --dry-run            [RH_DRY_RUN=1]       print what would run; change nothing
  -h, --help

Small machine: RH_OPTIMISE=1 and scripts/rh-optimise.sh (compressed work dir, swap, import
of an export made elsewhere); see verification/measurements/2026-11-22-small-scale.md.

Exit status of `all`: 0 only if Comparator ran and exited 0. 75 means a resource
limit stopped a step (disk, memory or timeout); 70 means a step failed.
EOF
}

# ---------------------------------------------------------------------- helpers
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {
  if [ "$DRY_RUN" = 1 ]; then printf '[%s] %s\n' "$(ts)" "$*" >&2; return 0; fi
  mkdir -p "$LOGS"; printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOGS/run.log" >&2
}
die() { log "ERROR: $*"; exit 70; }
run() { if [ "$DRY_RUN" = 1 ]; then { printf 'DRY-RUN:'; printf ' %q' "$@"; echo; } >&2; else "$@"; fi; }
done_p()  { [ -f "$STATE/$1.done" ]; }
mark_done() { local n="$1"; shift; mkdir -p "$STATE"; { echo "finished: $(ts)"; printf '%s\n' "$@" "host: $(hostname), $(nproc) cores, $(mem_total_gb) GB RAM"; } > "$STATE/$n.done"; }
free_gb() { local d="$WORK"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; df -BG --output=avail "$d" | tail -1 | tr -dc 0-9; }
mem_total_gb() { awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo; }
mem_cap_gb() { if [ -n "$MEM_GB" ]; then echo "$MEM_GB"; else echo $(( $(mem_total_gb) - 2 )); fi; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

pin_env() {   # variables the README sets, with a deliberately small environment
  export LEAN_ABORT_ON_PANIC=1 LAKE_ARTIFACT_CACHE=false MATHLIB_CACHE_GET_URL
}

# --------------------------------------------------------------------- preflight
preflight() {   # preflight [STEP] : with STEP, only that step's verdict decides the exit status
  local only="${1:-}" free mem cores bw ok=1 v
  free=$(free_gb); mem=$(mem_total_gb); cores=$(nproc)
  command -v bwrap >/dev/null && bw=yes || bw=no
  echo "Machine: ${cores} cores, ${mem} GB RAM, swap $(awk '/SwapTotal/ {printf "%d", $2/1048576}' /proc/meminfo) GB, ${free} GB free near $WORK, bwrap: $bw"
  printf '%-7s %-40s %s\n' STEP NEEDS VERDICT
  chk() { # step needs verdict(0=fits) text
    printf '%-7s %-40s %s\n' "$1" "$2" "$4"; [ "$3" = 0 ] || { [ -n "$only" ] && [ "$only" != "$1" ] || ok=0; }; }
  chk step1 "~9 GB disk, <4 GB RAM" 0 fits
  if [ "$free" -ge "$NEED_DISK_STEP2_GB" ]; then chk step2 "~${NEED_DISK_STEP2_GB}+ GB disk; hours on 40+ cores" 0 "disk ok (time: see verification/RUN-ON-CLOUD.md)"
  else chk step2 "~${NEED_DISK_STEP2_GB}+ GB disk; hours on 40+ cores" 1 "DOES NOT FIT: ${free} GB free"; fi
  if [ "$free" -ge "$NEED_DISK_STEP3_GB" ] && [ "$mem" -ge "$NEED_MEM_STEP3_GB" ]; then chk step3 "${NEED_DISK_STEP3_GB} GB disk, ${NEED_MEM_STEP3_GB} GB RAM" 0 fits
  else chk step3 "${NEED_DISK_STEP3_GB} GB disk, ${NEED_MEM_STEP3_GB} GB RAM" 1 "DOES NOT FIT: ${free} GB free, ${mem} GB RAM"; fi
  if [ "$mem" -ge "$NEED_MEM_STEP4_GB" ]; then chk step4 "~${NEED_MEM_STEP4_GB} GB RAM per kernel" 0 fits
  else chk step4 "~${NEED_MEM_STEP4_GB} GB RAM per kernel" 1 "DOES NOT FIT: ${mem} GB RAM"; fi
  echo "(Needs are the notes' figures for the original 175,187-module build, not measurements.)"
  [ "$bw" = yes ] || { echo "bubblewrap missing: apt-get install -y bubblewrap"; ok=0; }
  [ "$ok" = 1 ]
}

# ------------------------------------------------------------------------- tools
cmd_tools() {
  done_p tools && { log "tools: already done"; return 0; }
  log "tools: start"
  command -v zstd >/dev/null || run apt-get install -y zstd
  command -v bwrap >/dev/null || run apt-get install -y bubblewrap
  run mkdir -p "$DL" "$TOOLS" "$RES"
  for v in "$LEAN_BUILD_VER" "$LEAN_JUDGE_VER"; do
    local t="$DL/lean-$v-linux.tar.zst"
    [ -s "$t" ] || [ -x "$TOOLS/v$v/bin/lean" ] || run curl -fsSL --retry 4 --retry-delay 5 -o "$t" "$LEAN_RELEASE_BASE/v$v/lean-$v-linux.tar.zst"
    if [ -s "$t" ] && [ "$DRY_RUN" != 1 ]; then
      local want got; want="$(awk -v n="lean-$v-linux.tar.zst" '$2==n {print $1}' "$TOOLCHAIN_PINS")"
      [ -n "$want" ] || die "no pinned sha256 for lean-$v-linux.tar.zst in $TOOLCHAIN_PINS"
      got="$(sha "$t")"
      [ "$got" = "$want" ] || { rm -rf "$TOOLS/v$v"; die "sha256 mismatch for $t: got $got, pinned $want"; }
    fi
    if [ ! -x "$TOOLS/v$v/bin/lean" ]; then
      run mkdir -p "$TOOLS/v$v"
      run tar --zstd -xf "$t" -C "$TOOLS/v$v" --strip-components=1
    fi
  done
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  : > "$RES/toolchains.txt"
  for v in "$LEAN_BUILD_VER" "$LEAN_JUDGE_VER"; do
    echo "lean $v tarball sha256 $(sha "$DL/lean-$v-linux.tar.zst")  ($LEAN_RELEASE_BASE/v$v/lean-$v-linux.tar.zst)" >> "$RES/toolchains.txt"
    "$TOOLS/v$v/bin/lean" --version >> "$RES/toolchains.txt"
  done
  # lean4export at the tag the notes name, built with the build toolchain.
  if [ ! -x "$EXPORTER/.lake/build/bin/lean4export" ]; then
    rm -rf "$EXPORTER"
    git clone -q "$EXPORTER_URL" "$EXPORTER"
    git -C "$EXPORTER" checkout -q "$EXPORTER_TAG"
    [ "$(git -C "$EXPORTER" rev-parse HEAD)" = "$EXPORTER_COMMIT" ] || die "lean4export $EXPORTER_TAG is not $EXPORTER_COMMIT"
    ( cd "$EXPORTER" && PATH="$TC_BUILD/bin:$PATH" lake build ) >"$LOGS/lean4export-build.log" 2>&1 || die "lean4export build failed, see $LOGS/lean4export-build.log"
  fi
  echo "lean4export $EXPORTER_TAG $(git -C "$EXPORTER" rev-parse HEAD) binary sha256 $(sha "$EXPORTER/.lake/build/bin/lean4export")" >> "$RES/toolchains.txt"
  mark_done tools "$(cat "$RES/toolchains.txt")"
  log "tools: done"
}

# ------------------------------------------------------------------------ clones
fresh_clone() {  # fresh_clone DEST : a pristine copy of the commit this script runs from
  local dest="$1" commit
  commit="$(git -C "$REPO" rev-parse HEAD)"
  [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || log "NOTE: working tree has uncommitted changes; the clone uses commit $commit only"
  rm -rf "$dest"
  git clone -q --no-hardlinks "$REPO" "$dest"
  git -C "$dest" checkout -q "$commit"
  echo "$commit"
}

# ---------------------------------------------------------------- monitor + caps
# Runs beside a long step; appends a TSV sample every 60 s and kills the step's
# process group when free disk drops below MIN_FREE_GB or MemAvailable below 0.5 GB.
start_monitor() {  # start_monitor NAME PID WATCHDIR
  local name="$1" pid="$2" watch="$3" tsv="$LOGS/monitor-$1.tsv" n=0 oleans="-"
  [ -f "$tsv" ] || printf 'time\tfree_disk_gb\tmem_avail_mb\tlean_procs\trss_mb\toleans\n' > "$tsv"
  (
    while kill -0 "$pid" 2>/dev/null; do
      local fd ma lp rss
      fd=$(free_gb); ma=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
      lp=$(pgrep -c -x lean || true)
      rss=$(ps -C lean -o rss= 2>/dev/null | awk '{s+=$1} END {print int(s/1024)}')
      if [ $((n % 10)) = 0 ] && [ -d "$watch" ]; then oleans=$(find "$watch" -name '*.olean' 2>/dev/null | wc -l); fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$fd" "$ma" "$lp" "$rss" "$oleans" >> "$tsv"
      if [ "$fd" -lt "$MIN_FREE_GB" ]; then
        echo "DISK-LIMIT: ${fd} GB free < ${MIN_FREE_GB} GB" > "$STATE/$name.stopped"
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; break
      fi
      if [ "$ma" -lt 512 ]; then
        echo "MEMORY-LIMIT: MemAvailable ${ma} MB" > "$STATE/$name.stopped"
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; break
      fi
      n=$((n+1)); sleep 60
    done
  ) &
  MONITOR_PID=$!
}

# cgroup v1 memory cap when the machine allows it (kernel OOM-kills inside the
# group only); otherwise the monitor's MemAvailable check is the only guard.
cg_enter() {  # cg_enter NAME : move the calling shell into a capped cgroup
  local cg="/sys/fs/cgroup/memory/rhverify-$1" cap=$(( $(mem_cap_gb) * 1073741824 ))
  if [ -w /sys/fs/cgroup/memory ] && mkdir -p "$cg" 2>/dev/null; then
    echo "$cap" > "$cg/memory.limit_in_bytes" 2>/dev/null && echo $BASHPID > "$cg/cgroup.procs" 2>/dev/null \
      && return 0
  fi
  echo "no cgroup memory cap available; relying on the MemAvailable watchdog" >&2
}

cgroup_mem_ok() { [ -w /sys/fs/cgroup/memory ] && [ -w /sys/fs/cgroup/memory/cgroup.procs ]; }
guard_desc() {   # what actually limits memory for a sandboxed step
  local sw; sw="$(awk 'NR>1 {printf "%s%s (%d GB)", (n++?", ":""), $1, $3/1048576}' /proc/swaps)"
  if cgroup_mem_ok; then echo "memory: cgroup v1 cap $(mem_cap_gb) GB (kernel OOM-kills inside the group) plus a 60 s MemAvailable<512 MB watchdog"
  else echo "memory: NO cgroup cap available; ONLY a 60 s MemAvailable<512 MB watchdog guards this machine (a fast allocation can still trigger the kernel OOM killer)"; fi
  # Swap (e.g. zram) is not a cap: MemAvailable and the preflight's MemTotal checks ignore it.
  if [ -n "$sw" ]; then echo "swap active: $sw (not counted by the watchdog or the preflight)"; else echo "swap: none"; fi
}

# bubblewrap with no network, no capabilities, cleared environment (so the proxy
# variables and tokens of this shell are not visible inside).
#   sandbox_cmd ROW_DIRS... -- RW_DIRS... -- TOOLCHAIN [VAR=VALUE...] -- CMD...
# Fills the array SBX. Read-only: system dirs, the toolchain, ROW_DIRS.
# Writable: RW_DIRS and a tmpfs /tmp. Callers run "${SBX[@]}".
sandbox_cmd() {
  local -a ro=() rw=() ev=()
  while [ "$1" != -- ]; do ro+=(--ro-bind "$1" "$1"); shift; done; shift
  while [ "$1" != -- ]; do rw+=(--bind "$1" "$1"); shift; done; shift
  local tc="$1"; shift
  while [ "$1" != -- ]; do ev+=(--setenv "${1%%=*}" "${1#*=}"); shift; done; shift
  SBX=(bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64
    --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp
    --ro-bind "$tc" "$tc" "${ro[@]}" "${rw[@]}"
    --setenv HOME /tmp/home --setenv PATH "$tc/bin:/usr/bin:/bin"
    --setenv LEAN_ABORT_ON_PANIC 1 --setenv LAKE_ARTIFACT_CACHE false --setenv LANG C.UTF-8
    ${RH_LEAN_THREADS:+--setenv LEAN_NUM_THREADS "$RH_LEAN_THREADS"}   # optional: cap Lean/Lake worker threads (concurrent module builds)
    "${ev[@]}" --chdir "${SBX_CHDIR:?}" "$@")
}

# ------------------------------------------------------------------------- step1
cmd_step1() {
  done_p step1 && { log "step1: already done"; return 0; }
  done_p tools || cmd_tools
  log "step1: start (clean clone, Lean $LEAN_BUILD_VER)"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: would clone, mathlib/cache get, lake build Challenge, lean4export"; return 0; }
  pin_env; export PATH="$EXPORTER/.lake/build/bin:$TC_BUILD/bin:$PATH"
  mkdir -p "$RES" "$LOGS"
  local commit; commit="$(fresh_clone "$CLEAN")"
  cd "$CLEAN"
  # Mathlib only, from the official cache. NOT `lake exe cache get` (community cache).
  lake exe mathlib/cache get > "$LOGS/step1-cache-get.log" 2>&1 || die "step1: lake exe mathlib/cache get failed; tail: $(tail -3 "$LOGS/step1-cache-get.log")"
  lake build Challenge > "$LOGS/step1-build.log" 2>&1 || die "step1: lake build Challenge failed; see $LOGS/step1-build.log"
  [ ! -e .lake/build/lib/lean/Main.olean ] || die "step1: clean clone contains Main.olean"
  lake env lean4export Challenge -- $(cat export-targets.txt) > "$RES/challenge.export.tmp" 2> "$LOGS/step1-export.log" || die "step1: export failed"
  mv "$RES/challenge.export.tmp" "$RES/challenge.export"; chmod a-w "$RES/challenge.export"
  local s; s=$(sha "$RES/challenge.export"); echo "$s  challenge.export" > "$RES/challenge.export.sha256"
  local verdict="MATCHES the sha256 in the README"; [ "$s" = "$EXPECTED_CHALLENGE_SHA" ] || verdict="DIFFERS from the README's $EXPECTED_CHALLENGE_SHA"
  log "step1: challenge.export sha256 $s ($verdict), $(stat -c %s "$RES/challenge.export") bytes"
  mark_done step1 "commit: $commit" "sha256: $s" "readme-check: $verdict"
}

# ------------------------------------------------------------------------- step2
# Needs step1 first: the challenge must be exported before submission code is compiled.
cmd_step2() {
  done_p step2 && { log "step2: already done"; return 0; }
  done_p step1 || die "step2 requires step1 (challenge must be exported before any submission code is compiled)"
  preflight_gate step2
  log "step2: start (build clone, offline bubblewrap sandbox, $CPUS CPUs, stop below ${MIN_FREE_GB} GB free disk; $(guard_desc | tr '\n' ';'))"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: would clone, mathlib/cache get, then bwrap lake build Main"; return 0; }
  pin_env; export PATH="$TC_BUILD/bin:$PATH"
  if [ ! -f "$STATE/step2.cloned" ]; then
    fresh_clone "$BUILD" > "$STATE/step2.cloned"
    ( cd "$BUILD" && lake exe mathlib/cache get ) > "$LOGS/step2-cache-get.log" 2>&1 || die "step2: lake exe mathlib/cache get failed"
  fi
  rm -f "$STATE/step2.stopped"
  # Lake keeps a .setup.json per module listing its whole import closure (~6 MB each,
  # ~1 TB over 175k modules). It is not needed once the module is built; delete as the notes advise.
  local inner='
    mkdir -p "$HOME"
    ( while sleep 120; do
        find .lake/build/ir -name "*.setup.json" -print0 2>/dev/null | while IFS= read -r -d "" f; do
          t=".lake/build/lib/lean/${f#.lake/build/ir/}"
          [ "${t%.setup.json}.trace" -nt "$f" ] && rm -f -- "$f"
        done
      done ) &
    lake build Main; rc=$?; kill $! 2>/dev/null; exit $rc'
  local tcmd=(); [ "$STEP_TIMEOUT_MIN" -gt 0 ] && tcmd=(timeout --signal=TERM "${STEP_TIMEOUT_MIN}m")
  SBX_CHDIR="$BUILD" sandbox_cmd -- "$BUILD" -- "$TC_BUILD" -- bash -c "$inner"
  set +e
  (
    cg_enter step2
    exec setsid taskset -c "0-$((CPUS-1))" "${tcmd[@]}" "${SBX[@]}"
  ) > "$LOGS/step2-build.log" 2>&1 &
  local pid=$!
  start_monitor step2 "$pid" "$BUILD/.lake/build/lib/lean"
  wait "$pid"; local rc=$?
  kill "$MONITOR_PID" 2>/dev/null; wait "$MONITOR_PID" 2>/dev/null
  set -e
  summarize_build "$rc"
  if [ -f "$STATE/step2.stopped" ]; then log "step2: STOPPED: $(cat "$STATE/step2.stopped") (resume by re-running)"; exit 75; fi
  if [ "$rc" = 124 ] || [ "$rc" = 143 ]; then log "step2: stopped by timeout/TERM (rc=$rc); resume by re-running"; exit 75; fi
  if [ "$rc" = 137 ]; then log "step2: killed (rc=137), most likely the kernel OOM killer; see $LOGS/step2-build.log"; exit 75; fi
  [ "$rc" = 0 ] || die "step2: lake build Main failed (rc=$rc); see $LOGS/step2-build.log"
  [ -f "$BUILD/.lake/build/lib/lean/Main.olean" ] || die "step2: build reported success but Main.olean is missing"
  mark_done step2 "lake build Main: exit 0"
  log "step2: done"
}

summarize_build() {
  local n; n=$(find "$BUILD/.lake/build/lib/lean" -name '*.olean' 2>/dev/null | wc -l)
  log "step2: rc=$1; $n .olean files in the build tree; $(du -sh "$BUILD/.lake" 2>/dev/null | cut -f1) in .lake; $(free_gb) GB free"
  tail -n 3 "$LOGS/step2-build.log" 2>/dev/null | sed 's/^/    /' >&2 || true
}

# ------------------------------------------------------------------------- step3
cmd_step3() {
  done_p step3 && { log "step3: already done"; return 0; }
  done_p step2 || die "step3 requires step2 (a completed build of Main)"
  preflight_gate step3
  log "step3: start (export inside offline sandbox; build tree read-only; $(guard_desc | tr '\n' ';'))"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: would bwrap lake env lean4export Main"; return 0; }
  pin_env; mkdir -p "$OUTDIR"; rm -f "$OUTDIR/solution.export" "$STATE/step3.stopped"
  # lean4export is rebuilt after the build (the notes' rule): the copy from `tools` was never
  # visible to the build sandbox, which could only write to $BUILD.
  local targets; targets="$(cat "$CLEAN/export-targets.txt")"   # from the clean clone
  SBX_CHDIR="$BUILD" sandbox_cmd "$BUILD" "$EXPORTER" -- "$OUTDIR" -- "$TC_BUILD" "TARGETS=$targets" "EXPORTER_BIN=$EXPORTER/.lake/build/bin" -- \
    bash -c 'mkdir -p "$HOME"; PATH="$EXPORTER_BIN:$PATH"; lake env lean4export Main -- $TARGETS > '"$OUTDIR"'/solution.export'
  set +e
  (
    cg_enter step3
    exec setsid taskset -c "0-$((CPUS-1))" "${SBX[@]}"
  ) > "$LOGS/step3-export.log" 2>&1 &
  local pid=$!
  start_monitor step3 "$pid" "$OUTDIR"
  wait "$pid"; local rc=$?
  kill "$MONITOR_PID" 2>/dev/null; wait "$MONITOR_PID" 2>/dev/null
  set -e
  if [ -f "$STATE/step3.stopped" ]; then log "step3: STOPPED: $(cat "$STATE/step3.stopped")"; exit 75; fi
  [ "$rc" = 137 ] && { log "step3: killed (rc=137), most likely OOM"; exit 75; }
  [ "$rc" = 0 ] || die "step3: export failed (rc=$rc); see $LOGS/step3-export.log"
  mv "$OUTDIR/solution.export" "$RES/solution.export"
  local s; s=$(sha "$RES/solution.export"); echo "$s  solution.export" > "$RES/solution.export.sha256"
  log "step3: solution.export sha256 $s, $(stat -c %s "$RES/solution.export") bytes (reported by others: 5ea74b91...be244e)"
  mark_done step3 "sha256: $s"
}

# ------------------------------------------------------------------------- step4
cmd_step4() {
  done_p step4 && { log "step4: already done"; return 0; }
  rm -f "$STATE/step4.failed"
  done_p step1 && done_p step3 || die "step4 requires step1 and step3 (challenge.export and solution.export)"
  preflight_gate step4
  log "step4: start (Lean $LEAN_JUDGE_VER lake comparator, from an empty directory; $(guard_desc | tr '\n' ';'))"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: would run lake comparator"; return 0; }
  rm -rf "$JUDGE_DIR"; mkdir -p "$JUDGE_DIR"
  # The judge's config and the challenge come from the clean clone, not from the build clone.
  set +e
  ( cg_enter step4; cd "$JUDGE_DIR"
    env -i HOME="$JUDGE_DIR" PATH="$TC_JUDGE/bin:/usr/bin:/bin" LEAN_ABORT_ON_PANIC=1 \
      lake comparator --config "$CLEAN/comparator.json" \
        --challenge-from-export "$RES/challenge.export" --solution-from-export "$RES/solution.export" ) \
    > "$RES/comparator.log" 2>&1
  local rc=$?
  set -e
  echo "$rc" > "$RES/comparator.exit"
  log "step4: lake comparator exit code $rc"
  tail -n 5 "$RES/comparator.log" | sed 's/^/    /' >&2
  if [ "$rc" = 0 ]; then mark_done step4 "comparator exit: 0"; rm -f "$STATE/step4.failed"
  else
    { echo "finished: $(ts)"; echo "comparator exit: $rc (REJECTED or FAILED; see results/comparator.log)"; } > "$STATE/step4.failed"
    log "step4: Comparator did NOT accept (exit $rc). This is a failed or rejected run, not a pass."
  fi
  return "$rc"
}

# ----------------------------------------------------------------------- gating
preflight_gate() {
  [ "$ATTEMPT_ANYWAY" = 1 ] && return 0
  local out; if out=$(preflight "$1" 2>&1); then return 0; fi
  echo "$out" >&2
  log "$1: this machine does not meet that step's estimated needs (above). Refusing to start; use --attempt-anyway to measure where it stops."
  exit 75
}

# ------------------------------------------------------------------------ report
cmd_report() {
  mkdir -p "$RES"
  local f="$RES/SUMMARY.md" s
  {
    echo "# Verification run summary"
    echo; echo "Written $(ts) by scripts/run-verification.sh from commit $(git -C "$REPO" rev-parse HEAD)."
    echo "Machine: $(nproc) cores, $(mem_total_gb) GB RAM, $(free_gb) GB free disk."
    echo; echo "## Steps (a step without a checkpoint did NOT complete)"
    for s in tools step1 step2 step3 step4; do
      if done_p $s; then echo "- $s: DONE  ($(tr '\n' ' ' < "$STATE/$s.done"))"
      elif [ -f "$STATE/$s.failed" ]; then echo "- $s: REJECTED/FAILED  ($(tr '\n' ' ' < "$STATE/$s.failed"))"
      else echo "- $s: NOT COMPLETED"; fi
    done
    [ -f "$STATE/step2.stopped" ] && echo "- step2 last stopped by: $(cat "$STATE/step2.stopped")"
    echo; echo "## Hashes"
    for s in challenge solution; do [ -f "$RES/$s.export.sha256" ] && echo "- $(cat "$RES/$s.export.sha256")"; done
    echo; echo "## Tools"; [ -f "$RES/toolchains.txt" ] && sed 's/^/    /' "$RES/toolchains.txt"
    echo; echo "## Comparator"
    if [ -f "$RES/comparator.exit" ]; then echo "exit code: $(cat "$RES/comparator.exit")"; echo '```'; tail -n 40 "$RES/comparator.log"; echo '```'
    else echo "Not run. No verdict exists."; fi
    echo; echo "## Provenance"
    echo "Every step marked DONE above ran on the machine named in its checkpoint (host: ...) under this script's"
    echo "control. This script does not assume a single machine, but it does not accept results from elsewhere: an"
    echo "export, build or Comparator result produced on machines we do not control (offloaded or third-party) is"
    echo "unverified evidence, is not a verdict of this script, and must be labelled as such wherever it is quoted."
    echo; echo "## Reading this"
    echo "Only a Comparator exit code of 0 from a complete run of steps 1 to 4 means the exports were accepted."
    echo "Even then, the build and exports used Lean $LEAN_BUILD_VER only; see verification/NOTES.md#lean-version and #checkers."
  } > "$f"
  log "report: $f"
}

# ------------------------------------------------------------------ checkpoint
cmd_checkpoint() {
  cmd_report
  local id; id="$(date -u +%Y%m%dT%H%M%SZ)"; local d="$REPO/verification/runs/$id"
  mkdir -p "$d"
  cp "$RES/SUMMARY.md" "$d/" ; cp "$RES"/*.sha256 "$RES/toolchains.txt" "$RES/comparator."* "$d/" 2>/dev/null || true
  for l in "$LOGS"/*.log; do [ -f "$l" ] && tail -n 200 "$l" > "$d/$(basename "$l")"; done
  for t in "$LOGS"/monitor-*.tsv; do [ -f "$t" ] && { head -1 "$t"; tail -n 200 "$t" | grep -v '^time'; } > "$d/$(basename "$t")"; done
  cp -r "$STATE" "$d/state" 2>/dev/null || true
  git -C "$REPO" add "$d"
  git -C "$REPO" commit -q -m "verification run $id: checkpoint (logs and summary only)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_012BQmPS17QUemzEFZXpRAHz" || { log "checkpoint: nothing to commit"; return 0; }
  # RH_PUSH_BRANCH: remote branch to publish to (default: the checked-out branch). Never force-pushes.
  local br i; br="${RH_PUSH_BRANCH:-$(git -C "$REPO" rev-parse --abbrev-ref HEAD)}"
  for i in 1 2 3 4; do
    git -C "$REPO" fetch -q origin "$br" && git -C "$REPO" merge -q --no-edit FETCH_HEAD || { log "checkpoint: fetch/merge failed"; }
    git -C "$REPO" push origin "HEAD:$br" && return 0
    log "checkpoint: push failed (attempt $i); retrying in $((2**i)) s"; sleep $((2**i))
  done
  log "checkpoint: push failed after 4 attempts; commit is local"; return 1
}

cmd_status() {
  for s in tools step1 step2 step3 step4; do
    if done_p $s; then echo "$s: DONE ($(sed -n 1p "$STATE/$s.done"))"
    elif [ -f "$STATE/$s.failed" ]; then echo "$s: REJECTED/FAILED ($(sed -n 2p "$STATE/$s.failed"))"
    else echo "$s: not completed"; fi
  done
  [ -f "$STATE/step2.stopped" ] && echo "step2 stopped by: $(cat "$STATE/step2.stopped")"
  echo "free disk: $(free_gb) GB"
  tail -n 5 "$LOGS/run.log" 2>/dev/null || true
}

# Small-machine optimisations (issue #1): with RH_OPTIMISE=1, scripts/rh-optimise.sh replaces
# preflight (measured needs, counts swap/compression), start_monitor (swap-aware) and cg_enter
# (RH_MEM_GB=0 = no cgroup cap). Storage, swap and import commands: scripts/rh-optimise.sh --help.
# shellcheck source=scripts/rh-optimise.sh
. "$REPO/scripts/rh-optimise.sh"

# -------------------------------------------------------------------------- main
CMD=""; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --work) WORK="$2"; shift ;;
    --cpus) CPUS="$2"; shift ;;
    --mem-gb) MEM_GB="$2"; shift ;;
    --min-free-gb) MIN_FREE_GB="$2"; shift ;;
    --timeout-min) STEP_TIMEOUT_MIN="$2"; shift ;;
    --attempt-anyway) ATTEMPT_ANYWAY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
    *) if [ -z "$CMD" ]; then CMD="$1"; else ARG="$1"; fi ;;
  esac; shift
done
TOOLS="$WORK/toolchains"; DL="$WORK/dl"; STATE="$WORK/state"; LOGS="$WORK/logs"; RES="$WORK/results"
CLEAN="$WORK/clean"; BUILD="$WORK/build"; EXPORTER="$WORK/lean4export"; OUTDIR="$WORK/solution-out"; JUDGE_DIR="$WORK/judge"
TC_BUILD="$TOOLS/v$LEAN_BUILD_VER"; TC_JUDGE="$TOOLS/v$LEAN_JUDGE_VER"
[ "$DRY_RUN" = 1 ] || mkdir -p "$STATE" "$LOGS" "$RES"

case "$CMD" in
  tools) cmd_tools ;;
  step1) cmd_step1 ;;
  step2) cmd_step2 ;;
  step3) cmd_step3 ;;
  step4) cmd_step4 ;;
  all)
    preflight || log "preflight: this machine will not fit all steps (see above); steps 2-4 refuse to start unless --attempt-anyway"
    trap cmd_report EXIT
    cmd_tools; cmd_step1; cmd_step2; cmd_step3; cmd_step4 ;;
  preflight) preflight ;;
  status) cmd_status ;;
  report) cmd_report ;;
  checkpoint) cmd_checkpoint ;;
  reset) [ -n "$ARG" ] || { usage >&2; exit 2; }; rm -f "$STATE/$ARG.done" "$STATE/$ARG.stopped" "$STATE/$ARG.failed"; echo "reset $ARG" ;;
  "") usage >&2; exit 2 ;;
  *) echo "unknown command $CMD" >&2; usage >&2; exit 2 ;;
esac
