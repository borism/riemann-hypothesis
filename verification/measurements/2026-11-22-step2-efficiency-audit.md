# Step 2 efficiency audit on the 4-core / 15 GB cloud VM (2026-11-22)

Run audited: `RH_OPTIMISE=1 RH_WORK=/home/user/rh-verify RH_CPUS=4 bash scripts/run-verification.sh step2`,
started 09:51:53Z (lake started ~09:55:36Z after `mathlib/cache get`). Measured 10:06-10:17Z, read-only
(`/proc` counters, `ps`, the build log, one `compsize` scan, a 71 MB zstd test on a copy in a scratch dir,
and a static parse of the `import` lines of the 164,464 sources). Nothing was signalled, reniced or
reconfigured. Early-build numbers: ~500 modules built when measured, so per-module costs will change
later (see "Import closure growth").

## Summary

The build is **CPU-bound and the CPUs are saturated**. IO, compression and swap cost less than 1% each.
About 20% of all CPU time is kernel time, almost all of it page faults from each `lean` process mapping
~6 GB of imported `.olean` files; about half of each module's CPU time is spent importing, not checking.
None of that can be removed without changing Lean. The few remaining levers are worth single-digit
percent. Projected finish at the measured rate is **about 124 h from now (~2026-11-27 14:30Z)**, plausibly
up to ~150 h (~2026-11-28 16:00Z) because modules built later import more.

## 1. CPU

`/proc/stat`, whole machine, 4 cores:

| window | user | sys | idle | iowait | steal |
|---|---:|---:|---:|---:|---:|
| 22 s (10:06:40) | 82.2% | 16.2% | 0.4% | 0.0% | 1.0% |
| 107 s (10:08) | 84.1% | 14.7% | 0.3% | 0.0% | 0.8% |
| 410 s (10:06:40-10:13:30) | 77.0% (+1.8% my niced parse) | 19.8% | 0.4% | 0.0% | 0.8% |

CPU pressure (PSI cpu some) is 35-42%: there is always runnable work waiting. Load average ~6.

Per-process accounting over 410 s (kernel threads summed by name): lake 2.8% of the machine;
btrfs kworkers (`btrfs-delalloc`, `btrfs-endio-write`, `btrfs-compressed-write`) together **0.9%**;
loop0, zram and ksoftirqd below 0.1%. So zstd:9 compression costs under 1% of the machine.

28 `lean` processes followed from start to exit (1 s polling, 100 s):

| | median | range |
|---|---:|---:|
| wall life | 6 s | 5-23 s |
| user CPU | 4.5 s | 2.7-21.1 s |
| system CPU | 1.5 s | 1.1-1.9 s |
| minor faults | ~158,000 | 150k-233k |
| peak RSS (VmHWM) | 6.5 GB | of which file-backed 6.0-6.1 GB, anon 0.44-0.53 GB |

Sum: 181 s user + 41 s sys over 232 s of process life (0.96 CPU per process): **19% of lean's CPU is
system time**. The cheapest modules take 2.7-3.4 s user + 1.1-1.5 s sys, so importing Mathlib (8,690
modules, ~6 GB mapped, ~150k faults at ~40 KB each, i.e. fault-around already at 64 KB) costs about
**4 core-seconds per module**, out of a mean of ~7.9 core-seconds measured. The lake log's own times agree:
533 modules, mean 9.1 s wall, none under 2 s.

zstd test on a copy (150 project `.olean`, 71 MB tar, single thread, 128 KB blocks like btrfs):

| level | size | CPU |
|---|---:|---:|
| zstd -1 | 32.4% | 6.5 ms/MB |
| zstd -3 | 30.7% | 10 ms/MB |
| zstd -9 | 28.8% | 30 ms/MB |

At ~22 modules/min the build writes ~2.5 MB/s before compression (olean/ilean/c/trace ~0.65 MB plus the
5.9 MB `.setup.json`, most of which reaches writeback before the 120 s deletion loop removes it). At
zstd:9 that is ~0.075 core-s/s = 0.5% of the machine, consistent with the kworker measurement. zstd:3
would save ~0.35% (~25 min over the run) and cost ~2 GB more disk on ~100 GB of olean; zstd:1 saves ~0.4%
and costs ~3.5 GB. `compress` instead of `compress-force` would let btrfs skip files whose first block
looks incompressible; olean headers trigger that, which is why the image uses `compress-force`. Not worth
changing; if desired, `mount -o remount,compress-force=zstd:3` applies to new writes without a restart.

## 2. Parallelism

- `RH_CPUS=4` is applied only as `taskset -c 0-3` (all cores of this VM). `lake build Main` runs with
  no `-j`, so Lake uses its default (hardware concurrency, 4). Observed: 3-4 `lean` processes at every
  sample, 5-9 threads each (Lean's default `--threads` = core count; no `--threads`/`-j` flag on the
  command line: `lean --tstack=400000 FILE -o -i -c --setup --json`).
- Mild oversubscription (up to ~30 lean threads on 4 cores) but no idle time and no measurable cost:
  the extra threads mostly sleep; they fill gaps during each process's serial import phase.
- More jobs would not help (CPU saturated). Memory is not what limits parallelism: anon per job is
  ~0.5 GB now, and the mapped Mathlib oleans are shared page cache.
- cgroup `rhverify-step2`: limit 13,958,643,712 B (13 GB), usage 4.0-4.8 GB, max 6.6 GB, failcnt 0,
  `memsw` unlimited (the group may swap). The cap is not limiting.

## 3. Memory

At 10:16: used 3.4 GB, buff/cache 11.9 GB, free 1.2 GB, MemAvailable 12.7 GB. Active(file) 8.7 GB,
Inactive(file) 0.8 GB, Mapped 6.5 GB, AnonHugePages 0.8 GB (THP `madvise`). zram: 41 MB stored as
11.6 MB (lz4) - only idle anon (lake's 1.1 GB RSS, shells) was swapped, 40 MB total. Swap is neither
helping nor hurting now.

Over 410 s: kswapd reclaimed 461k pages (1.8 GB), direct reclaim 86k pages (scanned 295k),
`workingset_refault_file` 460k pages (1.8 GB): page cache is already full and cycling, mostly of
written-once data (new oleans, setup.json, and the loop device's second copy of the image, see 4).
PSI memory some <0.15%: no measurable stall yet.

Note on the monitor: its `rss_mb` column (19-27 GB, more than the machine has) is the sum of RSS
including the shared mapped Mathlib oleans, counted once per process. It is not memory use.

Tuning knobs, measured effect now: `vm.swappiness` (60), `vfs_cache_pressure` (100), dirty ratios
(writes are 0.26 MB/s), zram size, btrfs `commit=`, `discard=async` (1.7 MB/s of discards, ~0 CPU):
**none can matter by more than ~0.5% now**, because there is no IO wait and no memory stall.

### Import closure growth (the real later risk)

Static parse of all imports: of 164,464 project modules, the in-flight ones import ~8,690 modules of
which only ~5 are project modules. But over a 2,000-module random sample, the project part of the
import closure is: mean 2,936 modules, median 701, p90 9,240, p99 23,147; 7% import >10,000 project
modules, 3% >20,000. At ~0.6 MB per project olean that is +1.8 GB mapped per module on average (~+30%
import work, ~+1.2 core-s/module, i.e. ~+15% total) and up to +14-20 GB for the top few percent,
which exceeds RAM: those imports will re-read and re-decompress oleans from the image. This, not
compression or IO today, is what will slow the late build, and the only remedy is more RAM.

## 4. IO

Over 410 s: vda read 1.16 MB/s, write 0.26 MB/s, 1% busy; loop0 read 1.13 MB/s, write 0.26 MB/s, 2%
busy; iowait 0.0%. The loop-on-btrfs-on-ext4 layering is not a bottleneck. loop0 has `DIO 0`
(buffered), so every block of the image is cached twice: decompressed in btrfs's page cache and
compressed in ext4's page cache of `rh-verify.btrfs.img`. Today that costs only memory (part of the
1.8 GB of refaults); later, when closures outgrow RAM, it wastes ~1/3 extra of the cache.
Image: 11 GB on disk for 24 GB of data (compsize 37% overall incl. 2.7 GB stored uncompressed),
649,399 files. Free root disk 44 GB at 10:16 (46 GB at start).

Putting only `.olean` output on the compressed image would not help speed (no IO wait) and the
sources and Mathlib cache are small; not worth the complexity.

## 5. Wasted work

| artifact | made by | needed for steps 3-4? | can it be avoided during the build? |
|---|---|---|---|
| `.setup.json` (5.9 MB each, ~970 GB written over the run) | lake, read by lean `--setup` | no | no (lean needs it as input); already deleted within ~120 s; compression cost ~0.4% |
| `.c` (`-c`, ~15 KB) and `.c.hash` | lean codegen | no | only by changing Lake's invocation; small CPU (C emission of IR that is built anyway for the `.olean`); not recommended |
| `.ilean` (29 KB) | lean `-i` | no | not without changing Lake; tiny |
| `.trace`, `.hash` | lake | needed for resume/up-to-date checks | keep |
| cleanup loop `find .lake/build/ir` every 120 s, monitor `find ... -name '*.olean'` every 10 min | driver | - | both <0.3% of one core even at 164k modules; could be lighter but not worth a restart |

After step 2, `scripts/rh-optimise.sh prune-build` already removes `.ilean/.c/.setup.json`.

## 6. Driver: what is actually active

`. "$REPO/scripts/rh-optimise.sh"` is sourced at line 458, after all functions are defined and before
`main` runs, so its overrides take effect. In the running process (`RH_OPTIMISE=1`, `RH_MEM_GB` unset):

- `free_gb`: replaced (watches the root disk holding the image: 44-46 GB). Active.
- `preflight`: replaced (measured needs). Active.
- `start_monitor`: replaced. Active: the TSV rows have 7 fields including `swap_free_mb` (8141-8191);
  the watchdog stops the build only when MemAvailable + SwapFree < 512 MB. But the TSV **header is the
  old 6-column one** from the 04:46 run (header is written only when the file is new), so every column
  after `mem_avail_mb` is mislabelled (`lean_procs` holds swap free, `rss_mb` holds the process count,
  `oleans` holds RSS; the olean count is a 7th unlabelled column). Cosmetic, but misleading.
- `cg_enter`: replaced by a wrapper that, since `RH_MEM_GB` is unset (not `0`), calls the original:
  cgroup v1 cap 13 GB is in force (memory.limit 13,958,643,712 B).
- `guard_desc` is **not** overridden, so the start message's "swap ... (not counted by the watchdog or
  the preflight)" is **wrong** for this run: both count swap.

Spurious kill risk: the watchdog needs RAM+swap below 512 MB, impossible with 12.7 GB available and 8 GB
zram free. The cgroup's OOM killer acts only if *anon* in the group exceeds 13 GB (page cache in the
group is reclaimed first); anon is ~2-3 GB with 4 jobs and should stay under ~8 GB even for the deepest
imports. Risk: low. The guard is not too conservative either. Disk: the 3 GB floor vs ~30 GB more
expected on 44 GB free leaves ~10 GB margin.

## 7. Rate and projection

| sample | modules built (lake log `Built`) | `.olean` count (monitor) |
|---|---:|---:|
| 10:05:36Z | | 280 |
| 10:07:33Z | 324 | |
| 10:16:37-43Z | 533 | 513 |

Rate: 22.8 modules/min (log, 9.2 min apart) and 21.2/min (olean count, 11 min apart), ~1,320/h; the
earlier ext4 run measured 21-27/min. Remaining ~163,900 modules: **~124 h at the current rate, finishing
~2026-11-27 14:30Z**. With the +15% import growth estimated above and slow deep modules, **~140-150 h
(~2026-11-28 06:00-16:00Z)**. Uncertain by at least ±15%: lake orders work by dependencies, and later
modules import more.

## Recommendations (ranked)

| # | change | expected gain | risk | restart? |
|---|---|---|---|---|
| 1 | Switch the loop device to direct IO: `losetup --direct-io=on /dev/loop0` (proposed, NOT applied) | removes the second (compressed) page-cache copy of the image: ~1/4-1/3 more useful cache when deep imports exceed RAM; ~0-5% late in the build, 0% now | low-medium: toggling DIO on a live loop device flushes and switches; if the ioctl fails nothing changes. Do it while watching `dmesg` | no |
| 2 | Raise page-fault fault-around: `mount -t debugfs none /sys/kernel/debug; echo 2097152 > /sys/kernel/debug/fault_around_bytes` (from 65536) (proposed, NOT applied) | fewer, larger faults for the ~150k faults/process; sys time is 19% of the build. Guess 2-6% throughput; must be measured by comparing lean `stime`/minflt before and after (the 1 s poller used here) and reverted if no gain | low: performance-only, revert by writing 65536 | no |
| 3 | Fix the driver cosmetics for the record: override `guard_desc` in rh-optimise.sh, and write a new TSV (or a new header) when the column set changes | correct logs/report; 0% speed | none | no (takes effect on the next start) |
| 4 | (optional) `mount -o remount,compress-force=zstd:3 /home/user/rh-verify` | ~0.35% CPU (~25 min), +~2 GB disk | very low | no |
| 5 | More RAM for the late phase, if the VM can be resized (e.g. 32 GB) | avoids re-reading oleans for the ~3-7% of modules importing >10-20k project modules; maybe 5-15 h saved | needs a stop/resume (resize = reboot) | yes; a restart loses only in-flight modules (≤4 x ~10 s) plus Lake's start-up re-hash of the tree (~1 min now, likely several minutes near the end), and re-reading ~6 GB of Mathlib into cache |

Not worth doing: swappiness, vfs_cache_pressure, dirty ratios, btrfs `commit=`, removing
`discard=async`, more/less zram, more lake jobs, `--threads`: all measured at or below noise now.

Best realistic improvement without a restart: **~3-10% (~4-12 h)**, mostly late in the build, and only
if items 1-2 measure as they are expected to. The build is fundamentally limited by 4 cores and by
Lean importing ~6+ GB per module.

## Considered and rejected (would change or weaken what is checked)

- Skipping or shortening proof checking: `-DdebugSkipKernelTC`, `debug.skipKernelTC`, lowering
  `maxHeartbeats`, `Elab.async=false/true` overrides, or any other change to `leanOptions` or
  `moreLeanArgs`: they change the elaboration that produces the checked environment.
- Using a community/remote Lake cache or `LAKE_ARTIFACT_CACHE=true` with downloaded artifacts: brings in
  unbuilt oleans from an untrusted source.
- Disabling the bubblewrap sandbox or network isolation to save its (negligible) overhead.
- Building with `lean` directly instead of `lake build` (skipping Lake's trace/setup work): different
  inputs from the ones Lake supplies; the notes record why that matters.
- Deleting `.olean` or `.trace` files of finished modules during the build.

## Distributed or multi-core runs (added on request)

Static import graph (from `import` lines of all 164,464 sources; Mathlib is pre-built from the official
cache): longest chain of project modules **201**; modules per depth band: 1-25: 60,217; 26-50: 41,477;
51-75: 27,832; 76-100: 22,585; 101-125: 9,943; 126-150: 2,068; 151-175: 263; 176-200: 78; 201: 1 (Main).
Depths 173-177 have a single module each. Total work ~164k x 8-9 core-s = **~390 core-hours**; critical
path 201 modules x ~10-20 s = **~35-70 min**. So step 2 is very parallel: wall ≈ 390/N h + ~1 h for N
cores, until per-node page cache (6 GB Mathlib + up to ~20 GB of project oleans per deep import) runs
out. One large machine (e.g. 64 cores / 256 GB: ~7 h) needs no new trust machinery; a cluster can work
(oleans are bit-identical across builds at the same absolute path, per NOTES.md "Comparing builds")
but sharding with Lake is **not tested**: see issue #3 (https://github.com/borism/riemann-hypothesis/issues/3) for a procedure with per-shard
duplicate builds and hash comparison.

Step 3 (lean4export of Main) is **not parallelisable**: one process, one file with global sequential
name/level/expression ids; partial exports cannot be concatenated and the comparator takes one file.
Sutherland: ~1 h 20 min, one thread, 163 GB peak. It can be run twice on separate nodes for redundancy
(the export sha256 is path-independent).

Step 4: the two external kernels and Lean's kernel are independent and run one after another; they can
run on separate machines on the same export, each with a comparator.json naming one external kernel
(wall = max instead of sum; per node ~131-169 GB RAM+swap with the comparator's retained parse).
A single kernel cannot be split by declaration range: neither leanchecker(-paranoid) nor nanoda_bin
0.4.17 has an option to trust a prefix and check a range, and every check needs all earlier
declarations. nanoda uses several threads on one machine.
