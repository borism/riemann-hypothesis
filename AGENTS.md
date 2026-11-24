# AGENTS.md

Guidance for AI agents (and people) working in this repository. Read it before changing anything.

## What this repository is

A fork of `leanprover-community/riemann-hypothesis`: a Lean 4 [Comparator](https://github.com/leanprover/comparator)
harness for a claimed formalization of the Riemann Hypothesis and the generalized Riemann Hypothesis
(announced 2026-11-20). The submission's own files are under `src/` (164,464 modules). The five challenge
statements are in `src/Challenge.lean` (each `by sorry`, on purpose); `comparator.json` allows only `propext`,
`Quot.sound` and `Classical.choice`.

The checking steps are in `README.md` ("Checking it"): 1 export the challenge, 2 `lake build Main` offline,
3 export the solution, 4 `lake comparator`. This fork exists to run them on cloud machines and on free or cheap
AI-company infrastructure.

## Rules that matter most

1. **Never claim a result that has not been produced.** Nothing here is verified until step 4 passes. Say what was
   run, on which source and toolchain, and what is still open. Do not write "verified", "proved" or "checked" about
   the submission on the strength of a build, a grep, or a reading of the source.
2. **Say which source a result covers.** The long-running build is of an older source (`f1f6d654`, built as
   `f073285e`) with Lean 4.33.1 (build and export) and 4.36.0 (judge) and Mathlib `0df444a3`; upstream has moved on
   (Lean 4.37.0-rc1). Label every status, issue comment and README line with the source it covers. See issue #11.
3. **Do not touch the live checkout while a build runs.** If `scripts/run-verification.sh step2` is running, do not
   pull, merge, checkout, rebase or edit files in the checkout it was started from. Use a separate `git worktree`
   (sparse if you only need a few files).
4. **Do not run a second Lean build on the build machine.** It has 15 GB of RAM and thrashes with more than 2 Lean
   threads (`RH_LEAN_THREADS=2`). Heavy reads, greps over the whole tree, and `lake` runs wait or go to a rented
   machine. Use `nice -n 19 ionice -c3` for anything big.
5. **No secrets** in files, commit messages, issue text, chat or logs. Credentials go through the environment's
   secret mechanism, never into the repository.
6. **Do not post or upload on your own.** Nothing goes to GitHub issues, pull requests, Hugging Face or any
   outside service unless the owner asked for that action. Reports an agent writes stay local until the owner has
   read them. Do not open a pull request unless asked; do not merge one unless asked.
7. **Keep personal details out of outside requests** (names, e-mail addresses, project names in URLs, headers or
   payloads).
8. **Do not weaken a check to get green:** no skipped or disabled tests, no editing `comparator.json` or the
   statements in `src/Challenge.lean`, no changing which axioms are allowed.

## Where things live

| Thing | Where |
|---|---|
| Challenge statements, allowed axioms | `src/Challenge.lean`, `comparator.json`, `export-targets.txt` |
| Notes on the source, scans, the build | `verification/NOTES.md` |
| Build cache design | `verification/CACHE.md`, `verification/PORTABLE-CACHE.md`, `scripts/` (`cache-*`, `ci-*`) |
| Running the build on a cloud VM | `verification/RUN-ON-CLOUD.md`, `scripts/run-verification.sh`, `scripts/rh-optimise.sh` |
| Hourly checkpoint to Hugging Face and git | `scripts/rh-checkpoint.sh`, `scripts/rh-checkpoint-loop.sh` (branch `run/step2-*`: `INDEX.tsv`, `progress.tsv`) |
| After a machine restart | `scripts/rh-recover.sh` |
| Watching the run | `scripts/rh-watch.sh` |
| The runner pool (waves of GitHub-hosted builds) | branch `exp/gh-runners-restore-test`: `.github/workflows/exp-pool-wave.yml`, `scripts/rh-pool-*.sh`, `scripts/exp-pool-plan.py`, `verification/pool/RUNBOOK.md` |
| Pool verdicts and hashes (the trust anchor) | branch `pool/verdicts`: `verdicts/<wave>.tsv`, `stats/<wave>.json` |
| Accepted pool batches | prereleases `pool-<wave>` of this repository |
| Build outputs of the VM | Hugging Face dataset `bmaryshev/riemann-hypothesis-build-checkpoints` (public) |

Branches: `main` is the fork's public face (README and results documents). The branch the build machine runs from
and the pool branches carry the scripts; a script mentioned above may exist only on that branch.

## Working on a running build

- `.olean` files record absolute paths, so every node builds at `/home/user/rh-verify/build`. Do not move the tree.
- After a machine restart the loop-mounted image and the swap are gone, but the image file on the root disk
  survives. Run `scripts/rh-recover.sh` (it mounts, adds swap, then starts the build and the checkpoint loop, in
  that order). Do not start the build before the image is mounted.
- Run the watcher in the background and re-run it after each exit:
  `RH_POOL_REPO=<checkout> scripts/rh-watch.sh`. It exits at once on a finished run, a stopped build, a restart or
  low disk, and otherwise after 50 minutes with a heartbeat line. Do not start it with a trailing `&` from a
  background shell call: it then returns immediately and gives no heartbeat.
- Merging a pool wave into the live tree stops the build for a few minutes. Follow
  `verification/pool/RUNBOOK.md` exactly: fetch to a scratch directory, closure check, dry run, wait for the lost
  work to be small, stop the checkpoint loop and then the build, merge, post-check, restart both. Do it only for
  batches the spot-check accepted, and never for a rejected or failed job.
- Spot-check rejections, disabled workflows and a changed `merge_by_utc` deadline are things to report to the owner,
  not to work around.

## Reading the submission

Static reading of the Lean source is useful but does not replace the Comparator run. When auditing claims about
the formalization, check what the five theorems actually depend on (a structure field or a `def` that the final
theorems cannot avoid must have been proved to build the instance; one they never use is irrelevant to them), grep
for `sorry`, `axiom`, `native_decide`, `unsafe`, `opaque`, `implemented_by`, `@[extern]`, and cite file and line.
Say what you could not check.

## Style of work here

- Prefer small, reviewable pull requests against the branch the owner names; mirror the repository's PR template if
  there is one.
- Commit messages say what changed and why.
- Record state that a future session needs (what is running, what was decided, what is pending) in a file in the
  work area, not only in chat.
