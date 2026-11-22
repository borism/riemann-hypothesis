# Step 2 build run, 2026-11-22: live tracking files

Files for one `lake build Main` run (step 2) on a 4-core / 15 GB cloud VM, started 2026-11-22T09:51Z.
They are written by `scripts/rh-checkpoint-loop.sh` (see #6) about once an hour, so this branch
changes while the run is going. This pull request is a **draft tracker**; it is not meant to be
merged until the run has ended, failed, or been abandoned.

| File | What it is |
|---|---|
| `progress.tsv` | one line per pass: time, modules built (`.olean` count), modules per minute since the last line, free disk (GB), memory available (MB), swap used (MB), checkpoint shards uploaded |
| `monitor-step2.tsv` | the driver's 1-minute resource samples. The header is the old 6-column one, so the columns after `mem_avail_mb` are mislabelled (see the efficiency audit) |
| `build-tail.log` | the last 200 lines of the `lake build` log, rewritten each pass |
| `driver-tail.log` | the last 50 lines of the driver log |
| `../../checkpoints/step2/INDEX.tsv` | one line per checkpoint shard on Hugging Face: shard sha256, manifest sha256, file count. This is the trust anchor that `scripts/rh-checkpoint.sh pull` checks downloads against |

The full build log is not committed; it grows to many MB and git would keep a copy of every version.

What this shows: how far the run has got and how much resource it used. It does not show that any
module was independently rebuilt, and it says nothing about whether the claimed formalization is
correct. Restoring checkpoint shards continues this run; it is not an independent rebuild.
Tracking issue: #1.
