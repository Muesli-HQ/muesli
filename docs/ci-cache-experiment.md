# SwiftPM release cache experiment

This opt-in benchmark measures build-artifact reuse on separate GitHub-hosted
`macos-26` runners with Xcode 26.6. The same PR also rolls the measured raw-cache
strategy into `build_release` in `.github/workflows/ci.yml`. The required optimized
release build, test shards, and shipped app code are preserved.

## Actual CI rollout

- PR release jobs restore from the base commit's cache, falling back only to the
  latest cache with an identical compatibility fingerprint. Every job still runs
  `swift build -c release --product MuesliNativeApp --force-resolved-versions`.
- Only successful `push` builds on `main` can save release artifacts. After
  compilation, a metadata-only lookup checks for the exact commit's cache, with
  no prefix fallback. Only an exact hit skips the upload; an older compatible
  snapshot does not suppress refresh. A failed lookup step skips saving and
  emits a warning in the report.
  Main never downloads cached artifacts: every relevant main push remains a clean
  optimized-build validation. Manual CI runs also build clean and do not save.
  PRs never save this cache.
- Keys cover architecture, OS/runner image, exact Xcode/Swift/SDK and SDK path,
  workspace/scratch paths, full build command, manifest, lockfile, and helper
  digest. No fallback crosses those boundaries. Source changes are deliberately
  not part of the fingerprint: SwiftPM must invalidate and compile them normally.
- Only `~/Library/Caches/muesli-spm/ci/release` is cached. No timestamp repair,
  credentials, signing material, debug products, or app data are cached. Shipping
  workflows do not consume this cache.
- Cache misses/eviction build cold. Save failures do not fail a correct build;
  compilation failures still fail the required gate. Restore failures are not
  disguised as successful builds.
- Timing markers, measurement recording/reporting, and artifact uploads are
  best-effort and cannot fail the required job. The build helper preserves the
  compiler exit status even when timer/log/result writes fail, and compiler
  output remains in the Actions console. Cache identity/safety checks remain
  mandatory; this does not make an unsafe restore or a failed compile pass.
- Each successful relevant main commit can publish a fresh ~1.6 GB snapshot.
  Storage is controlled by retention, not a periodic refresh or frozen seed.
  A separate best-effort main-only cleanup job retains the newest three snapshots
  across the `ci-release-v1-` namespace on `refs/heads/main`. It first verifies the
  replacement's full key/current commit and positive size via the cache API, then
  revalidates targets and replacement before each exact-ID deletion. It ignores
  PR caches, benchmark caches, LocalVQE caches, and other namespaces/refs.
  Missing replacement or API/metadata errors stop deletion. An out-of-order job
  cannot delete snapshots newer than its own replacement. These safeguards and
  cancellation may temporarily retain more than three; this is a count target,
  not a hard repository byte quota. Deleted caches are rebuildable, not backups.
- Only the cleanup job has `actions: write`; it runs after a successful main
  build/save, never on a PR or manual dispatch, and is not part of `ci-gate`.
  Save-action success alone is insufficient: the API must confirm the replacement
  exists before anything is deleted. No existing caches were deleted locally
  while implementing or testing this policy.
- Job summaries and seven-day `release-build-measurements` artifacts report
  matched cache key, bypass state, main exact-lookup and restore/save outcomes,
  build/pipeline time, and transfer
  phases. Pipeline includes intervening steps; queue/checkout/preparation and
  report/upload time are excluded. Incomplete phases are explicitly marked.

Bootstrap: this PR's actual release job initially has no trusted main cache and
will build cold. Its first successful post-merge main build seeds the cache for
subsequent PRs. The experiment proves fresh-runner reuse before merge; the first
ordinary PR after seeding verifies the base-branch restore path. No second
implementation PR is required. GitHub documents [base/default-branch cache
access](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

Test shards and CLI packaging are unchanged and may become the critical path;
the release-job speedup is not a promise that the entire CI pipeline takes five
minutes.

### Clean builds / cache bypass

Set repository Actions variable `MUESLI_CI_RELEASE_CACHE_DISABLED` to the exact
string `true`, then rerun CI. This disables release-cache restore, lookup, save,
and cleanup while retaining the identical optimized compile and all required
checks. Unset it (or set `false`) to resume caching. Manual `CI` workflow dispatch
already builds clean and never saves/deletes release caches, so dispatch on a
feature branch is an additional diagnostic path without changing the variable.
The switch does not purge existing entries and does not affect unrelated caches.

Do not wait for a timer if a cache is suspect. Use the bypass to diagnose; fix the
underlying invalidation issue and rotate the cache schema/helper fingerprint if
the existing snapshot must no longer be consumed.

Policy/helper checks: `python3 scripts/test_ci_release_cache.py` and
`python3 scripts/test_ci_release_cache_cleanup.py` (both run in the Linux
classifier job). Cleanup API calls are mocked in tests; the cleanup CLI defaults
to dry-run and requires `--delete` plus a trusted successful main-save context to
apply deletions. Workflow syntax is checked with actionlint.

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

Apply the `ci-cache-benchmark` label to a same-repository PR from
`codex/ci-build-cache-experiment` changing the workflow or harness (or update it
while that label is present). Other PR branches do not automatically run it. The
label requirement was added after the two initial runs so ordinary rollout
updates do not repeatedly launch extra cold builds. Once the
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
- The experimental cache is PR-scoped and uses a separate namespace and path
  from the actual CI rollout above. It never seeds the shared trusted-main cache;
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
Timestamp restoration did not demonstrate a wall-clock benefit. A repeat with
raw-edited validates the simpler rollout. Automatic phase accounting was
added after this first run to make net-savings comparisons reproducible directly
from artifacts (the first result above uses the API timeline).

## Raw-cache confirmation (2026-10-01)

[Run 36858256720](https://github.com/Muesli-HQ/muesli/actions/runs/36858256720)
at `ee0c5268` passed all three scenarios without timestamp restoration:

| Scenario | Whole job | Swift build | Measured pipeline | Cache transfer |
| --- | ---: | ---: | ---: | ---: |
| cold | 21m 18s | 1233.003s | 1262.873s | save 22.679s |
| raw | 4m 52s | 244.999s | 276.377s | restore 30.775s |
| raw-edited | 7m 38s | 388.926s | 437.355s | restore 41.555s |

The edited binary check passed. Both warm runs emitted one app, one C-family,
zero SwiftSyntax, and three other compile progress entries, versus cold's
one/181/17/31. The raw-edited whole job was about 64% shorter than cold, including
cache transfer and binary validation. Its longer runtime than the unchanged run
is why we do not promise a uniform five-minute build. These two hosted benchmark
runs support adopting the simpler raw-cache strategy; production cache-hit rate,
whole-CI critical path, and base-branch restoration still need observation after
trusted-main seeding.
