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

The three-snapshot cleanup uses GitHub's cache API and only runs when the
release build used a GitHub-hosted runner. Blacksmith uses its own documented
cache eviction policy (entries not accessed for more than seven days); this
migration does not enforce the three-snapshot cap on Blacksmith. Use the
Blacksmith dashboard/CLI for its cache administration. A future custom retention
adapter must verify a replacement on that backend and preserve scope/version
boundaries before deleting anything.

References: [GitHub contexts](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts),
[Blacksmith Actions cache](https://docs.blacksmith.sh/blacksmith-caching/dependencies-actions).

These expressions are workflow policy, not a provider-side billing boundary:
changes to workflow YAML must be reviewed before authorizing contributor runs.
Organization-managed security checks and external review services are configured
separately and are not routed by these repository workflow files.
