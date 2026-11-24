# riemann-hypothesis

[![checks](https://github.com/leanprover-community/riemann-hypothesis/actions/workflows/checks.yml/badge.svg)](https://github.com/leanprover-community/riemann-hypothesis/actions/workflows/checks.yml)

> **This fork** also records an attempt to run the checks on a small cloud machine, with measurements and open issues. The intent is to shift at least part of the verification burden onto AI companies, by using their own infrastructure: see [This fork](#this-fork-running-the-checks-on-a-small-cloud-machine).

A [Comparator](https://github.com/leanprover/comparator) setup and community build cache for the Lean formalization that
claims a proof of the Riemann Hypothesis, and of GRH for Dirichlet L-functions, announced on
2026-11-20 at <https://alpo.ge/remark.pdf>.

The first commit, `40e56bab`, is the submitted Lean source exactly as published. Since then,
cleanup pull requests have removed 10,724 of its 175,187 files and edited 18; the
[notes](verification/NOTES.md#source) list them. Check out `40e56bab` for the original. This
repository also adds Comparator files and cache infrastructure:

| File | What it is |
|---|---|
| [`src/Challenge.lean`](src/Challenge.lean) | the five theorems, stated in a file that imports only Mathlib |
| [`comparator.json`](comparator.json) | the Comparator config |
| [`export-targets.txt`](export-targets.txt) | the declarations to export |
| [`verification/`](verification/NOTES.md) | our notes, and the results once there are some |
| [`scripts/`](scripts/) | public Lake cache configuration and reproducible bootstrap/publishing tools |

## This fork: running the checks on a small cloud machine

This fork (`borism/riemann-hypothesis`) tries to run the "Checking it" steps 1-4 below on a
standard 4-core, 15 GB RAM, about 59 GB disk Claude cloud VM, with help from GitHub-hosted
runners. It reports what was measured. It does not say whether the claimed formalization is
correct, and no result here shows that the Riemann Hypothesis claim holds or fails: nothing from
steps 2-4 has completed. Last updated 2026-11-24 (figures as of about 00:40Z). Tracking issue:
[#1](https://github.com/borism/riemann-hypothesis/issues/1). Per-wave figures, events and sources
are in [`verification/pool-results-2026-11-24.md`](verification/pool-results-2026-11-24.md).

**Scope of the run.** The run checks upstream source commit `f1f6d654` (built as `f073285e`, which
adds only `scripts/` and `verification/`), with Lean 4.33.1 for build and export, Lean 4.36.0 for
judging and Mathlib `0df444a3`. Upstream `main` has moved on: at `c900e67c` (Lean 4.37.0-rc1)
149,215 of the 164,074 files under `src/` differ from `f1f6d654` (measured with `git diff`), and
it has moved again since. The challenge files (`src/Challenge.lean`, `comparator.json`,
`export-targets.txt`) are unchanged between the two commits (measured). **Any result of this run
says nothing about the current upstream source.** The analysis is in
[#11](https://github.com/borism/riemann-hypothesis/issues/11). Pull request
[#12](https://github.com/borism/riemann-hypothesis/pull/12) (open) adds the scope statement and a
pin guard to the driver. Pull request [#13](https://github.com/borism/riemann-hypothesis/pull/13)
(open) adds a copy of the announcement note with a factual summary; the note contains a
description and a timeline but no theorem or proof, and the Lean source is the only artifact.

**Intent.** This work aims to shift at least part of the verification burden onto AI companies, by
running the checks on infrastructure that those companies themselves provide, instead of relying
only on volunteers' machines. The commands for the parts that do not fit on a small VM (issues
[#2](https://github.com/borism/riemann-hypothesis/issues/2) and
[#3](https://github.com/borism/riemann-hypothesis/issues/3)) are written so that they can be run
on other AI companies' compute as well. So far, only Anthropic's Claude cloud VM, GitHub-hosted
runners and Hugging Face (for checkpoint storage) have been used.

Free or cheap services that might run the heavier steps (suggestions; of these, only GitHub-hosted
runners have been tried):

| Service | What it offers | Could cover |
|---|---|---|
| [Hugging Face Jobs](https://huggingface.co/docs/hub/jobs-pricing) | Pay per minute. The live list (`hf jobs hardware`, 2026-11-22) has `cpu-performance`: 32 vCPU, 256 GB RAM, 1 TB disk at $1.90/h, and `cpu-xl`: 16 vCPU, 124 GB at $1.00/h | Steps 3 and 4 fit in 256 GB. Step 2 would take about 12 h on 32 cores (reasoned from #3) |
| [Modal](https://modal.com/pricing) | A monthly free credit plus per-second CPU and memory billing (about $30 a month, from secondary sources) | Steps 3 and 4 for a few hours; the maximum memory per container was not checked |
| Kaggle notebooks and [Google Colab](https://research.google.com/colaboratory/faq.html) | Free, about 12-30 GB RAM and sessions up to about 12 h (secondary sources, unconfirmed) | Only step 2 shards (#3). Too small for steps 3 and 4 |
| [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) | Free and unlimited for public repositories. Jobs are limited to 6 h and the Free plan to 20 concurrent jobs. A standard Linux runner was reported by the run notes as 4 vCPU, 15.6 GiB RAM, 145 GB disk with 88 GB free (run 45024870099; not re-checked). Larger runners are billed | **Tried:** step 2 modules, as a pool of up to 16 parallel jobs (see "Spreading the work" below, [#9](https://github.com/borism/riemann-hypothesis/issues/9)). Step 1 (the upstream CI already does it). Not steps 3 and 4 |
| Cursor cloud agents | An isolated VM per agent, reported as 4 CPU / 15 GB / about 126 GB disk (unofficial). Needs a paid plan, billed at model API rates; the forum says there is no separate VM charge "for now" | The same size as the VM used here: step 1 and slow step 2 only |
| SpaceXAI (Grok) | No free or cheap general-purpose compute was found. The Grok API code tool is a restricted Python sandbox without persistence | Nothing |
| Other providers' coding-agent sandboxes | Limits unknown to us | Not assessed |

Whether the bubblewrap sandbox works inside the untried services is untested, and a weaker
sandbox weakens the isolation the notes require for step 2. Prices and limits change, so check
the provider's page before relying on a figure.

### Status

| Step | State | Measured, extrapolated or untested |
|---|---|---|
| 1. Export challenge | done (2026-11-22) | Measured: reproduced the README's challenge sha256, `bd484ac9...ab2b9` |
| 2. `lake build Main` (about 164,464 modules) | running since 2026-11-22T09:51Z, **not finished**. About 129,948 modules (79%) have `.olean` files in the live tree; about 94,099 of them were built on GitHub-hosted runners and merged in, the rest on the VM. About 34,500 remain, all deep in the import graph (depth 25 and above, reported by the run log) | Measured: the counts (`progress.tsv` on branch `run/step2-2026-11-22`); the split is reported by the run log. Extrapolated: 44-72 h more on the VM alone at 8-13 modules/min, if that rate holds and deeper modules are not slower |
| 3. Export solution | not run | Extrapolated from Mathlib-sized exports (about +-20%): about 42 GB memory plus swap, no margin |
| 4. `lake comparator` | not run | Extrapolated: about 131-169 GB of memory, does not fit in 15 GB. Tracked in [#2](https://github.com/borism/riemann-hypothesis/issues/2) |

There is no solution export and no Comparator output. Compressing `.olean` files with zstd gives
29-34% of raw size (31-34% on the live work directory, measured with `compsize`, reported by the
run log), so a full step 2 tree needs about 42 GB of disk compressed against about 110 GB raw.
Free root disk was about 19-21 GB on 2026-11-24.

### Where the time goes

An audit of step 2 ([#7](https://github.com/borism/riemann-hypothesis/pull/7)) found all 4 cores
busy. About half of the per-module time is Lean importing Mathlib `.olean` files. Compression,
disk IO and swap each cost under about 1%. Direct IO on the loop device made no measurable
difference. One proposed tweak (`fault_around_bytes`) could not be applied because the kernel
is in lockdown mode.

**Thrashing (measured, reported).** From about 10:00Z on 2026-11-23, with 4 concurrent Lean jobs,
the VM thrashed: about 55-65% system CPU, 15-20% IO wait and about 650 MB/s of reads from the zstd
image (reported by the run log; not in git). The build rate in `progress.tsv` fell from 22-30 to
about 4 modules/min. Modules deep in the import graph map more `.olean` files than fit in 15 GB of
RAM. Limiting Lean to 2 worker threads (`RH_LEAN_THREADS=2`, a new optional setting in
`scripts/run-verification.sh`, commit `8648c265f4d` on branch `ccr-bdb3a003-2b6l4u`) helped for a
while. After each restart the VM thrashes again for roughly an hour (cold page cache). The rate
since then was 8-13 modules/min when healthy and 0.6-6 when thrashing.

### Tooling

Nothing below is on `main`. #5 is stacked on #4 and #6 on #5; #12's base is the branch
`ccr-bdb3a003-2b6l4u`, not `main`. No pull request is merged.

| Pull request or branch | Adds |
|---|---|
| [#4](https://github.com/borism/riemann-hypothesis/pull/4) | `scripts/run-verification.sh`: a resumable driver with a bubblewrap offline sandbox and toolchain sha256 pins (`scripts/toolchain-sha256.txt`); `verification/RUN-ON-CLOUD.md`, which documents the weaker isolation compared with the podman sandbox in the notes |
| [#5](https://github.com/borism/riemann-hypothesis/pull/5) | `scripts/rh-optimise.sh`: zstd btrfs work dir, optional zram and swap, pruning, `import` of an export by sha256, measured preflight, swap-aware watchdog; measurement helpers and `verification/measurements/2026-11-22-small-scale.md` |
| [#6](https://github.com/borism/riemann-hypothesis/pull/6) | `scripts/rh-checkpoint.sh` and `rh-checkpoint-loop.sh`: checkpoint step 2 outputs to a public Hugging Face dataset (named in the script; hourly, 30 shards), with trust anchored by hashes in git |
| [#7](https://github.com/borism/riemann-hypothesis/pull/7) | the step 2 efficiency audit, `verification/measurements/2026-11-22-step2-efficiency-audit.md` |
| [#10](https://github.com/borism/riemann-hypothesis/pull/10) (draft) | tracker for the run files on branch `run/step2-2026-11-22`: `progress.tsv`, the checkpoint `INDEX.tsv`, log tails |
| [#12](https://github.com/borism/riemann-hypothesis/pull/12) | the scope statement and a pin guard for the driver (issue [#11](https://github.com/borism/riemann-hypothesis/issues/11)) |
| [#13](https://github.com/borism/riemann-hypothesis/pull/13) | a copy of the announcement note `remark.pdf` with a factual summary |
| branch `exp/gh-runners-restore-test` | the runner pool: workflows `exp-pool-wave.yml` and `exp-pool-republish.yml`, planner and merge scripts, runbook (issue [#9](https://github.com/borism/riemann-hypothesis/issues/9)). No pull request |
| branch `pool/verdicts` | the record of every wave: `verdicts/<wave>.tsv` (batch hashes and spot-check verdicts) and `stats/<wave>.json` (runner-minutes, modules). The merge step checks every hash against it. No pull request |
| branch `ccr-bdb3a003-2b6l4u` | the VM's working branch; adds the `RH_LEAN_THREADS` setting. No pull request of its own |

### Limits on what this shows

- **Pool batches were spot-checked, not independently rebuilt.** The merged modules were built on
  GitHub's machines. A seeded 5% sample of each batch was rebuilt on a separate runner and
  compared file by file. The rest was not rebuilt by anyone else, and none of it was rebuilt on
  the VM. Steps 3 and 4 still re-check every declaration with independent kernels.
- **Rejected and failed jobs.** One job was rejected by its spot-check (wave w10, 14 of 245
  sampled files differed) and one failed with no output (wave w11, cause unknown). Neither was
  merged; their modules stay unbuilt.
- **Old source only.** All results cover `f1f6d654`, not current upstream (see the scope above).
- **Checkpoint restore is not an independent rebuild.** Restoring checkpoint shards continues
  the same run. It does not rebuild the modules from source.
- **Weaker isolation.** The cloud VM and the runners use bubblewrap in a user namespace, not the
  podman sandbox described in the [notes](verification/NOTES.md). The differences are in
  `verification/RUN-ON-CLOUD.md` once #4 is merged.
- **Extrapolations.** Step 3 and 4 figures come from smaller exports, not from the solution. The
  time left for step 2 assumes the recent VM rate.

### Spreading the work over machines (tried for step 2)

Issue [#3](https://github.com/borism/riemann-hypothesis/issues/3) proposed a cluster run by
reasoning: step 2 should parallelise (about 390 core-hours with a critical path of 201 modules),
step 3 does not, and step 4 could run one kernel per node but cannot be split inside a kernel.
Step 2 on GitHub-hosted runners was then tried ([#9](https://github.com/borism/riemann-hypothesis/issues/9)):
a wave is up to 16 build jobs (500-700 modules each) plus 4 spot-check jobs and a publish job.
Each wave restores earlier accepted batches from the prerelease `pool-<wave>`. At a planned stop,
the VM merges the accepted batches into its tree by hand (about 1.5-5 minutes each, reported)
after checking every hash against the verdicts in git.

| Measured from `pool/verdicts` (waves `pilot2` and `w1`-`w13`) | |
|---|---|
| Modules accepted | 94,302 (of which about 203 had also been built by the VM, so about 94,099 are new) |
| Build jobs accepted / rejected / failed | 197 / 1 / 1 |
| Runner-minutes (build, spot, plan; not the publish job, not failed or cancelled runs) | about 7,366 |
| Full waves of 16 jobs | 8,000-11,200 modules in about 0.9-2.4 hours of wall time |
| Pool rate | about 180-205 modules per minute of wall time in w1-w2, 51-78 in w11-w13, against 8-30 for the VM |

Waves shrank early because the buildable frontier narrows with import depth (w6 had only 315
modules), and later waves were slower per module as modules got deeper. The closure check found 0
unresolved imports at every merge, and the VM did not rebuild any merged module afterwards (both
reported by the run log). The
repository's workflows were disabled by GitHub once (2026-11-23 about 00:14Z) and were re-enabled
by the owner; no reason was shown. Details and the full table are in the
[results document](verification/pool-results-2026-11-24.md).

The upstream sections below (Using the build cache, What is claimed, Checking it, License) are
unchanged.

## Using the build cache

Fetch and restore Mathlib and this project's compiled modules:

```bash
lake exe cache get
lake build --no-build
```

The cache settings are in `lakefile.toml`; no user configuration is needed. The first command
fetches both caches anonymously and extracts the oleans to `.lake/build`. It prefers a successful
CI build matching the current clean source, configuration, dependency manifest and toolchain;
documentation-only commits can reuse the same cache. Otherwise it tries the original published
cache. The second command checks the default build targets without compiling them. The original
project cache is 4.94 GB and contains portable Lean outputs and generated C. Subsequent ordinary
builds compile changed modules and their dependents.

The community cache includes outputs from **untrusted pull requests and volunteer machines**.
Download integrity checks do not verify proofs. Use an independent fresh build when you need
to trust the result.

The [cache notes](verification/CACHE.md) describe the pinned published archive, the cheaper
bootstrap that reuses its proofs, and how to produce and publish future caches. For independent
verification, follow the clean-build instructions below.

## What is claimed

| Theorem in `Main.lean` | Statement |
|---|---|
| `riemannHypothesis` | Mathlib's `RiemannHypothesis` |
| `riemannZeta_eq_zero_re` | the same, written out |
| `LFunction_ne_zero_of_half_lt_re` | L(χ, s) ≠ 0 for Re s > 1/2, for every modulus and every Dirichlet character, except the trivial character at s = 1 |
| `LFunction_eq_zero_re` | every zero of L(χ, s) with 0 < Re s < 1 has Re s = 1/2 |
| `LFunction_eq_zero_re_of_isPrimitive` | the same, for primitive characters |

## Checking it

```bash
export LEAN_ABORT_ON_PANIC=1   # as Comparator sets it: stop on an internal error, don't continue
export LAKE_ARTIFACT_CACHE=false   # rebuild the submission even if cache-env.sh was sourced earlier
export MATHLIB_CACHE_GET_URL=https://cache.mathlib.org/mathlib4   # Mathlib's current cache server

# 1. Export the challenge. Clean clone at $CLEAN, Lean v4.33.1.
cd "$CLEAN"
lake exe mathlib/cache get
lake build Challenge
lake env lean4export Challenge -- $(cat export-targets.txt) > challenge.export

# 2. Build the solution. Second clone, inside a sandbox with no network. Takes hours.
lake exe mathlib/cache get      # before entering the sandbox
lake build Main         # inside the sandbox

# 3. Export the solution. Still inside the sandbox; only solution.export comes out.
lake env lean4export Main -- $(cat "$CLEAN/export-targets.txt") > solution.export

# 4. Judge. Lean v4.36.0, from an empty directory, with the config from the clean clone.
lake comparator --config "$CLEAN/comparator.json" \
  --challenge-from-export "$CLEAN/challenge.export" --solution-from-export solution.export
```

What to know before running it:

- **Two Lean versions.** The project is pinned to Lean `v4.33.1`, and `lake comparator` exists
  only from Lean 4.35. So the proof is built and exported with `v4.33.1` and judged with
  `v4.36.0`. The exporter is [lean4export](https://github.com/leanprover/lean4export) at tag
  `v4.33.0`, built with Lean `v4.33.1`.
- **Challenge first.** Compiling the submission runs its code, so the challenge is exported
  where none of that code has been compiled. CI does step 1 on every push and publishes the
  result as the `challenge-export` artifact. Its sha256 is
  `bd484ac9886a96f26b1d9a7a59ebd45b7a70d102c015d4f31f9302bbdd6ab2b9`.
- **Not `lake exe cache get`.** In this repository that command also downloads prebuilt files
  for the submission itself, and `lake build Main` then compiles nothing. Steps 1 and 2 use
  `lake exe mathlib/cache get`, which fetches Mathlib only.
- **Cost.** Hours on a large machine, about 100 GB of disk, and a lot of memory for step 4.

The [notes](verification/NOTES.md) have the details: where the source came from, the Lean
version and its known kernel fixes, the tools, the sandboxes, the test of these steps, and the
limits of what a passing run shows.

## License

The submission belongs to its author and was published without a license. It is mirrored here
for verification only: unmodified at commit `40e56bab`, and with the changes listed in the
[notes](verification/NOTES.md#source) since.
