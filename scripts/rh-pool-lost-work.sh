#!/usr/bin/env bash
# Estimate the work lost if the live `lake build Main` were stopped now (issue #9 pool merges).
# Read-only: lists running lean processes (ps) and reads the tail of the step 2 log. Sends no signals.
#
#   rh-pool-lost-work.sh            print in-flight modules with their elapsed time, and a total
# Lost work = the elapsed time of every lean process now running (each module restarts from zero).
# Finished modules are kept (Lake skips them on restart). Lower is better: stop when the total is small,
# for example right after several modules finished and before a long one has run for long.
set -euo pipefail
LOG="${RH_STEP2_LOG:-/home/user/rh-verify/logs/step2-build.log}"
now=$(date +%s)
mapfile -t rows < <(ps -C lean -o etimes=,rss=,args= 2>/dev/null | sed -n 's|^ *\([0-9]*\) *\([0-9]*\) .* /home/user/rh-verify/build/src/\([^ ]*\)\.lean .*|\1\t\2\t\3|p' | sort -rn)
tot=0
printf '%-8s %-8s %s\n' elapsed rss_MB module
for r in "${rows[@]}"; do
  IFS=$'\t' read -r e rss m <<<"$r"; tot=$((tot+e))
  printf '%-8s %-8s %s\n' "${e}s" "$((rss/1024))" "${m//\//.}"
done
echo "in flight: ${#rows[@]} modules; work lost if stopped now: ${tot} core-seconds (~$((tot/60)) core-min)"
if [ -r "$LOG" ]; then
  last=$(tail -c 200000 "$LOG" | grep -oE '\[[0-9]+/[0-9]+\] Built [^ ]+ \([0-9.]+m?s\)' | tail -1 || true)
  echo "last finished (log): ${last:-none found in the last 200 kB}; log modified $(( now - $(stat -c %Y "$LOG") )) s ago"
  # typical module time from the last 200 finished modules, to judge whether a long one is about to finish
  tail -c 2000000 "$LOG" | grep -oE '\] Built [^ ]+ \(([0-9.]+)(m?s)\)' | tail -200 | sed -E 's/.*\(([0-9.]+)(m?s)\)/\1 \2/' |
    awk '{v=$1; if ($2=="ms") v/=1000; print v}' | sort -n |
    awk '{a[NR]=$1; s+=$1} END {if (NR) printf "recent modules: n=%d mean %.0f s, median %.0f s, p90 %.0f s\n", NR, s/NR, a[int(NR/2)+1], a[int(NR*0.9)]}'
fi
