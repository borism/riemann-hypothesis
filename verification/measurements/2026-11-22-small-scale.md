# Small-scale measurements on the standard cloud VM (2026-11-22)

Machine: 4 cores, 16 GB RAM (15 usable), zram 8G lz4 swap (added by the coordinator), ext4 root
with ~59 GB for this work, shared. Tools: Lean 4.33.1 / 4.36.0 official tarballs, lean4export
v4.33.0 (15f6055e). Peak memory from scripts/measure-peak.py (anon = heap, file = mmapped).

## Build (step 2), first 627 modules of `lake build Main` (shared run in /home/user/rh-verify)

| artifact | files | total | average |
|---|---:|---:|---:|
| .olean | 627 | 379.4 MB | 605 KB |
| .ilean | 627 | 18.4 MB | 29 KB |
| .c | 627 | 9.3 MB | 15 KB |
| .trace | 627 | 2.7 MB | 4 KB |
| .setup.json (not yet deleted) | 29 | 171.6 MB | 5.9 MB |

Rate: ~27 modules/minute on 4 cores (553 .olean after 20 min, 625 after 23 min).
Per lean process: ~0.2-0.6 GB private (anon), ~6 GB shared clean (mmapped Mathlib .olean).

Olean compressibility (200 project .olean, 84 MB): zstd-1 2.9x/3.1x stream; on a btrfs loop
mount with compress-force: zstd:1 34%, zstd:9 33%, zstd:15 31% of original size.
Write time for 84 MB: zstd:1 0.6 s, zstd:9 1.9 s, zstd:15 11 s (single stream).

## Export (step 3 analogue) and checkers (step 4 analogue)

| run | export | lines | wall | peak anon | peak file |
|---|---:|---:|---:|---:|---:|
| lean4export Challenge (README targets) | 350,862,311 B (sha256 bd484ac9…, matches README) | 6,495,712 | 172 s* | 0.64 GiB | 5.17 GiB |
| lean4export Mathlib, 10 Mathlib theorems | 651,142,904 B | 12,104,368 | 110 s* | 0.84 GiB | 5.28 GiB |
| leanchecker-paranoid --from-export challenge | | | 89 s* | 0.60 GiB | 0.01 GiB |
| leanchecker --from-export challenge | | | 77 s* | 0.51 GiB | 0.07 GiB |
| nanoda_bin challenge (stops at sorryAx, expected) | | | 28 s* | 0.39 GiB | |

*while 4 build jobs were running on the same 4 cores.

Challenge export line mix: app 5,049,614 (avg 48 B), ie other 552,050, forallE 373,442,
names 329,321, const 136,992, thm 40,431, def 10,238.

## Checker and exporter heap, per line, and how it compresses

On the 12.1M-line Mathlib export (all three checkers accept it). Ratio = per 4 KiB page, as zram
compresses, over the non-zero heap pages near the peak (scripts/heap-compressibility.c).

| program | peak heap | heap per line | lz4 | zstd-3 | estimate for the solution (1.14e9 lines) |
|---|---:|---:|---:|---:|---:|
| leanchecker-paranoid (4.36.0) | 1.11 GiB | 98 B | 2.33 | 3.64 | ~112 GB |
| leanchecker (4.36.0) | 0.93 GiB | 82 B | 2.49 | 4.05 | ~93 GB |
| nanoda_bin (4.36.0, 4 threads) | 0.73 GiB | 65 B | 1.65 | 2.30 | ~74 GB |
| lean4export (4.33.1) | 0.84 GiB (0.47 GiB = imported Mathlib) | 33 B above the environment | 1.74* | 2.75* | ~38 GB + environment of Main |

*the growth between two samples (the expression table), not the environment, which compresses
3.3x (lz4) / 5.1x (zstd).

The solution's line count: 61,570,595,788 B / 54 B per line = 1.14e9 (54.0 and 53.8 B per line
in the two exports measured here).

Export at rest: btrfs compress-force zstd:3 18%, zstd:9 14%; zstd -3 stream 16.9%.

## Swap experiments (cgroup v1 memory limit, cgroup OOM killer disabled)

leanchecker-paranoid on the challenge export (needs ~0.58 GB):

| limit | RAM:need | swap device | result | wall |
|---|---|---|---|---:|
| none | | | accepts | 89-130 s (busy machine) |
| 400 MB | 1:1.5 | zram lz4 | accepts | 133 s |
| 200 MB | 1:2.8 | zram lz4 | accepts | 177 s |
| 200 MB | 1:2.8 | loop over a file on btrfs zstd:1 (compressed disk swap) | accepts | 234 s; swap file stored at 41% |
| 85 MB | 1:7 | zram lz4 | ENOMEM after 312 s | |

With the cgroup's OOM killer left on, small cgroup-v1 limits kill Lean at once instead of swapping
(seen at 150-250 MB); the 1:7 failure is the same artefact. A real run uses no cgroup cap
(`RH_MEM_GB=0`) and global memory pressure instead, which these tests do not reproduce.

## What each optimisation costs in trust

| optimisation | changes what is checked? | weakens isolation? |
|---|---|---|
| btrfs zstd loop image for the work dir | no: files read back bit-identical; exports are sha256-hashed | no: sandboxes bind the same paths |
| deleting the clean clone's `.lake` after step 1 | no: step 4 reads only comparator.json and challenge.export | no |
| `.setup.json` deletion during the build (notes' loop) | no | no |
| deleting `.ilean`/`.c` after step 2 | no: the exporter reads only `.olean` | no |
| zram / swap file / compressed swap | no: changes speed and capacity only | no; compressed swap risks a hang under extreme pressure, not a wrong verdict |
| no cgroup cap (`RH_MEM_GB=0`) | no | the machine-wide watchdog (MemAvailable+SwapFree) is the only memory guard |
| importing an export made elsewhere (`rh-optimise.sh import`) | the export is accepted only with the expected sha256 | the step that made it was not run under this script; labelled IMPORTED in the report |
