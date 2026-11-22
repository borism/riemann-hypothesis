# Runner pool for step 2: handoff notes (issue #9)

Written 2026-11-22 about 19:25Z by the agent that built the pool, for whoever continues the work. The tags mean:
- **VERIFIED**: measured or observed, with a run id or file.
- **REPORTED**: from docs or from other people.
- **REASONED**: inference, not tested.

Code: branch `exp/gh-runners-restore-test`. Records: branch `pool/verdicts`. Issue: #9. All findings comments are on #9.

Status at the time of writing: wave `w2` (run 45055923015) was in progress, dispatched by hand at 18:35Z with `chain_left=6`, and started building at 18:42Z. If it succeeds, its `chain` job dispatches `w3` automatically. That self-dispatch has **not yet been observed**. The operator merged `pool-w1` into the live tree at 18:41Z and restarted the build at 18:44Z. `pool-pilot2` is **not merged** (section 3).

## 1. Architecture

```
VM (live lake build Main, 4 cores)                GitHub Actions (public fork, standard runners)
  rh-checkpoint-loop.sh  -- every ~60 min -->  HF dataset step2/step2-shard-NNNN.tar.zst + manifests
  INDEX.tsv (shard + manifest sha256) committed to branch run/step2-2026-11-22  (trust anchor)
                                                exp-pool-wave.yml (workflow_dispatch only):
                                                 plan   : kill switch, caps, rate from progress.tsv; available =
                                                          INDEX manifests (hash-checked) + accepted earlier waves
                                                          (manifests from pool-<wave> releases, checked vs pool/verdicts);
                                                          DAG from src; region planner -> slice-0..J-1, spot-0..S-1
                                                 build xJ: restore shards + earlier batches at /home/user/rh-verify/build,
                                                          lake build +slice in bwrap (no network), pack tar.zst+manifest
                                                 spot  xS: restore, unpack this wave's batches (transport-checked),
                                                          delete sample outputs, rebuild, compare 7 file types
                                                 publish : (contents: write, no Lean code) verdict per job; prerelease
                                                          pool-<wave> with ACCEPTED batches only; commit
                                                          verdicts/<wave>.tsv + stats/<wave>.json to pool/verdicts
                                                 chain   : (actions: write, no Lean code) gh workflow run next wave, or stop
VM operator (by hand, at a restart): rh-pool-fetch.sh (git verdicts + release assets, sha256) ->
  rh-pool-closure-check.py -> rh-pool-merge.sh (dry run, then --apply) -> rh-pool-postcheck.sh -> restart
```

Files and their roles:
- `.github/workflows/exp-pool-wave.yml`: the wave.
- `scripts/exp-pool-plan.py`, mode `region`: the planner.
- `scripts/exp-dag.py`: the import DAG.
- `scripts/exp-pool.sh`: runner-side build, pack, compare, prev, restore-prev and sampler.
- `scripts/exp-gh-restore-test.sh`: setup (pinned toolchain, official Mathlib cache) and restore of INDEX shards.
- `scripts/rh-pool-fetch.sh`, `rh-pool-closure-check.py`, `rh-pool-merge.sh`, `rh-pool-postcheck.sh`, `rh-pool-lost-work.sh`, `rh-pool-stop.sh`: VM side.
- `verification/pool/RUNBOOK.md`: the operator's merge procedure.

Other workflows on the branch:
- `exp-runner-facts`, `exp-restore-test`, `exp-deep-test`, `exp-merge-test`: earlier experiments.
- The upstream workflows (`checks`, `build-pr`, `publish-ci-cache`) are deleted on this branch only, so pushes here run nothing else.

Chain:
- A wave dispatched with `chain_left=N` ends with a `chain` job.
- That job dispatches the next wave (`wN+1`, `chain_left-1`) unless one of these holds: `STOP` exists on `pool/verdicts`; the plan said stop (no ready modules); any verdict row is `REJECTED` (the publish job also fails then); `chain_left` reached 1; two failed waves in a row (`fails` input).
- One wave runs at a time: concurrency group `exp-pool-wave`, `cancel-in-progress: false`. The dispatch happens in the last job of the run, so the next wave queues until the current run ends.
- Kill switch: `bash /home/user/wt-gh/scripts/rh-pool-stop.sh "reason"`, or `--clear` to remove it. It is checked in plan (start) and in chain (before dispatch). VERIFIED: set and cleared at 18:34Z, commits b22bf5f3 and fd95514e.

## 2. Assumptions and how they were checked
- **Same absolute path gives byte-identical outputs.** VERIFIED on samples:
  - runner against VM: 1,561 files (runs 45025118777, 45025916476) and 56 files of the deepest restored modules (run 45030991469);
  - runner against runner: 21 files (run 45031028289), pilot2 (run 45036640516), and 3,920 files in w1 (run 45043220270).
  - No difference was ever seen.
  - Not yet compared against the VM for any module beyond depth 59. The VM building the 3 pilot2 modules itself would be the first such comparison for pool outputs.
- **Lake accepts restored or merged trees.** VERIFIED:
  - `lake build --no-build` gave rc=0 and "All targets up-to-date" on restored shards (runs 45025118777, 45025916476) and after a merge on a runner (run 45032647693).
  - `lake build -v` rewrote 0 files.
- **The VM builds in DFS post-order from `Main`, imports in source order.** VERIFIED at 17:47Z: 6,218 (later 10,221) built modules from the VM log all sit at DFS positions ≤ 6,252 (later ≤ 10,233).
  - REASONED: this holds as long as Lake's scheduler does not change. Re-check after every restart: the merged modules are skipped, so the VM's position jumps.
- **VM rate.** VERIFIED: 17.7-25.4 modules/min in `progress.tsv`.
  - The planner used to assume 20. Since commit 99e69553 it is 25, and since 49036e98 it is the mean of the last 3 `progress.tsv` rates.
  - With 20/min, w1 started only about 4.8 h ahead instead of 8 h (VERIFIED, analysis in the #9 Stage 2 comment).
- **8 h horizon.** The planner takes modules ≥ 8 h of VM work beyond the VM's estimated position, so a 6-hourly merge is in time. REASONED.
  - The estimate is the highest DFS position in INDEX plus rate x minutes since the last shard.
  - `merge_by_utc` in `plan.json` and `stats/` is the time the VM would reach the wave's first module.
- **Slices are closed under imports.** Each unbuilt import of a picked module is in the same job, so no module is built twice.
  - VERIFIED: 0 modules built outside the slice (w1 build logs). Simulation: 0% duplication, against 78% for contiguous DFS chunks.
  - Caveat: "available" includes earlier pool waves. Merges must therefore include all earlier waves (section 3).
- **700-module cap.** VERIFIED: w1 jobs took 21.5-34.4 min of build for mostly shallow modules (depth median 3, max 80).
  - The build step has a 72 min timeout. On timeout, the modules with all 7 files are packed (added in e7ca7959, untested).
  - REASONED: deeper regions will be slower per module.
- **Runner hardware.** VERIFIED (run 45024870099): Ubuntu 26.04, 4 vCPU (EPYC 7763), 15.6 GiB RAM, 3 GB swap, 145 GB disk with 88 GB free (121 GB after deleting toolchains), bwrap works unprivileged.
- **Restore cost.** VERIFIED:
  - INDEX shards: 3 in 27-41 s, 5 in 40-49 s, 6 in 47 s.
  - The 16 w1 batches (1.5 GB) in 24 s (w2 build job 2, run 45055923015).
  - Toolchain plus Mathlib: 65-100 s.
  - Checkout of the clone: 60-85 s.

## 3. Bugs and surprises (all fixed unless noted)
| what | effect | fix (commit) |
|---|---|---|
| A workflow `run: { … }` was parsed as a YAML mapping | workflow invalid, run failed at once | plain string (4fe1d223) |
| `restore-prev` used a manifest path relative to the wrong directory | w1 attempt 1 (run 45042041576) failed in all 16 build jobs, about 75 runner-min | `realpath` (96e4c0ee) |
| `if: always()` jobs still run after a cancel | spot jobs ran after cancelling | `if: ${{ !cancelled() && … }}` (96e4c0ee) |
| Push trigger on wave file re-ran default waves | risk of accidental waves | workflow is dispatch-only (e7ca7959) |
| A push touching `exp-gh-restore-test.sh` also triggered `exp-restore-test.yml` (paths filter) | 1 unneeded run, cancelled (45030989532) | be careful with paths filters |
| Merge script: path regex rejected non-ASCII module names (`₂`), and `tar -t` escaped them | w1 merge would have been refused; found in the scratch rehearsal | `[^\t]+` plus traversal and control-character checks; `tar --quoting-style=literal` (8bf1a0e1) |
| Merge script: dry run exited 1 after a successful run (`[ ] && …` as the last command under `set -e`) | false failure | `if` (bf5abcc3, 8bf1a0e1) |
| Merge script: one process per file; slow under load | 2 batches took >2 min at nice 19 | bulk `cp --parents`, one `sha256sum -c` for existing files (8bf1a0e1) |
| Artifacts cannot reach the VM | the blob host changes per artifact (`productionresultssa2`, `productionresultssa14`) and the VM proxy refuses it | transport via prereleases (`release-assets.githubusercontent.com` works) |
| **pilot2 never merged; w1 depends on 3 pilot2 modules** (`GroundTheory.GlobalFields.SUnits`, `SUnitsKernel`, `…GaloisModules.CoeGalRootsOfUnityHomApply`) | after the w1 merge, Lake `--no-build` rc=3 on the live tree (operator) | merge every unmerged wave oldest first; `rh-pool-closure-check.py`; `depends_on_waves` in `plan.json` (04ffcceb). **pilot2 is still unmerged**: the operator decides whether to merge it at the next restart or let the VM build the 3 modules |
| Operator found: the loop pid via `pgrep -f rh-checkpoint-loop.sh` can be a wrapper shell, and `/home/user/wt-run` has no `scripts/` | runbook commands wrong | anchored `pgrep -f '^bash scripts/rh-checkpoint-loop.sh'`; restart the loop from `/home/user/riemann-hypothesis` (04ffcceb) |
| First planner `deep` mode computed full closures for 52k modules on the VM | CPU use on the VM; stopped after 2 min | early cut-off; keep heavy analysis on runners |
| `sampler` RSS of `lean` counts shared mmapped .olean pages | "sum lean RSS" of 28-31 GB while used RAM was 6 GB | look at used RAM and swap, not RSS |
| The per-module max-time statistic compared strings | wrong "max" in early logs | numeric (0bd4d90a) |
| `/usr/bin/time` around bwrap reports only about 7 MB RSS | useless numbers | sampler instead |

## 4. Measurements (VERIFIED unless marked)
| run | what | result |
|---|---|---|
| 45024870099 | runner facts | 1.6 min |
| 45025118777 / 45025916476 | restore 2 shards + rebuild 23 / 200 modules | 5.8 / 11.5 min; 161 / 1,400 files identical to the VM; 4 GB RAM |
| 45030991469 | deep test | 8 deepest restored (depth 56-59) identical; 436-module closure of two depth-80 modules in 31 min (14/min), RAM 6.0 GB, swap 0.7 GB; import-all probe 9.4 GB RSS |
| 45031028289 | pilot1, 3+1 jobs, 60 modules | 13.5 min; accepted (batches as artifacts only; `legacy/pilot1.tsv`) |
| 45032647693 | merge test on a runner | tampered batch refused; 420 merged; `--no-build` rc=0 |
| 45036640516 | pilot2, 3+1, 60 modules | 12.2 min wall, 21 runner-min; release `pool-pilot2` |
| 45042041576 | w1 attempt 1 | failed (restore-prev bug), about 75 runner-min |
| 45043220270 | **w1, 16+4, 11,200 modules** | 54 min wall; build jobs 24.6-38.5 min; restore of 5 shards 40-49 s; RAM ≤ 5.9 GB, swap 0, disk ≥ 64 GB free; spot 3,920/3,920; 525 runner-min; **207 modules/min = 8.2x the VM (25.4/min)**; release 1.55 GB (34 assets) |
| 45055923015 | w2, 16+4, chain_left=6 | running at the time of writing |

Total Actions use so far: about 13 runner-hours (REASONED from the per-run sums).

## 5. Open questions and risks for w2..w7
- **Self-dispatch is untested.** If `gh workflow run` from the `chain` job fails (permissions, inputs), the chain just stops after w2. Watch for `w3` in the run list about 1 min after w2's publish.
- **The new code in w3+ is untested in Actions:** `depends_on_waves`, `closure_unavailable`, the fail-on-outside-slice guard (commit 04ffcceb). I tested the planner change locally only. A crash in plan counts as a failed wave: the chain retries once with the next wave name, then stops.
- **Deep modules:** nothing above depth 80 has been built on a runner. RAM for p99 closures is untested (REASONED: about 27 GB mapped, which means page-cache thrashing on 15.6 GiB, not necessarily OOM). Later waves move deeper.
- **Restore growth:** each wave adds about 1.5 GB of releases that every later job downloads and unpacks. That is fast so far (24 s for 1.5 GB), and REASONED to be fine for 6 waves (about 9 GB, about 30 GB raw on a 75 GB-free disk). Beyond that, extract only each job's import closure.
- **Release storage:** about 1.5 GB per wave. GitHub has no stated total cap per release (REPORTED: 2 GiB per asset). Watch it.
- **Duplicate work with the VM:**
  - zero so far (VERIFIED for w1 at 17:47Z);
  - grows if merges are late: about 2% at 6 h and 6% at 8 h after a wave (REASONED);
  - after each restart the VM jumps over merged modules;
  - unmerged pilot2 modules will be built by the VM around DFS 15,800.
- **Merge order:** pilot2 -> w1 (done) -> w2 -> … Every wave depends on all earlier ones.
- **Usage policy:** REPORTED. The terms forbid "disproportionate burden" and give no number. The owner accepted the risk.
- **Concurrency:**
  - our maximum is 16 at once (builds, then spots), which leaves 4 of the Free plan's 20 for the upstream `checks` runs;
  - beyond that, jobs queue (delay, not failure) (REASONED from GitHub docs, REPORTED limit);
  - a queued build job cannot fail its wave by queuing, but queue time can push a job toward its 90 min `timeout-minutes`, which counts from start, not queue (REPORTED behaviour).
- **Planner position estimate:** it uses the INDEX lag times a rate. After a merge plus restart, the VM's actual DFS position runs ahead of INDEX's highest position until the next shard. REASONED: conservative, in that the horizon is larger than needed.

## 6. Cheat sheet
- **Status:** run list of `exp-pool-wave.yml` (MCP `actions_list list_workflow_runs resource_id=exp-pool-wave.yml`). Per wave: `git -C /home/user/wt-gh fetch -q origin pool/verdicts && git show FETCH_HEAD:stats/w2.json`. Verdict rows: `git show FETCH_HEAD:verdicts/w2.tsv` (column 8 is `accepted`, `REJECTED` or `FAILED`).
- **Merge deadline:** `merge_by_utc` under `plan` in `stats/<wave>.json`. w1 was about 22:35Z (already merged).
- **Merge order:** all `verdicts/*.tsv` waves not yet merged, oldest first. Check with `rh-pool-closure-check.py` (RUNBOOK step 0).
- **Stop the chain:** `bash /home/user/wt-gh/scripts/rh-pool-stop.sh "reason"`. The running wave finishes and no new wave starts. To stop at once, also cancel the run.
- **Clear the switch:** `--clear`, then dispatch a new chain by hand, e.g. wave `w8`, jobs 16, cap 700, spot_jobs 4, horizon_h 8, chain_left 6, fails 0.
- **Fetch / dry run:** `nice -n 19 bash scripts/rh-pool-fetch.sh /home/user/pool-in pilot2 w2`, then `RH_WORK=/home/user/rh-verify bash scripts/rh-pool-merge.sh /home/user/pool-in/w2/verdict.tsv /home/user/pool-in/w2` (dry run by default).
- **Rehearse:** only under `/home/user/pool-scratch` with `RH_WORK=/home/user/pool-scratch` (`RH_POOL_SCRATCH=1` for `--apply`; it is refused for the live path). Delete the scratch tree afterwards.
- **NEVER on the live tree or processes** (an agent; only the operator does merges and restarts by hand):
  - no `--apply`, no writes under `/home/user/rh-verify`;
  - no signals or renice to `run-verification.sh`, `lake`, `lean`, `rh-checkpoint-loop.sh`, `wait-step2.sh`;
  - no edits in `/home/user/riemann-hypothesis`, `/home/user/wt-run`, `/home/user/wt-pr`, `/home/user/wt-readme`, `/home/user/rh-logs`;
  - nothing CPU-heavy on the VM (DAG parse at nice 19 / ionice idle is the most I ran, about 80 s);
  - push only to `exp/…` and `pool/verdicts`;
  - post only on #9.

## 7. What I expect to go wrong next, and what I would do
1. **The chain stops after w2** because the self-dispatch fails, or because the untested plan code from 04ffcceb crashes in w3. Look at w2's `chain` job log and w3's `plan` job log. A crash is cheap: the plan job fails before any build starts, and the chain retries once and then stops.
2. **Merge mistakes on the VM:**
   - forgetting pilot2 or the oldest-first order;
   - forgetting to stop the loop before the build;
   - forgetting runbook step 5.

   The closure check and postcheck catch the first two. Keep the operator on the runbook.
3. **Later waves get slower** (deeper modules) and hit the 72 min build timeout. The partial-pack path then runs for the first time. The fallback is to lower `cap` to 400-500.
4. **The VM rebuilds the 3 pilot2 modules with different bytes** (no difference seen so far). Lake would then rebuild the 3 dependent w1 modules: safe, but it would be the first determinism failure. Compare the VM's files with the `pool-pilot2` manifests once it has built them.
