#!/usr/bin/env bash
# Run CMD, and each time its heap has grown by 15% since the last sample, measure how
# well its anonymous pages compress per 4 KiB page (as zram does) with lz4 and zstd.
# The last line printed before exit is the sample nearest the peak.
#   scripts/measure-zram-ratio.sh HC_BINARY ZSTD_LEVEL -- CMD ARGS...
# HC_BINARY is scripts/heap-compressibility.c compiled (see its header).
set -u
hc="$1"; lvl="$2"; shift 3
"$@" & pid=$!
last=0
while kill -0 "$pid" 2>/dev/null; do
  a=$(awk '/RssAnon/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)
  if [ "${a:-0}" -gt $(( last * 115 / 100 + 65536 )) ]; then
    "$hc" "$pid" "$lvl" | sed "s/^/[anon ${a} kB] /" >&2
    last=$a
  fi
  sleep 2
done
wait "$pid"
