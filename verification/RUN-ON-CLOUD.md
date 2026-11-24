# Running the checks on a standard Claude cloud machine

Tracked in [issue #1](https://github.com/borism/riemann-hypothesis/issues/1). The driver is
[`scripts/run-verification.sh`](../scripts/run-verification.sh).

## Bottom line

A standard cloud machine (4 cores, 15 GB RAM, about 59 GB of free disk) **can complete step 1 only**
(export the challenge). It cannot complete steps 2, 3 or 4 of the README:

| Step | Needs (from the notes and the measurement below) | This machine | Fits |
|---|---|---|---|
| 1. Export the challenge | about 9 GB disk, under 4 GB RAM, 3 minutes | yes | yes |
| 2. Build `Main` | about 110 GB of disk at least (measured extrapolation: 130 to 155 GB); the notes' machine needed 7 to 10 hours on 48 cores | 59 GB free in total | no |
| 3. Export the solution | about 165 GB RAM and 65 GB disk (the export is 61.6 GB) | 15 GB RAM | no |
| 4. `lake comparator` | about 150 GB RAM per kernel | 15 GB RAM | no |

The RAM and step 3/4 figures are the notes' own, reported by others on large machines. They were
not measured here, and this machine could not run those steps. The step 2 figures are partly
measured; see below.

A run that stops in step 2, 3 or 4 is not a verification. Only a Comparator exit code of 0 after
a complete run of steps 1 to 4 means the solution was accepted, and even that is limited by the
points in [NOTES.md](NOTES.md#limits).

## What the script does

`scripts/run-verification.sh all` runs `tools`, `step1` to `step4` in order. Each step writes a
checkpoint under `$RH_WORK/state`, so a rerun skips finished steps and resumes `lake build`.

- **tools**: downloads the Lean 4.33.1 and 4.36.0 tarballs directly from GitHub releases (elan's
  hosts are blocked here), checks them against [`scripts/toolchain-sha256.txt`](../scripts/toolchain-sha256.txt),
  and builds lean4export at tag `v4.33.0` (`15f6055e`) with Lean 4.33.1.
- **step1**: clean clone, `lake exe mathlib/cache get` (the official Mathlib cache only; never
  `lake exe cache get`), `lake build Challenge`, export, and the sha256. It refuses to continue if
  `Main.olean` exists in that clone. Step 2 refuses to start before step 1 is done, so the challenge
  is exported before any submission code is compiled.
- **step2**: second clone, `lake exe mathlib/cache get`, then `lake build Main` inside bubblewrap
  with no network, a cleared environment, no capabilities, a read-only system and toolchain, and a
  writable build clone and tmpfs `/tmp` only. It runs on at most `RH_CPUS` cores, deletes the
  per-module `.setup.json` files as the notes advise, and stops cleanly when free disk falls below
  `RH_MIN_FREE_GB` (exit 75).
- **step3**: exports inside the same kind of sandbox, with the build clone read-only; only
  `solution.export` is written out, and its sha256 is recorded.
- **step4**: Lean 4.36.0 `lake comparator` from an empty directory, with the config and the
  challenge export from the clean clone. Output and exit code go to `results/comparator.log` and
  `results/comparator.exit`. A non-zero exit is recorded as REJECTED/FAILED, never as done.
- `preflight` compares the machine with the needs above per step, and steps 2 to 4 refuse to
  start when their own need is not met unless `--attempt-anyway` is given. `report` writes
  `results/SUMMARY.md`; `checkpoint` copies small logs and the summary into `verification/runs/` and
  pushes them. State of a half-finished build lives only in `$RH_WORK`; if the container is
  reclaimed, step 2 starts again from the beginning (step 1 takes 3 minutes).

## Isolation compared with the notes

The notes use a rootless podman container with `--network none`, `--read-only`, `--cap-drop all`
and a 440 GB memory limit. Here:

- bubblewrap (`--unshare-all`, so no network; `--cap-drop ALL`; `--clearenv`; `--new-session`;
  `--die-with-parent`) gives comparable filesystem and network isolation. `lake comparator` in step 4
  uses its own bubblewrap sandbox as in the notes.
- Weaker: the machine is one root-owned VM, the sandbox runs as root with a user namespace rather
  than as an unprivileged user, `/etc` is visible read-only, the kernel is shared, and there is no
  seccomp filter or separate memory cgroup beyond the optional cgroup v1 cap below. The notes'
  rule that tools in the work directory are rebuilt after the build is followed only for lean4export,
  which is built before step 2 from a directory the sandbox never sees; the build sandbox cannot
  write to it.
- Memory guard: a cgroup v1 memory cap when `/sys/fs/cgroup/memory` is writable, plus a 60 second
  `MemAvailable < 512 MB` watchdog. Where there is no cgroup cap, only the watchdog applies, and a
  fast allocation can still reach the kernel OOM killer. Swap (for example zram) is not a cap and
  is not counted by the watchdog or the preflight. The start line of each step says which guard is
  in effect.
- Toolchain integrity: the pins in `scripts/toolchain-sha256.txt` are the hashes of the first
  download, not independently fetched official digests (GitHub's API and release pages for
  `leanprover/lean4` were denied in the session). Compare them with the digests on the release
  pages before relying on a run.

## Network

Only `cache.mathlib.org` had to be added to the environment's allowed hosts. GitHub git access
and release downloads already worked, `bubblewrap` and `zstd` come from the apt mirror, and
`rh-cache.taucetiproject.org` (the community cache) is deliberately not used.

## Step 2 measurement (a timed trial, not a verification)

`lake build Main` in the sandbox, 4 CPUs, Lean 4.33.1, Mathlib restored from the official cache,
for 45 minutes (2026-11-22 04:46 to 05:31 UTC), then stopped by the script's timeout (exit 124,
clean). It resumed on a second 3 minute trial with the revised script. Swap was not active for
most of the trial (zram appeared at about 05:12 and was barely used).

| Quantity | Measured |
|---|---|
| Project modules built in 45 minutes | 933 `.olean` files (960 after the second trial), about 21 per minute |
| Concurrent `lean` processes | 4 |
| Disk used by build output | 875 MB for 933 modules, about 0.94 MB per module (`.olean` and `.ilean` 0.81 MB, generated C 0.016 MB, traces and hashes the rest) |
| Memory | `MemAvailable` never below 10.3 GB of 15.4 GB; summed RSS of the 4 processes up to 26 GB (shared mapped oleans are counted several times); no OOM |
| Errors | none; the warnings are Mathlib deprecations and linter output |

Extrapolating this sample, which is the first modules Lake chose and not a random sample, to the
164,464 `.lean` files of the current tree:

- **Time:** about 130 hours (5 to 6 days) on 4 cores, against 7 to 10 hours on the notes' 48 cores.
- **Disk:** about 130 to 155 GB of build output, against 59 GB free in total. With 28 GB free at
  the end of the trial and the 3 GB floor, the build would stop for lack of disk after about 26,000
  modules, roughly 16 percent, after about 20 hours.
- **Memory** for step 2 was not the limit; steps 3 and 4 are.

The extrapolation can be off by a factor of 2 either way, and individual modules vary widely. It
does not change the conclusion.

## What a result would and would not show

If all four steps ran on a machine that did fit, the result is Comparator's verdict on the export
made by Lean 4.33.1 and judged by Lean 4.36.0 with Lean's kernel, the hardened build and nanoda.
It would not cover con-leche and con-ron, which cannot check this project, and a pass by the
4.33.1 kernel alone is limited evidence (see [NOTES.md](NOTES.md#lean-version)). Results produced on
machines we do not control, including offloaded work, are unverified evidence and are labelled so
in `results/SUMMARY.md`.
