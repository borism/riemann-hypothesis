# Merging runner-pool waves into the live step 2 build (runbook, issue #9)

Run these commands by hand, as root, on the VM that runs the live build. Nothing here runs automatically.
Each step says what to expect; **stop at the first surprise** and use the rollback at the end.
Rehearsed on a scratch tree, not on the live tree. The rehearsal used real `pool-w1` and `pool-pilot2` assets; see "Rehearsal".

Variables used below:

```bash
WAVE=w1                                    # the wave to merge (one or more: WAVES="w1 w2")
POOL=/home/user/wt-gh                      # checkout with the pool scripts (branch exp/gh-runners-restore-test)
IN=/home/user/pool-in                      # downloaded release assets (root disk, about 1.6 GB per full wave)
LOGS=/home/user/rh-logs
STAMP=$LOGS/pool-merge-$WAVE.stamp
LIST=$LOGS/pool-merged-$WAVE.list
B=/home/user/rh-verify/build/.lake/build
cd "$POOL" && git pull -q --ff-only        # current scripts
```

## 0. Before the window (the live build keeps running)
**Merge every accepted wave that is not yet in the tree, oldest first** (`pilot2`, `w1`, `w2`, …; `legacy/` is not a
wave). A wave builds on the modules of all earlier waves (see `depends_on_waves` in `stats/<wave>.json`); merging a
wave without its predecessors leaves imports that the VM must build itself (this happened with `w1` without
`pilot2`: 3 modules). The merge is idempotent, so re-merging an already merged wave changes nothing.
Check the closure before the window (read-only; the DAG is built from the same sources in the pool checkout):

```bash
nice -n 19 python3 -I $POOL/scripts/exp-dag.py $POOL/src /tmp/pool-dag.tsv      # about 80 s; src = live commit's src
nice -n 19 python3 -I $POOL/scripts/rh-pool-closure-check.py /tmp/pool-dag.tsv $B $IN/*/*-manifest.tsv
#  expect "unresolved imports: 0" (exit 0). Anything listed is a module neither in the tree nor in the batches.
```

Fetch and verify the assets first, so the build is stopped only for the merge itself.
This uses only the network: git fetch of `pool/verdicts`, then `github.com` → `release-assets.githubusercontent.com`.

```bash
nice -n 19 bash $POOL/scripts/rh-pool-fetch.sh $IN $WAVE
#  expect one line per job: "w1 job N: tar + manifest fetched, sha256 matches git (4900 files)"
#  it stops with "sha256 differs from the verdict in git (refusing)" if any asset does not match
RH_WORK=/home/user/rh-verify nice -n 19 bash $POOL/scripts/rh-pool-merge.sh $IN/$WAVE/verdict.tsv $IN/$WAVE
#  DRY RUN (the default): writes nothing. Expect "verified: 4900 files, 4900 new, 0 already present"
#  for each of the 16 jobs, then "total: 78400 files in accepted batches, 0 already present; dry run, nothing written".
#  "already present" > 0 means the VM built some of these modules itself; such files must be identical, otherwise the batch is refused.
```

## 1. Choose the moment
```bash
bash $POOL/scripts/rh-pool-lost-work.sh
#  lists the lean processes in flight with elapsed seconds, and "work lost if stopped now: N core-seconds".
```
Stop when that total is small, for example under about 60 core-seconds. Typical modules take 10 s (median) or 20 s (p90).
Do not stop while a module has been running for minutes; wait for it to finish. Lost work is at most what is in flight; finished modules are kept.

## 2. Stop the checkpoint loop, then the build
Stop the **checkpoint loop first**. If it woke up during the merge, it would upload a half-merged tree as a VM shard. Also, as soon as it sees the driver gone, it runs one last pass and exits.

```bash
LOOP=$(pgrep -f '^bash scripts/rh-checkpoint-loop.sh'); echo "loop pid $LOOP"   # not a wrapper shell
ps -o pid,stat,etimes,args -p "$LOOP"                       # normally state S (sleeping)
pgrep -f 'rh-checkpoint.sh push' && echo "A PUSH IS RUNNING: wait until it finishes" # do not stop the loop mid-push
kill -TERM -- -"$(ps -o pgid= -p "$LOOP" | tr -d ' ')"      # the loop runs in its own process group (setsid)
sleep 2; pgrep -f 'rh-checkpoint-loop.sh' || echo "loop stopped"
```

Then the build. Use the same signal the driver's own disk and memory watchdog sends: TERM to the step's process group. That group is the outer `bwrap`, started with `setsid` by the driver.

```bash
D=$(pgrep -f -o 'run-verification.sh step2'); echo "driver pid $D"
G=$(pgrep -P "$D" -x bwrap); echo "step process group $G"   # the outer bwrap is the group leader
date -u; bash $POOL/scripts/rh-pool-lost-work.sh | tail -2   # record what is lost
kill -TERM -- -"$G"
while pgrep -f 'run-verification.sh step2' >/dev/null; do sleep 2; done
tail -3 /home/user/rh-verify/logs/run.log
#  expect: "step2: stopped by timeout/TERM (rc=143); resume by re-running" (the driver exits with 75)
pgrep -x lake || pgrep -x lean || echo "no lake/lean left"
```

Note: the parent's watcher (`wait-step2.sh`) will report "DRIVER GONE". That is expected.

## 3. Merge
With several waves, run this step once per wave, oldest first, each with its own `LIST`
(`for WAVE in pilot2 w1 w2; do …; done`); fetch them all in step 0 (`rh-pool-fetch.sh $IN pilot2 w1 w2`).

```bash
touch "$STAMP"; sleep 1
RH_WORK=/home/user/rh-verify RH_POOL_MERGED_LIST=$LIST \
  bash $POOL/scripts/rh-pool-merge.sh $IN/$WAVE/verdict.tsv $IN/$WAVE --apply
#  refuses if lake build Main or the checkpoint loop is still running.
#  per batch: "verified: …", "merged N files"; at the end "merged files listed in $LIST (N lines)".
#  any refusal (hash, path, conflict with an existing file): stop here and go to Rollback.
```

The merge is checked twice: once against the git verdict (the tar and manifest sha256), then every unpacked file against its manifest. After copying, every file in the live tree is checked against the manifest again.

Expected duration [rehearsal]: 73 s for 2 batches (9,800 files) at nice 19 while the live build held all 4 cores. With the build stopped, expect roughly 2-5 min for all 16 batches [reasoned].

## 4. Checks after the merge (build still stopped)
```bash
RH_WORK=/home/user/rh-verify bash $POOL/scripts/rh-pool-postcheck.sh "$STAMP" "$LIST" $IN/$WAVE
#  expect: "files changed since the stamp: N; merged list: N; changed but not merged: 0; merged but not changed: 0",
#          "sha256 of all N merged files match their manifests", "merged modules: M", "OK"
#  "changed but not merged" > 0 means something else wrote to the tree: stop and investigate.
awk -F'\t' 'NR>1 && $8=="accepted" {s+=$3} END {print "files in accepted batches (git verdict):", s}' $IN/$WAVE/verdict.tsv
wc -l < "$LIST"     # = that number minus the "already present" files the merge reported
```

Optional: ask Lake itself whether the merged modules are up to date. The build must be stopped. This runs Lake in the same sandbox shape as the driver (no network, empty environment). In earlier tests Lake wrote no files during this check.

```bash
TC=/home/user/rh-verify/toolchains/v4.33.1; BUILD=/home/user/rh-verify/build
sed 's/^/+/' "$LIST.modules" > /tmp/pool-targets.txt
bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv \
  --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp --ro-bind "$TC" "$TC" --ro-bind "$BUILD" "$BUILD" \
  --ro-bind /tmp/pool-targets.txt /targets.txt \
  --setenv HOME /tmp/home --setenv PATH "$TC/bin:/usr/bin:/bin" --setenv LAKE_ARTIFACT_CACHE false --setenv LANG C.UTF-8 \
  --chdir "$BUILD" bash -c 'mkdir -p $HOME; mapfile -t t < /targets.txt; lake build --no-build "${t[@]}"' 2>&1 | tail -3
#  expect "All targets up-to-date (…)" and exit status 0.
#  The build tree is bound read-only here, so this check cannot change anything.
#  A non-zero status with "Built"/"would be rebuilt" lines means Lake wants to rebuild merged modules: roll back.
#  An error about a read-only file system means this Lake version wants to write even with --no-build: skip the
#  optional check; the restart check below shows the same thing.
```

## 5. Keep pool files out of the VM's checkpoint shards (decided: yes)
The HF dataset stays VM-built only; pool files stay in the `pool-<wave>` prereleases (record: `pool/verdicts`).
`rh-checkpoint.sh push` uploads every file under `.lake/build` that is not in `state/ckpt/uploaded.list`
(same `./lib/lean/…` / `./ir/…` path format as the merge list), so mark the merged files as uploaded, while the
loop is still stopped:

```bash
U=/home/user/rh-verify/state/ckpt/uploaded.list
cp -a "$U" "$U.before-$WAVE"
cat "$LIST" >> "$U"
grep -c . "$LIST"; LC_ALL=C sort "$LIST" | LC_ALL=C comm -23 - <(LC_ALL=C sort -u "$U") | wc -l   # second number must be 0
```

Effect: a plain `rh-checkpoint.sh pull` on a new machine does not restore these modules (Lake would rebuild them,
safe but slow); the pool planner restores INDEX shards plus the releases, so it is not affected.

## 6. Restart
The same command as the original start, appending to the same log:

```bash
cd /home/user/riemann-hypothesis
RH_OPTIMISE=1 RH_WORK=/home/user/rh-verify RH_CPUS=4 setsid nohup bash scripts/run-verification.sh step2 \
  >> /home/user/rh-logs/step2-driver.log 2>&1 < /dev/null &
sleep 60; tail -2 /home/user/rh-verify/logs/run.log            # "step2: start (…)"
cd /home/user/riemann-hypothesis && setsid nohup bash scripts/rh-checkpoint-loop.sh >> /home/user/rh-logs/ckpt-loop.log 2>&1 < /dev/null &
#  (from the main tree: it has scripts/rh-checkpoint-loop.sh; the loop commits in /home/user/wt-run by default)
#  the loop runs with its defaults (60 min interval), as before: it had no RH_* variables set
```

After 10-20 minutes, and again after a few hours, check that Lake did not rebuild merged modules:

```bash
grep -oE '\] Built [^ ]+' /home/user/rh-verify/logs/step2-build.log | awk '{print $3}' | sort -u > /tmp/built-now.txt
sort -u "$LIST.modules" | comm -12 - /tmp/built-now.txt | wc -l   # expect 0: no merged module rebuilt by the VM
```

Expected cost of a restart [measured/reasoned]:
- Lost work: the in-flight modules, as printed in step 1. It is usually under a minute of core time when you pick the moment.
- Downtime: the stop takes seconds. The merge takes about 2-5 min, the checks about 1-2 min, and Lake's start-up graph walk about 1-3 min (reasoned).
- In total, under about 10 min every 6 h, i.e. about 3% of VM time.
- In return, one 16-job wave adds about 11,200 modules, the equivalent of about 7.5 h of VM work at 25 modules/min.

## Is a restart needed? (recommendation: yes)
Merging while `lake build Main` runs is **not tested**, and the merge script refuses it. The risks:
1. Lake may already have planned or started some of those modules, and would build them again: wasted work, though harmless if the bytes are identical.
2. Lake could read a file while it is being copied. `cp` is not atomic, so it could see a truncated `.olean` or trace and fail the build, or record a wrong hash.
3. The checkpoint loop could upload a half-merged tree.
4. A clean, observed comparison ("Lake reports the merged modules up to date") is only possible with the build stopped.

A restart every 6 h costs about 3% and removes all four risks.

## Rollback
Use it if any check fails, or if Lake rebuilds merged modules after the restart.

```bash
# stop the loop and the build again (step 2), then:
cd "$B" && xargs -d '\n' -a "$LIST" rm -f          # remove exactly the merged files (nothing else was written: postcheck)
find "$B" -type d -empty -delete
cp -a /home/user/rh-verify/state/ckpt/uploaded.list.before-$WAVE /home/user/rh-verify/state/ckpt/uploaded.list   # if step 5 was done
# restart (step 6). The VM then rebuilds those modules itself when its DFS order reaches them. To confirm,
# their names show up as "Built" in step2-build.log over the following hours:
#   sort -u "$LIST.modules" | comm -12 - /tmp/built-now.txt | wc -l   grows over time
```

If the VM had already built dependents on top of merged modules before the rollback, Lake rebuilds the removed modules. If the bytes come out identical (as in every comparison so far), the dependents remain valid. Otherwise their traces no longer match and Lake rebuilds them too, which is safe.

## Rehearsal (2026-11-22, scratch tree `/home/user/pool-scratch`, deleted afterwards)
- Fetch of `pool-w1` jobs 0-1 (`RH_POOL_JOBS="0 1"`) and `pool-pilot2`: 25 s, all sha256 match the git verdicts.
- Dry run: "verified: 4900 files, 4900 new" per batch; no file written.
- Apply: 9,799 files merged in 73 s (1 pre-seeded identical file skipped). Postcheck: 9,799 changed = 9,799 listed, all sha256 match, OK.
- Second apply: "0 new, 4900 already present and identical" per batch, 0 files changed (idempotent).
- Conflict: one merged file altered, re-run, refused: "a file already in the live tree has different content". The postcheck also failed on it.
- Rollback: `xargs rm` of the list; only the pre-seeded file remained.
- Guards: `RH_POOL_SCRATCH` refused for the live path. `--apply` refused while `lake build Main` runs.
- Two bugs were found and fixed before writing this: module paths with non-ASCII characters (`₂`) were rejected by the path check, and `tar -t` escaped them. Earlier merge tests used ASCII-only modules.
- Not rehearsed: the stop and the restart of the live build, and the Lake `--no-build` check on the live tree. Lake's acceptance of merged files was shown on a runner (merge test, run 45032647693).

## Lessons from the live run (2026-11-23 to 2026-11-24, merges of `pilot2`, `w1` ... `w13`)
Facts from the run; the rehearsal above stays as written.

1. **Restart commands.** The live build is now started with two Lean worker threads, because four thrash the VM when modules are deep in the import graph:
   `RH_LEAN_THREADS=2 RH_OPTIMISE=1 RH_WORK=/home/user/rh-verify RH_CPUS=2 setsid nohup bash scripts/run-verification.sh step2 >> /home/user/rh-logs/step2-driver.log 2>&1 < /dev/null &`
   (`RH_CPUS` alone only pins the same number of processes to fewer cores.) Use the same environment after every merge. The checkpoint loop restart is unchanged (from `/home/user/riemann-hypothesis`, not from `wt-run`).
2. **After a VM restart (machine reboot).** The root disk and the image file `/home/user/rh-verify.btrfs.img` survive; the loop mount and zram do not. Before anything else run `RH_WORK=/home/user/rh-verify bash scripts/rh-optimise.sh storage-mount 9 400G` (it only formats when the image file is missing and refuses a non-empty mount point) and `... zram 8G lz4`, check `find /home/user/rh-verify/build/.lake/build -name '*.olean' | wc -l`, then start the build and the loop. If nothing is running, a merge needs no stop. Expect the first minutes after any restart to show heavy reads (cold page cache) and about an hour of slow progress.
3. **Rejected and failed jobs.** `rh-pool-fetch.sh` prints `job N: REJECTED, skipped` or `FAILED, skipped` and fetches only accepted batches; `rh-pool-merge.sh` then covers only those. Expect fewer files than planned (`files in accepted batches` from the verdict). The modules of skipped jobs stay unbuilt and are planned again in a later wave. A rejected job usually means a spot-check mismatch; a build step that ran close to the 90-minute limit packs only the modules it finished, so lower `cap` (500 modules per job worked) when waves run long.
4. **"already present and identical" is normal.** If the VM built some of a wave's modules itself before the merge, the dry run reports them (`verified: 3500 files, 3444 new, 56 already present and identical`). That is a free VM-versus-runner comparison; the merge skips those files and lists only the new ones in `$LIST`. A differing file makes the merge refuse; do not force it.
5. **Planner rate.** The plan takes the VM's rate from the last three rows of `progress.tsv`. A merge adds thousands of modules at once, so its row shows a rate in the hundreds or thousands, which pushed the look-ahead past the end of the build order (`NO READY MODULES`, wave `w11`, first attempt). Rows with a rate of 100 modules/min or more are now ignored (commit `253cd0f02e8`). If a wave finds nothing although many modules are unbuilt, look at the last three rows first.
6. **Size of a merge window.** A wave of 8,000-11,200 modules takes about 1.5-5 minutes to copy and check (5 minutes for 25,200 modules at once). The closure check (`exp-dag.py` and `rh-pool-closure-check.py`, about 3 minutes at nice 19) and the fetch (about 1.3 GB per 8,000 modules) need no stop. Wait for `rh-pool-lost-work.sh` to report 100 core-seconds or less, usually within seconds.
7. **Wave times.** Full waves took about 1.1 hours at first and up to 2.4 hours for the deepest modules. The first wave after a long idle time, or a wave in which one job runs long, is held up by its slowest build job, because the spot-check jobs start only after all builds finish.
8. **Workflow runs.** GitHub disabled the repository's workflows once (2026-11-23 about 00:14Z) and cancelled the wave that was running; after re-enabling them, check `list_workflows` shows every workflow `active` and re-dispatch with the same inputs. Do not poll the full run list (it returns every run); read `stats/<wave>.json` on `pool/verdicts` or one run by id.
9. **Order and watchers.** Always merge oldest wave first; later waves depend on earlier ones (`depends_on_waves` in the stats). Re-arm the heartbeat watcher after a stop (it reports `DRIVER GONE`, which is expected during a merge).
