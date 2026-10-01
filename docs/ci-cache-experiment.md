# SwiftPM release cache experiment

This opt-in benchmark measures build-artifact reuse on separate GitHub-hosted
`macos-26` runners with Xcode 26.6. It does not change `.github/workflows/ci.yml`,
the required optimized release build, test shards, or any shipped app.

## Scenarios

| Job | Inputs | Purpose |
| --- | --- | --- |
| cold | Fresh checkout, empty scratch path, no cache restore | Baseline and cache producer |
| raw | Fresh checkout, exact cache restore | Test naive artifact caching |
| unchanged | Same restore, byte-verified input timestamps | Detect checkout timestamp invalidation |
| edited | Same timestamp restoration, then change an About string | Verify useful reuse across real app edits |
| raw-edited | Raw restore, then change an About string | Verify the simpler strategy without timestamp restoration |

Warm jobs run on new runners after cold completes. The edited jobs
requires an app compile progress entry and checks the built binary contains the
new string. Its source edit is confined to that disposable CI checkout. No
benchmark binary is installed, executed, published, or signed.

## Running

Open/update a same-repository PR from `codex/ci-build-cache-experiment` changing
the workflow or harness. Other PR branches do not automatically run it. Once the
workflow exists on the default branch, it can also be dispatched manually.
Do not merge an experiment merely to run it: the PR trigger works before merge.

The first run used four macOS jobs. The follow-up matrix uses three: cold, raw,
and raw-edited. Cancel obsolete runs; concurrency does this
automatically on new commits. A cold run may take approximately 20 minutes, and
a cache that fails to reuse compilation may take that long again in warm jobs.

## Measurements and acceptance

Each job uploads `environment.json`, `measurement.json`, `timings.json`, and elapsed-time-stamped
`build.log`, retained for seven days. `measurement.json` includes automatically
measured pipeline and cache save/restore durations, plus input-validation,
snapshot, and probe-edit time when applicable. Pipeline includes binary validation
and intervening workflow-step overhead; it excludes queue, checkout, environment
preparation, final reporting and artifact upload. Phase durations overlap with
pipeline: do not add them to it. Incomplete phases are null, never zero.
The Actions timeline supplies queue time and whole-job duration. Progress-entry counts show
work replayed, not exclusive module CPU time (compilation overlaps).

Compare:

1. Cold build time versus warm build **plus restore and input-validation time**.
2. Cache save time and compressed/uncompressed size (cache action and build log).
3. C-family/SwiftSyntax compilation replay in each warm build.
4. Whether the edited build actually recompiles the app and embeds the new string.
5. Queue time separately from execution time; caching cannot fix runner queues.

One run establishes feasibility, not a stable speedup. Repeat promising scenarios
before adopting caching. Preserve a clean optimized-build validation path and
test the real rollout's cross-commit invalidation, toolchain changes, dependency
changes, cache misses, and cache eviction. Splitting/reusing test builds and
benchmarking larger runners are separate experiments.

## Isolation and safety

- Cache keys include exact Xcode/Swift/SDK, OS/image, architecture, absolute paths,
  package manifest/lockfile, harness digest, release configuration/product, and
  run ID/attempt. No broad restore fallback is used; a warm miss fails rather
  than being mislabeled as a warm result.
- Only the isolated scratch directory is cached, not credentials or a home
  directory. Global SwiftPM source caches on hosted images are outside this
  experiment; "cold" means no restored compiled artifacts in the scratch path.
- Timestamp restoration modifies metadata only when SHA-256 matches, and rejects
  path traversal/symlink escapes. Changed/new/deleted source inputs are not hidden.
- The experimental cache is PR-scoped, not a shared trusted-main cache. A rollout
  would warm caches from trusted main pushes with PR restore-only consumers;
  privileged release workflows must not trust PR-produced artifacts.
- No production gate depends on the experimental jobs and no paid runner tier or
  repository setting is changed. Cache entries expire under repository policy;
  delete only this run's `experiment-spm-v1-*` entries after measurement if needed.

Harness checks: `python3 scripts/test_ci_cache_experiment.py` (no native build).

## First hosted result (2026-10-01)

[Run 36854266264](https://github.com/Muesli-HQ/muesli/actions/runs/36854266264)
at `b1272674` passed all four scenarios. Whole-job times from the Actions API
(exclude queue; include checkout, cache, validation, and upload):

| Scenario | Job duration | Swift build duration |
| --- | ---: | ---: |
| cold | 22m 40s | 1309.256s |
| raw | 5m 39s | 279.758s |
| unchanged | 5m 41s | 283.916s |
| edited | 5m 28s | 264.719s |

The edited build recompiled the app and verified its new string, with zero
C-family or SwiftSyntax compile entries. Cache restore took 31–42 seconds;
save took 31 seconds; compressed cache was about 1.6 GB (3.5 GB unpacked).
The ~76% edited-job reduction is one feasibility result, not a production SLA.
Timestamp restoration did not demonstrate a wall-clock benefit. Repeat with
raw-edited before choosing the simpler rollout. Automatic phase accounting was
added after this first run to make net-savings comparisons reproducible directly
from artifacts (the first result above uses the API timeline).
