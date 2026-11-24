# Runner pool and step 2: results as of 2026-11-24

Figures as of about 2026-11-24T00:40Z. This is a factual record of what was run and measured in
this fork. **Nothing here verifies or refutes the claimed formalization.** Step 2 is not finished,
and steps 3 and 4 have not been run. Every result applies to the old source commit `f1f6d654`
only (see [What this does not show](#what-this-does-not-show)).

Each figure carries one of three labels:

- **measured**: computed for this document on 2026-11-24 from git history, files on the named
  branch, or the GitHub Actions API.
- **reported**: taken from a run log, handoff note or the owner's account, and not re-derived here.
  Many of these are not in git.
- **not checked**: stated for completeness; no source was read.

## Scope of the run

| Item | Value | Label |
|---|---|---|
| Source commit checked | `f1f6d654` (upstream), built as `f073285e`, which adds only `scripts/` and `verification/` | measured (`git diff --name-only f1f6d654 f073285e`) |
| Toolchains | Lean 4.33.1 for build and export, 4.36.0 for judging | reported |
| Mathlib | `0df444a3` (`rev` in `lake-manifest.json` at `f1f6d654`) | measured |
| Upstream `main` at the time of the decision | `c900e67c`, Lean 4.37.0-rc1, Mathlib `31ce06ea` | measured |
| Files under `src/` changed between `f1f6d654` and `c900e67c` | 149,215 modified, 15,248 deleted, 1 added, of 164,074 at `f1f6d654` | measured (`git diff --name-status f1f6d654 c900e67c -- src`) |
| Challenge files (`src/Challenge.lean`, `comparator.json`, `export-targets.txt`) | unchanged between the two commits | measured (`git diff --stat`) |
| Upstream `main` when last asked | `4d25b0ed`, not compared | measured (`git ls-remote upstream main`) |

The decision to keep checking `f1f6d654` is in issue
[#11](https://github.com/borism/riemann-hypothesis/issues/11). Pull request
[#12](https://github.com/borism/riemann-hypothesis/pull/12) (open, not merged) adds the scope
statement and a pin guard to the driver. Pull request
[#13](https://github.com/borism/riemann-hypothesis/pull/13) (open, not merged) adds a copy of the
announcement note with a factual summary.

## Where step 2 stands

| Item | Value | Label |
|---|---|---|
| Modules with `.olean` files in the live tree | 129,948 of about 164,464 (79%), at 2026-11-24T00:25:57Z | count measured (`verification/runs/20261122-step2-live/progress.tsv` on branch `run/step2-2026-11-22`); the 164,464 total is reported |
| Built on GitHub-hosted runners and merged in | about 94,099 | 94,302 accepted modules (measured, below) minus about 203 that the VM had also built (reported) |
| Built on the VM | about 35,849 | by subtraction |
| Not yet built | about 34,500, all deep in the import graph (depth 25 and above) | count by subtraction; the depth statement is reported |
| Steps 3 and 4 | not run. Step 4 does not fit on this VM (issue [#2](https://github.com/borism/riemann-hypothesis/issues/2)) | reported |

The planner's plan files (`plan.depths` in `stats/<wave>.json`) give a depth range of 1-80 for w1
and 7-125 for w13 (measured). What the planner's "depth" means exactly was not checked, so this
document makes no claim about the deepest module built.

## The runner pool

Code is on branch `exp/gh-runners-restore-test` (workflow `.github/workflows/exp-pool-wave.yml`,
scripts `scripts/exp-pool*.{sh,py}` and `scripts/rh-pool-*.sh`, notes in `verification/pool/`).
Records are on branch `pool/verdicts`. The design below is from `verification/pool/HANDOFF.md` on
the code branch (reported):

1. A **wave** is a plan job, up to 16 build jobs (500-700 modules each), 4 spot-check jobs and a
   publish job. Waves run one at a time.
2. Each build job restores the VM's checkpoint shards and the accepted batches of earlier waves
   (prereleases `pool-<wave>`), builds its slice with `lake build` inside a bubblewrap sandbox
   with no network, and packs the new files with a manifest of sha256 hashes.
3. Each spot-check job restores the same inputs, unpacks the wave's batches, deletes a seeded 5%
   sample of the outputs, rebuilds them on a separate runner and compares all 7 file types.
4. The publish job writes a verdict per job (`accepted`, `REJECTED`, `FAILED`), attaches only the
   accepted batches to the prerelease and commits `verdicts/<wave>.tsv` and `stats/<wave>.json`
   to `pool/verdicts`.
5. At a planned stop, the VM fetches the accepted batches, checks every hash against the verdicts
   in git, runs a closure check on imports and merges the files into its tree by hand (about
   1.5-5 minutes each, reported). Rejected and failed jobs are skipped and their modules stay
   unbuilt.

## Per wave

Sources: `stats/<wave>.json` and `verdicts/<wave>.tsv` on `pool/verdicts` for modules,
runner-minutes and verdicts; run start and end times from the GitHub Actions API
(`gh api repos/borism/riemann-hypothesis/actions/runs/<id>`). All measured. "Wall" is the run's
start to its last update. "Runner-min" is the sum of the plan, build and spot jobs and excludes
the publish job. "Merged" is the first progress line in `progress.tsv` whose module count
includes the wave. It is inferred by matching each jump in the count with the sum of accepted
modules of the waves in its group, because there is no merge log in git.

| Wave | Actions run | Wall (min) | Planned | Accepted | Build jobs: accepted / rejected / failed | Runner-min | Accepted modules per wall-min | Merged into the VM tree |
|---|---|---|---|---|---|---|---|---|
| pilot2 | 45036640516 | 12 | 60 | 60 | 3 / 0 / 0 | 21.0 | 5 |  |
| w1 | 45043220270 | 55 | 11,200 | 11,200 | 16 / 0 / 0 | 524.7 | 205 | by 2026-11-22T18:46:55Z |
| w2 | 45055923015 (attempt 1) | 61 | 11,200 | 11,200 | 16 / 0 / 0 | 606.9 | 184 | by 2026-11-22T20:22:56Z |
| w3 | 45066928907 | 70 | 4,968 | 4,968 | 16 / 0 / 0 | 364.8 | 71 | by 2026-11-23T00:40:47Z |
| w4 | 45073542187 | 51 | 5,638 | 5,638 | 16 / 0 / 0 | 381.9 | 111 | by 2026-11-23T00:40:47Z |
| w5 | 45078292251 | 29 | 1,721 | 1,721 | 16 / 0 / 0 | 211.3 | 59 | by 2026-11-23T00:40:47Z |
| w6 | 45080958504 | 45 | 315 | 315 | 16 / 0 / 0 | 163.8 | 7 | by 2026-11-23T00:40:47Z |
| w7 | 45157599194 | 75 | 2,800 | 2,800 | 4 / 0 / 0 | 175.6 | 37 | by 2026-11-23T16:00:50Z |
| w8 | 45171253075 | 69 | 11,200 | 11,200 | 16 / 0 / 0 | 691.6 | 163 | by 2026-11-23T16:00:50Z |
| w9 | 45182194959 | 73 | 11,200 | 11,200 | 16 / 0 / 0 | 686.0 | 153 | by 2026-11-23T16:00:50Z |
| w10 | 45194719442 | 106 | 11,200 | 10,500 | 15 / 1 / 0 | 766.4 | 99 | by 2026-11-23T17:15:22Z |
| w11 | 45226491562 | 146 | 8,000 | 7,500 | 15 / 0 / 1 | 926.7 | 51 | by 2026-11-23T19:50:40Z |
| w12 | 45252197567 | 145 | 8,000 | 8,000 | 16 / 0 / 0 | 911.6 | 55 | by 2026-11-23T22:34:18Z |
| w13 | 45276959141 | 102 | 8,000 | 8,000 | 16 / 0 / 0 | 933.6 | 78 | by 2026-11-24T00:25:57Z |
| **Total** | | | 95,502 | 94,302 | 197 / 1 / 1 | 7,365.9 | | |

Notes on the table:

- **pilot2** is a 60-module pilot. An earlier pilot (`pilot1`, run 45031028289, 3 build jobs and
  1 spot job, 60 modules) kept its batches only as Actions artifacts and is not counted
  (`legacy/pilot1.tsv`). Whether pilot2 was merged together with w1 was not checked, so its cell is
  empty.
- **w2** was published by a separate republish run (`exp-pool-republish`, run 45063849788,
  2026-11-22T19:59:39Z to 20:00:41Z) after attempt 1 failed. The wall time shown is attempt 1.
- **w7** has 4 jobs (2,800 modules). Why it was planned that small was not checked.
- Module-count jumps in `progress.tsv` against the sum of accepted modules in each merge group
  (measured): w1 +11,808; w2 +12,078 (11,200); w3-w6 +12,973 (12,642); w7-w9 +25,226 (25,200);
  w10 +10,525 (10,500); w11 +7,737 (7,500); w12 +7,827 (8,000 minus about 203 already built by
  the VM); w13 +8,029 (8,000). Each jump also holds what the VM built meanwhile.
- The total of 7,365.9 runner-minutes is about 123 runner-hours. It leaves out publish jobs and
  the failed, cancelled and plan-only runs under Events, so Actions use was higher (not summed).
  Runner-minutes per accepted module rose from 0.05 in w1 (21 modules per runner-minute) to about
  0.12 in w11-w13 (8-9 modules per runner-minute).

### Throughput

| Item | Value | Label |
|---|---|---|
| Full waves (16 build jobs) | 8,000-11,200 modules planned, about 0.9-2.4 hours of wall time (w1 0.9 h, w2 1.0 h, w8 1.2 h, w9 1.2 h, w10 1.8 h, w11 2.4 h, w12 2.4 h, w13 1.7 h) | measured |
| Pool rate, first waves | about 180-205 accepted modules per minute of wave time (w1, w2) | measured |
| Pool rate, later waves | about 51-78 (w11-w13) | measured |
| VM rate | 8-30 modules/min: 17-30 early, 8-13 when healthy later | measured (`progress.tsv`, see below) |
| Why waves shrank early | the buildable frontier narrows with import depth: w3 4,968, w4 5,638, w5 1,721, w6 315 modules | measured (counts); the cause is reported |
| Later waves were slower per module | 21 accepted modules per runner-minute in w1, 8-9 in w11-w13; modules deeper in the import graph (the cause is reported, not tested) | measured (the figures) |

The wave wall time includes the spot-check jobs, which run after the build jobs. In w11 the
longest build job took 81.0 minutes and the longest spot job 61.2 minutes (`job_minutes` in
`stats/w11.json`).

## Events

| When (UTC) | What | Source and label |
|---|---|---|
| 2026-11-22 14:06-15:20 | Pilots on the runners: pilot1 (run 45031028289) and pilot2 | measured (Actions API, `legacy/pilot1.tsv`) |
| 2026-11-22 16:07-16:19 | w1 attempt 1 (run 45042041576) ended with conclusion `cancelled` in the Actions API. The handoff notes say all 16 build jobs failed on a relative manifest path in `restore-prev` (about 75 runner-minutes); fixed in `96e4c0ee` | API conclusion measured; cause and cost reported |
| 2026-11-22 19:35-20:31 | The kill switch was set and cleared (commits `b22bf5f3`/`fd95514e` at 18:34Z, `2c167a7d`/`b7fa9f0b` at 19:39Z/20:31Z on `pool/verdicts`). A run started at 19:35:58Z was cancelled at 19:39:24Z (run 45061673613) | measured (git, Actions API); whether the cancellation was caused by the switch was not checked |
| 2026-11-22 19:36 | w2 attempt 1 (run 45055923015) finished with failure (publish step); attempts 2 and 3 failed within a minute. Commits on the code branch mention a "403 on release create" and add a republish workflow. w2 was republished at 19:59-20:00Z | measured (Actions API, git log); the 403 is from commit messages only |
| 2026-11-22 23:46 to 2026-11-23 00:14 | A wave (run 45085024081) started at 23:46:18Z. GitHub disabled the repository's workflows at about 00:14Z and the run was cancelled at 00:14:07Z. Some build jobs had finished, the rest were cancelled, and nothing was published for it. The owner re-enabled the workflows; no reason was shown | run times measured; the disabling and the missing reason are reported. Which wave name the run carried was not checked |
| 2026-11-23 02:11 | A plan-only run (45098781622): the plan job succeeded and the build, spot and publish jobs were skipped | measured (Actions API). No published wave followed until w7 at 10:36Z, about 10.8 hours after w6 ended |
| 2026-11-23 about 10:00 | The VM starts thrashing (see below) | reported; the rate fall is measured |
| 2026-11-23 12:40 | `RH_LEAN_THREADS` committed (`8648c265f4d` on `ccr-bdb3a003-2b6l4u`) | measured (git) |
| 2026-11-23 15:50-16:15 | **w10 job 2 REJECTED.** Its build step ran from 14:38:12Z to 15:50:47Z (72.6 minutes, the job 79.6 of its 90-minute limit). The workflow gives the build step an internal timeout of 72 minutes (`EXP_BUILD_TIMEOUT=72m`, `exp-pool-wave.yml`) and packs only the modules that finished. The batch has 650 of the 700 planned modules (4,550 files). The spot-check matched 231 of 245 sampled files; 14 differed. The batch was not merged | build step times and counts measured. That the timeout cut the build is consistent with these numbers but was not confirmed; why the 14 files differed is not known |
| 2026-11-23 17:07 | A second plan-only run (45224197816): plan succeeded, build, spot and publish skipped. The owner reports this was the planner bug below | run measured; link to the bug reported |
| 2026-11-23 17:19 | **Planner fix**, commit `253cd0f02e8` on `exp/gh-runners-restore-test`: merge jumps in `progress.tsv` had poisoned the VM-rate estimate, so a restarted wave found "no ready modules". w11 started 8 seconds later | commit time measured; the bug description is reported |
| 2026-11-23 17:29 to 18:43 | **w11 job 8 FAILED** with no output. Its build step started at 17:29:35Z and recorded no end; none of the later steps ran; the job ended with `failure` at 18:43:15Z (about 74 minutes later). The other 15 jobs were accepted. Not merged | step times measured; cause unknown |
| 2026-11-24 about 00:15 | The whole machine restarted. The image file survived and was remounted. Recovery, as written in `verification/pool/RUNBOOK.md` on the code branch: remount the loop image with the storage-mount command of `scripts/rh-optimise.sh`, recreate zram, count the `.olean` files, then restart the build and the checkpoint loop. The first hour after any restart is slow | reported |

## Spot-checks and determinism

| Check | Result | Source and label |
|---|---|---|
| All spot-checks in the table above | 4,757 modules sampled (4,722 of them in accepted batches, 5.0% of 94,302), 33,285 of 33,299 files identical. All 14 differing files are in w10 job 2. The failed w11 job has no sample | measured (`spot_modules` and `spot_same_files` in `verdicts/*.tsv`; each module has 7 files) |
| Runner against VM, earlier tests | 1,561 files identical (runs 45025118777, 45025916476), plus 56 files of the deepest restored modules (run 45030991469, depth 56-59) | reported (`verification/pool/HANDOFF.md`) |
| Runner against runner, earlier tests | 21 files (run 45031028289), pilot2 and 3,920 files in w1 | 3,920 in w1 and 21 in pilot2 measured; the rest reported |
| Same, in waves w2, w8, w9 | 3,920 files each, all identical | measured |
| VM against runner at the w12 merge | 1,421 files (about 203 modules) that both the VM and a runner had built were byte-identical; the merge skips them as "already present and identical" | reported (merge log; not in git) |
| Merge-time hash check | every batch hash was checked against `pool/verdicts` before merging | reported |
| Closure check at merge time | 0 unresolved imports, every time | reported |
| Modules rebuilt by the VM after a merge | none | reported |

What these show: a deterministic build gave the same bytes on different machines for the files
compared. What they do not show is that unsampled files are right. See below.

## The VM: thrashing

Source for the rates: `progress.tsv` (measured, one line per hour; the lines that contain a merge
jump are left out). The CPU, IO and read figures come from the run log and are not in git
(reported). The `monitor-step2.tsv` file in git has memory and process columns only.

| Time (UTC) | Modules per minute | Swap used (MB) | Note |
|---|---|---|---|
| 2026-11-22 12:49 to 17:56 | 17.7-25.4 | 76-1,112 | early, shallow modules |
| 2026-11-23 00:25 to 05:44 | 22.3-30.1 | 228-342 | healthy |
| 06:45 to 09:48 | 14.3-23.0 | 322-1,098 | falling |
| 10:48 | 4.0 | 1,080 | thrashing (reported to start about 10:00) |
| 11:50 | 10.0 | 2,006 | |
| 12:50 | 5.0 | 400 | after the `RH_LEAN_THREADS=2` change (commit 12:40) |
| 13:50 to 15:52 | 11.0, 12.8, 13.0 | 350-357 | healthy with 2 threads |
| 17:01 | 5.1 | 1,005 | the hour after a merge and restart |
| 18:15 | 3.2 | 410 | the hour after the next merge |
| 19:16 | 8.2 | 485 | |
| 20:51 | 8.5 | 425 | after the merge at 19:50 |
| 21:52 | 13.4 | 510 | |
| 23:34 | 0.6 | 900 | the hour after the merge at 22:34 |

Reported by the run log:

- With 4 concurrent Lean jobs from about 10:00Z on 2026-11-23, system CPU was about 55-65%, IO
  wait 15-20%, and reads from the zstd image about 650 MB/s. The rate fell from 22-30 to 2-4
  modules/min.
- Cause: modules deep in the import graph map more `.olean` files than fit in 15 GB of RAM.
- Limiting Lean to 2 worker threads (`RH_LEAN_THREADS=2`, new optional setting in
  `scripts/run-verification.sh`) stopped the thrashing for a while. After each restart it thrashes
  again for roughly an hour (cold page cache).
- The compressed work directory holds about 31-34% of the raw size (measured with `compsize`:
  about 35 GB raw `.lake/build` for 63,000 modules at the time).
- Free root disk was about 21 GB (the last `progress.tsv` line says 19 GB at 00:25:57Z, measured).

## Checkpoints

| Item | Value | Label |
|---|---|---|
| Shards on the public Hugging Face dataset (its name is the `HF_REPO` default in `scripts/rh-checkpoint.sh` on #6) | 30, with 249,774 files and 24.3 GB raw in total; the last shard is 0030 (2026-11-23T21:51Z) | measured (`verification/checkpoints/step2/INDEX.tsv` on `run/step2-2026-11-22`) |
| Frequency | about hourly | reported (`progress.tsv` has one line per hour, measured) |
| Merged pool files | kept out of the shards; they live in the `pool-<wave>` prereleases | reported |
| Trust anchor | the shard and manifest hashes in `INDEX.tsv` in git | reported |
| Draft pull request [#10](https://github.com/borism/riemann-hypothesis/pull/10) | tracks these run files | measured |

## Open pull requests and issues

Pull requests (none merged): #4 driver, #5 optimisations (stacked on #4), #6 checkpoints (stacked
on #5), #7 audit, #10 draft tracker, #12 scope statement and pin guard (its base is the branch
`ccr-bdb3a003-2b6l4u`), #13 announcement-note copy. Open issues: #1 tracker (a status comment is
refreshed about every 2 hours, reported), #2 step 4 on a big machine, #3 distributed run, #9 runner
pool, #11 upstream moved on. All measured with the GitHub API on 2026-11-24.

## What this does not show

- **Nothing about the claimed formalization.** No step that judges the proof has run. Steps 3 and
  4 have not run, and step 2 is not finished. No result here says the claim holds or fails.
- **Nothing about the current upstream source.** The results cover `f1f6d654` only. About 91% of
  `src/` has changed upstream since.
- **Not an independent rebuild of the pool's modules.** The merged modules were built on GitHub's
  machines and spot-checked on a seeded 5% sample. They were not rebuilt on the VM, and the
  other 95% were not rebuilt by anyone else. A matching sample does not show that the rest is
  right. Steps 3 and 4 still re-check every declaration with independent kernels.
- **Hash checks are not proof checks.** Checking a batch against the verdicts shows that the file
  merged is the file the runner published. It does not show how that file was produced.
- **Rejected and failed jobs.** The w10 job 2 mismatch is unexplained, and the w11 job 8 failure
  has no known cause. Their modules stay unbuilt (700 and 500 modules planned). Whether other
  accepted batches carry a similar fault that the 5% sample missed is not known.
- **Checkpoint restore is not an independent rebuild.** It continues the same run.
- **Weaker isolation.** Builds ran in bubblewrap inside a user namespace, on the VM and on the
  runners, not in the podman sandbox of the notes (`verification/NOTES.md`).
- **The timing figures describe one run.** The VM and runner rates depend on module depth, on
  the VM's page cache and on the machine restart. They are not forecasts.
- **Unchecked statements.** The GitHub workflow disabling has no reason on record. The exact
  cause of the w10 and w11 incidents, the planner's meaning of "depth", the CPU and IO figures
  and the merge-time checks were not independently checked for this document.
