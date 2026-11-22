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
