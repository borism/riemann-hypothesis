# Pool verdicts (issue #9)

One file per wave in verdicts/: wave, job, files, tar_sha256, manifest_sha256, spot_modules, spot_same_files, verdict.
Written by the publish job of .github/workflows/exp-pool-wave.yml (branch exp/gh-runners-restore-test).
Accepted batches are attached to the prerelease pool-<wave>; rh-pool-merge.sh checks every hash against these files.
stats/<wave>.json: runner-minutes, modules built, wall time.
