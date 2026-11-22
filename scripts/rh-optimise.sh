#!/usr/bin/env bash
# Small-machine optimisations for scripts/run-verification.sh (issue #1).
#
# Two ways to use this file:
#
# 1. Standalone commands (root needed for mount/swap):
#      scripts/rh-optimise.sh storage-mount  [LEVEL] [SIZE]  put $RH_WORK on a zstd-compressed btrfs loop image
#      scripts/rh-optimise.sh storage-status                 compression ratio and real image size
#      scripts/rh-optimise.sh storage-umount
#      scripts/rh-optimise.sh zram SIZE [ALG]                OPTIONAL: zram swap (RAM-only, compressed)
#      scripts/rh-optimise.sh swap-file SIZE                 OPTIONAL: plain swap file on the root disk
#      scripts/rh-optimise.sh swap-compressed SIZE           EXPERIMENTAL: swap on a loop device over a file
#                                                            inside the compressed btrfs image
#      scripts/rh-optimise.sh swap-off                       remove the swap devices this script added
#      scripts/rh-optimise.sh prune-clean                    after step1: delete the clean clone's .lake (keeps
#                                                            comparator.json, export-targets.txt, challenge.export)
#      scripts/rh-optimise.sh prune-build                    after step2: delete .ilean/.c/.setup.json (not read
#                                                            by the exporter); the build is then no longer "up to date"
#      scripts/rh-optimise.sh import challenge|solution FILE [SHA256]
#                                                            take an export made elsewhere as the input of a later
#                                                            step, so step3/step4 can run in isolation (see below)
#      scripts/rh-optimise.sh budget                         print the measured per-step needs against this machine
#
# 2. Sourced by run-verification.sh when RH_OPTIMISE=1. It then replaces three functions:
#    preflight (measured needs, counts swap and compression), start_monitor (swap-aware memory
#    watchdog) and cg_enter (RH_MEM_GB=0 means no cgroup cap; a cgroup-v1 cap below a step's need
#    OOM-kills it instead of letting it swap, which is what was measured here).
#
# None of this changes what is checked. Compression and swap change where bytes live and how fast
# they are read; the files read back are bit-identical (sha256 is recorded after every step). See
# verification/measurements/2026-11-22-small-scale.md for the measurements, and for what each option does and does not weaken.

# ---------------------------------------------------------------- measured needs (issue #1)
# Per-line costs were measured on a 12.1M-line, 651 MB Mathlib export; the solution export has
# ~1.14e9 lines (61,570,595,788 bytes / 54 bytes per line). Disk costs from the first 627 modules.
OPT_LINES_SOLUTION=1140000000
OPT_NEED_VIRT_STEP3_GB=42     # lean4export: 33 B/line heap (~38 GB) + imported environment of Main (~2-4 GB)
OPT_NEED_VIRT_STEP4_GB=115    # leanchecker-paranoid 98 B/line (~112 GB); leanchecker 82 B (~93 GB); nanoda 65 B (~74 GB)
OPT_NEED_DISK_STEP2_RAW_GB=110
OPT_NEED_DISK_STEP2_ZSTD_GB=42   # .olean 99.5 GB at 31-34% + Mathlib + toolchain + ilean/c/traces
OPT_NEED_DISK_STEP3_ZSTD_GB=52   # step 2's tree + solution.export at 14% (zstd:9) of 61.6 GB
OPT_NEED_DISK_STEP4_ZSTD_GB=12   # solution.export at 14% + toolchain; everything else can be deleted

opt_img() { echo "${RH_STORAGE_IMG:-${WORK%/}.btrfs.img}"; }
opt_compressed() {  # 0 if $WORK is a mount with btrfs compression
  local o; o="$(findmnt -no FSTYPE,OPTIONS --target "$WORK" 2>/dev/null)" || return 1
  [[ "$o" == btrfs*compress* ]]
}
opt_swap_gb()   { awk '/SwapTotal/ {printf "%d", $2/1048576}' /proc/meminfo; }
opt_ram_gb()    { awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo; }

# ---------------------------------------------------------------- storage
opt_storage_mount() {
  local level="${1:-9}" size="${2:-400G}" img; img="$(opt_img)"
  if findmnt -n "$WORK" >/dev/null 2>&1; then echo "already mounted: $(findmnt -no SOURCE,FSTYPE,OPTIONS "$WORK")"; return 0; fi
  command -v mkfs.btrfs >/dev/null || apt-get install -y btrfs-progs btrfs-compsize
  if [ -d "$WORK" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
    echo "refusing: $WORK exists and is not empty; move it away first (its content would be hidden)" >&2; return 1
  fi
  mkdir -p "$WORK"
  if [ ! -f "$img" ]; then
    truncate -s "$size" "$img"            # sparse: takes only what is written
    mkfs.btrfs -q -m single -d single "$img"
  fi
  # compress-force: compress even when btrfs's first-block heuristic says no (olean headers).
  # discard=async: space freed inside the image is handed back to the root disk.
  mount -o loop,compress-force=zstd:"$level",noatime,discard=async "$img" "$WORK"
  echo "mounted $img on $WORK (zstd:$level)"
}
opt_storage_status() {
  findmnt -no SOURCE,FSTYPE,OPTIONS --target "$WORK"
  echo "image on disk: $(du -h "$(opt_img)" 2>/dev/null | cut -f1) (sparse, logical $(du -h --apparent-size "$(opt_img)" 2>/dev/null | cut -f1)); real free disk: $(df -h --output=avail "$(dirname "$(opt_img)")" | tail -1)"
  command -v compsize >/dev/null && compsize -x "$WORK" 2>/dev/null | sed -n '1,4p'
  df -h / "$WORK" | sed 1d
}
opt_storage_umount() { sync; umount "$WORK"; }

# ---------------------------------------------------------------- swap (all optional, all machine-wide)
OPT_SWAPLIST="${WORK%/}.swaps"    # devices/files this script added, one per line
opt_zram() {   # the commands used on the cloud VM; needs root and the zram module
  local size="${1:?size, e.g. 8G}" alg="${2:-lz4}" dev
  dev="$(zramctl --find --algorithm "$alg" --size "$size")" || { echo "zram not available here" >&2; return 1; }
  mkswap "$dev" >/dev/null && swapon -p 100 "$dev" && echo "$dev zram" >> "$OPT_SWAPLIST" && echo "zram swap $dev $size $alg"
}
opt_swap_file() {
  local size="${1:?size, e.g. 20G}" f="${WORK%/}.swapfile"
  fallocate -l "$size" "$f" && chmod 600 "$f" && mkswap "$f" >/dev/null && swapon -p 10 "$f" \
    && echo "$f file" >> "$OPT_SWAPLIST" && echo "swap file $f $size"
}
opt_swap_compressed() {
  # EXPERIMENTAL. Swap on a loop device whose backing file is inside the compressed btrfs image, so
  # swapped pages are stored zstd-compressed on disk (measured: Lean kernel heap at 41% with zstd:1).
  # Risks: swapping through a filesystem can deadlock under extreme memory pressure, and
  # copy-on-write can make the file take more disk than its size. Lower priority than zram.
  local size="${1:?size, e.g. 40G}" f dev
  opt_compressed || { echo "$WORK is not on compressed btrfs; run storage-mount first" >&2; return 1; }
  f="$WORK/.swap.img"; truncate -s "$size" "$f"
  dev="$(losetup -f --show "$f")" && mkswap "$dev" >/dev/null && swapon -p 50 "$dev" \
    && echo "$dev loop" >> "$OPT_SWAPLIST" && echo "compressed swap $dev over $f ($size)"
}
opt_swap_off() {
  [ -f "$OPT_SWAPLIST" ] || { echo "nothing to remove"; return 0; }
  local dev kind
  while read -r dev kind; do
    swapoff "$dev" 2>/dev/null
    case "$kind" in loop) losetup -d "$dev"; rm -f "$WORK/.swap.img" ;; file) rm -f "$dev" ;; zram) zramctl --reset "$dev" ;; esac
    echo "removed $kind swap $dev"
  done < "$OPT_SWAPLIST"
  rm -f "$OPT_SWAPLIST"
}

# ---------------------------------------------------------------- pruning
opt_prune_clean() {
  [ -f "$STATE/step1.done" ] || { echo "step1 is not done; nothing pruned" >&2; return 1; }
  [ -s "$RES/challenge.export" ] || { echo "no results/challenge.export; nothing pruned" >&2; return 1; }
  du -sh "$CLEAN/.lake" 2>/dev/null; rm -rf "$CLEAN/.lake"; echo "removed $CLEAN/.lake (step 4 needs only comparator.json and the challenge export)"
}
opt_prune_build() {
  [ -f "$STATE/step2.done" ] || { echo "step2 is not done; nothing pruned" >&2; return 1; }
  find "$BUILD/.lake/build" \( -name '*.ilean' -o -name '*.c' -o -name '*.setup.json' \) -delete
  echo "removed .ilean/.c/.setup.json under $BUILD/.lake/build (the exporter reads only .olean)"
}

# ---------------------------------------------------------------- isolation: import an export
opt_import() {   # import challenge|solution FILE [SHA256]
  local kind="${1:?challenge|solution}" f="${2:?FILE}" want="${3:-}" got
  [ -f "$f" ] || { echo "no such file $f" >&2; return 1; }
  case "$kind" in
    challenge) want="${want:-bd484ac9886a96f26b1d9a7a59ebd45b7a70d102c015d4f31f9302bbdd6ab2b9}" ;;
    solution)  want="${want:-5ea74b912147c5c93cc2b6d70cc727cf908df2f62ac6a20480a3fa02f6be244e}" ;;  # reported in NOTES.md
    *) echo "kind must be challenge or solution" >&2; return 2 ;;
  esac
  mkdir -p "$RES" "$STATE"
  got="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then echo "REFUSED: sha256 of $f is $got, expected $want" >&2; return 1; fi
  cp --reflink=auto "$f" "$RES/$kind.export"; chmod a-w "$RES/$kind.export"
  echo "$got  $kind.export" > "$RES/$kind.export.sha256"
  local step=step1; [ "$kind" = solution ] && step=step3
  { echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "IMPORTED, not produced by this run: $f"; echo "sha256: $got (matches expected $want)"; } > "$STATE/$step.done"
  # step 4 reads comparator.json from the clean clone; make one without building anything.
  if [ ! -f "$CLEAN/comparator.json" ]; then git clone -q --no-hardlinks "$REPO" "$CLEAN" && git -C "$CLEAN" checkout -q "$(git -C "$REPO" rev-parse HEAD)"; fi
  echo "imported $kind.export ($got); $step marked DONE as IMPORTED"
}

# ---------------------------------------------------------------- budget
opt_budget() {
  local ram swap free c=no; ram=$(opt_ram_gb); swap=$(opt_swap_gb)
  local d="$WORK"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; free=$(df -BG --output=avail "$d" | tail -1 | tr -dc 0-9)
  opt_compressed && c=yes
  echo "Machine: $(nproc) cores, ${ram} GB RAM, ${swap} GB swap ($(awk 'NR>1 {printf "%s ", $1}' /proc/swaps)), ${free} GB free, compressed work dir: $c"
  echo "step2 disk: need ~${OPT_NEED_DISK_STEP2_RAW_GB} GB raw or ~${OPT_NEED_DISK_STEP2_ZSTD_GB} GB compressed; RAM ~6 GB with 4 jobs; ~100 h on 4 cores (27 modules/min measured)"
  echo "step3: need ~${OPT_NEED_VIRT_STEP3_GB} GB of RAM+swap (heap) plus page cache for ~105 GB of mmapped .olean; disk ~${OPT_NEED_DISK_STEP3_ZSTD_GB} GB compressed"
  echo "step4: need ~${OPT_NEED_VIRT_STEP4_GB} GB of RAM+swap for leanchecker-paranoid (checkers run one at a time); disk ~${OPT_NEED_DISK_STEP4_ZSTD_GB} GB compressed + swap"
  echo "have RAM+swap: $((ram + swap)) GB (zram counts at its configured size, which overstates it by the compression ratio)"
}

# ---------------------------------------------------------------- overrides when sourced
if [ "${BASH_SOURCE[0]}" != "$0" ] && [ "${RH_OPTIMISE:-0}" = 1 ]; then
  # On a compressed loop image the filesystem's own free space is fictional (sparse image); the
  # real limit is the disk holding the image, so the disk watchdog and preflight use that.
  free_gb() {
    if opt_compressed; then df -BG --output=avail "$(dirname "$(opt_img)")" | tail -1 | tr -dc 0-9
    else local d="$WORK"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; df -BG --output=avail "$d" | tail -1 | tr -dc 0-9; fi
  }
  preflight() {
    local only="${1:-}" ok=1 free ram swap virt bw comp=0
    free=$(free_gb); ram=$(mem_total_gb); swap=$(opt_swap_gb); virt=$((ram + swap)); opt_compressed && comp=1
    command -v bwrap >/dev/null && bw=yes || bw=no
    echo "Machine (RH_OPTIMISE=1): $(nproc) cores, ${ram} GB RAM + ${swap} GB swap, ${free} GB free near $WORK, compressed: $comp, bwrap: $bw"
    chk() { printf '%-7s %-52s %s\n' "$1" "$2" "$4"; [ "$3" = 0 ] || { [ -n "$only" ] && [ "$only" != "$1" ] || ok=0; }; }
    local d2=$OPT_NEED_DISK_STEP2_RAW_GB; [ $comp = 1 ] && d2=$OPT_NEED_DISK_STEP2_ZSTD_GB
    chk step1 "~9 GB disk" 0 fits
    # Disk already used by a resumed build counts as available to it.
    local used2=0
    if [ $comp = 1 ]; then used2=$(du -s -BG "$(opt_img)" 2>/dev/null | cut -f1 | tr -dc 0-9)
    elif [ -d "$BUILD/.lake" ]; then used2=$(du -s -BG "$BUILD/.lake" 2>/dev/null | cut -f1 | tr -dc 0-9); fi
    [ $((free + used2)) -ge "$d2" ] && chk step2 "~$d2 GB disk (measured), ~100 h on 4 cores" 0 "disk ok" || chk step2 "~$d2 GB disk" 1 "DOES NOT FIT: $((free + used2)) GB"
    [ "$virt" -ge "$OPT_NEED_VIRT_STEP3_GB" ] && chk step3 "~$OPT_NEED_VIRT_STEP3_GB GB RAM+swap (measured per line)" 0 "fits by capacity (slow if swapping)" \
      || chk step3 "~$OPT_NEED_VIRT_STEP3_GB GB RAM+swap" 1 "DOES NOT FIT: $virt GB RAM+swap"
    [ "$virt" -ge "$OPT_NEED_VIRT_STEP4_GB" ] && chk step4 "~$OPT_NEED_VIRT_STEP4_GB GB RAM+swap (leanchecker-paranoid)" 0 "fits by capacity (slow if swapping)" \
      || chk step4 "~$OPT_NEED_VIRT_STEP4_GB GB RAM+swap" 1 "DOES NOT FIT: $virt GB RAM+swap"
    echo "(zram counts at its configured size; the real capacity depends on the compression ratio. See verification/measurements/2026-11-22-small-scale.md.)"
    [ "$bw" = yes ] || { echo "bubblewrap missing"; ok=0; }
    [ "$ok" = 1 ]
  }
  # Swap-aware watchdog: stop only when RAM *and* swap are nearly exhausted (MemAvailable + SwapFree).
  start_monitor() {
    local name="$1" pid="$2" watch="$3" tsv="$LOGS/monitor-$1.tsv" n=0 oleans="-"
    [ -f "$tsv" ] || printf 'time\tfree_disk_gb\tmem_avail_mb\tswap_free_mb\tlean_procs\trss_mb\toleans\n' > "$tsv"
    (
      while kill -0 "$pid" 2>/dev/null; do
        local fd ma sf lp rss
        fd=$(free_gb); ma=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo); sf=$(awk '/SwapFree/ {print int($2/1024)}' /proc/meminfo)
        lp=$(pgrep -c -x lean || true); rss=$(ps -C lean -o rss= 2>/dev/null | awk '{s+=$1} END {print int(s/1024)}')
        if [ $((n % 10)) = 0 ] && [ -d "$watch" ]; then oleans=$(find "$watch" -name '*.olean' 2>/dev/null | wc -l); fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$fd" "$ma" "$sf" "$lp" "$rss" "$oleans" >> "$tsv"
        if [ "$fd" -lt "$MIN_FREE_GB" ]; then echo "DISK-LIMIT: ${fd} GB free < ${MIN_FREE_GB} GB" > "$STATE/$name.stopped"; kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; break; fi
        if [ $((ma + sf)) -lt 512 ]; then echo "MEMORY-LIMIT: MemAvailable ${ma} MB + SwapFree ${sf} MB" > "$STATE/$name.stopped"; kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; break; fi
        n=$((n+1)); sleep 60
      done
    ) &
    MONITOR_PID=$!
  }
  eval "opt_orig_cg_enter() $(declare -f cg_enter | tail -n +2)"
  cg_enter() {
    if [ "${MEM_GB:-}" = 0 ]; then echo "no cgroup memory cap (RH_MEM_GB=0): the step may use swap; the swap-aware watchdog guards the machine" >&2; return 0; fi
    opt_orig_cg_enter "$@"
  }
fi

# ---------------------------------------------------------------- standalone entry point
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  WORK="${RH_WORK:-$(dirname "$REPO")/rh-verify}"
  STATE="$WORK/state"; RES="$WORK/results"; CLEAN="$WORK/clean"; BUILD="$WORK/build"
  OPT_SWAPLIST="${WORK%/}.swaps"
  cmd="${1:-}"; shift || true
  case "$cmd" in
    storage-mount) opt_storage_mount "$@" ;;
    storage-status) opt_storage_status ;;
    storage-umount) opt_storage_umount ;;
    zram) opt_zram "$@" ;;
    swap-file) opt_swap_file "$@" ;;
    swap-compressed) opt_swap_compressed "$@" ;;
    swap-off) opt_swap_off ;;
    prune-clean) opt_prune_clean ;;
    prune-build) opt_prune_build ;;
    import) opt_import "$@" ;;
    budget) opt_budget ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
  esac
fi
