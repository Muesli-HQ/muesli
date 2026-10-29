# CI runner routing

The workflows in `.github/workflows/` reserve Blacksmith runners for
`pHequals7` acting on their own work in `Muesli-HQ/muesli`. All other runs use
GitHub-hosted runners of the corresponding OS.

| Run | Runner provider |
| --- | --- |
| PR authored and updated by `pHequals7` | Blacksmith |
| Community or bot-authored PR, including maintainer updates | GitHub |
| Contributor updates to a maintainer PR | GitHub |
| Push or manual dispatch initially triggered by `pHequals7` | Blacksmith |
| Push or manual dispatch initially triggered by another account | GitHub |
| Issue/comment automation | Blacksmith only when both actor and target author are `pHequals7` |
| Workflows running in forks | GitHub |

Routing uses GitHub's original `github.actor`, not `github.triggering_actor`,
so rerunning or approving a community run does not move it to paid hardware.
A maintainer merge into `main` produces a separate push run: that push uses
Blacksmith when `pHequals7` performs the merge, regardless of the PR's author.
Bot-authored PRs are not implicitly treated as maintainer PRs. There is no
label or PR-body override that enables Blacksmith.

Runner selection is evaluated before a job starts. It deliberately does not
add a separate routing job, so maintainer runs do not need to queue for a
GitHub runner first. Keep every job's condition consistent; the dependency-free
`scripts/test_ci_runner_routing.py` exercises the actual workflow expressions
against ownership, fork, bot, and rerun cases in the classifier test job.

## Checkout and build caches

Keep `actions/checkout` and its existing input settings. Cached Git checkout
is not enabled. Keep the release-cache compatibility fingerprint, unconditional
compilation after restore, and default-branch-only writes.

Blacksmith redirects Actions cache operations to its own backend. GitHub and
Blacksmith cache populations are separate; a successful cold build does not
prove a warm hit. Expect a miss when switching providers or toolchains. Each
backend needs a successful main-push cache save before compatible PRs can reuse
that snapshot; do not grant community PRs cache-write permissions to warm it.

Both backends retain the newest three main release snapshots. The maintenance
job uses GitHub's cache API for GitHub-hosted builds and the pinned Blacksmith
CLI for Blacksmith builds. It only runs after a successful main build and a
successful cache save or a verified exact cache hit for that main commit.
An exact-hit rerun can therefore finish cleanup after an earlier interrupted
or failed attempt without overwriting the cache.

Blacksmith maintenance requires the repository secret `BLACKSMITH_CACHE_TOKEN`,
an organization service token with cache-management access. It is only supplied
to the main-push maintenance job, never PR builds. CLI 0.5.3 is checksum-pinned
and auto-updates are disabled. Authentication failures are visible CI failures;
no deletion is attempted on missing or malformed inventory metadata.

Retention reads every page, validates the populated replacement, and rechecks
before every deletion. Blacksmith deletes match key, version, exact main scope,
and transparent-cache variant; unrelated namespaces, PR/feature scopes, and
LocalVQE caches are untouched. Deletion is verified against a fresh inventory.
An older overlapping job cannot delete newer snapshots; the latest successful
cleanup converges to three. Retention failures fail the main CI gate without
preventing compilation or tests from running. Each provider serializes its
maintenance jobs independently.

Use the opt-in `ci-build-cache-experiment.yml` workflow on a maintainer-dispatched
branch for cold-save/warm-restore checks. Its run-specific namespace is separate
from the production main snapshots. Both warm variants require an exact cache
hit; the edited variant also verifies recompilation and a marker in the rebuilt
binary. These tests establish same-branch reuse; main-to-PR reuse additionally
requires the first successful main snapshot on the selected provider.

Verified on Blacksmith macOS 26 in
[benchmark run 40880908083](https://github.com/Muesli-HQ/muesli/actions/runs/40880908083):

| Scenario | Build | Restore | Measured pipeline |
| --- | ---: | ---: | ---: |
| Cold | 359.0 s | — | 367.6 s |
| Warm, unchanged source | 282.3 s | 9.5 s | 292.3 s |
| Warm, edited source | 277.8 s | 11.7 s | 291.5 s |

Both warm jobs restored the same exact 1.97 GB cache. The edited binary marker
was verified. Reuse reduced the measured pipeline by about 20%, but SwiftPM
still recompiled substantial portions of the build. This is one measured run,
not a general performance guarantee. The temporary experiment cache was removed
after verification using exact key/version/scope/variant deletion, preserving
other entries. Production retention selection is covered by synthetic fixtures;
there were no main release snapshots on Blacksmith yet when this was tested.

References: [GitHub contexts](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts),
[Blacksmith Actions cache](https://docs.blacksmith.sh/blacksmith-caching/dependencies-actions).

These expressions are workflow policy, not a provider-side billing boundary:
changes to workflow YAML must be reviewed before authorizing contributor runs.
Organization-managed security checks and external review services are configured
separately and are not routed by these repository workflow files.
