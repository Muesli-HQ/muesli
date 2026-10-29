# CI runner routing

GitHub-hosted runners are the default for every workflow, including maintainer
PRs, pushes to `main`, merges, reviews, automation and ordinary manual runs.
Only `ci.yml` can opt into Blacksmith, in `Muesli-HQ/muesli`, when the original
triggering actor (`github.actor`) is `pHequals7`:

| Run | Runner provider |
| --- | --- |
| PR with `ci:blacksmith`, triggered by `pHequals7` | Blacksmith |
| PR without `ci:blacksmith` | GitHub |
| Community/bot-triggered update, even with `ci:blacksmith` | GitHub |
| Push or merge into `main`, regardless of PR label | GitHub |
| Ordinary manual CI run | GitHub |
| Explicit manual Blacksmith cache warm-up on `main` by `pHequals7` | Blacksmith |
| All other workflows and fork-repository runs | GitHub |

## Accelerate a selected PR

Add the repository label `ci:blacksmith`, either in the PR sidebar or with:

```bash
gh pr edit 698 --repo Muesli-HQ/muesli --add-label ci:blacksmith
```

Adding the label starts a fresh `pull_request` CI run. It keeps the same PR
merge-ref checkout, test requirements and `ci-gate` check as normal CI, and
cancels the superseded run through the existing per-PR concurrency group.
Subsequent updates triggered by `pHequals7` stay on Blacksmith while labelled.
This is an explicit selection of the PR, including a community or bot PR the
maintainer chooses to accelerate; there is no hardcoded exception for #698.
Community activity does not independently opt into paid compute.

Remove the label to start replacement GitHub CI and cancel the paid run:

```bash
gh pr edit 698 --repo Muesli-HQ/muesli --remove-label ci:blacksmith
```

A rerun uses the original event/actor/label snapshot, not the current labels or
`github.triggering_actor`. Change the label to request a fresh provider choice;
remove and re-add it to reselect Blacksmith after a contributor-triggered update.
Unrelated label events allocate no runners and use a separate concurrency group.
Their skipped gate is named `ignored-label-event`, so they neither cancel real
CI nor replace its required `ci-gate` status with a skipped success.

Runner selection is evaluated before jobs start. There is no routing job that
must first wait for a GitHub runner. `scripts/test_ci_runner_routing.py` exercises
the actual expressions, label events, cancellation groups, warm-up boundaries,
and default routing across the other workflows.

## Manually warm Blacksmith's main cache

After this workflow change is merged, open **Actions → CI → Run workflow**, select
**main**, and enable **Warm Blacksmith release cache on main**. CLI equivalent:

```bash
gh workflow run ci.yml --repo Muesli-HQ/muesli --ref main \
  -f warm_blacksmith_cache=true
```

This paid operation runs the release build, lightweight policy checks and cache
maintenance. It skips the test shards, AIElements tests, packaged CLI smoke test
and update-flow check. The final check is `blacksmith-cache-warm`, not `ci-gate`;
a cache warm-up must not substitute for complete CI. Its concurrency group is
separate from ordinary `main` CI, so warming and post-merge checks do not cancel
one another.

Only `pHequals7` can request this mode in the upstream repository on `main` with
release caching enabled. Invalid requests fail validation before native jobs or
cache credentials are used. Ordinary manual runs remain on GitHub and do not
write release snapshots. Warm-up always compiles cleanly, then saves the exact
main-commit snapshot or verifies it already exists. Lookup/save failure fails
warm-up explicitly. Matching PRs can then restore that main snapshot from
Blacksmith. A cache miss still compiles normally.

## Checkout, cache isolation and retention

Keep `actions/checkout` and its existing inputs. Paid cached Git checkout/sticky
disks are not enabled. Blacksmith redirects normal Actions cache operations to
its separate backend; the providers do not share snapshots. Only compatible
fingerprints can be reused, and compilation always runs after restoring.
Expect colder caches when Blacksmith is used infrequently.

GitHub main pushes and authorized Blacksmith main warm-ups each retain their
provider's newest three main release snapshots. PRs never write these snapshots
or receive cache-maintenance credentials. Cleanup requires a successful main
build and a saved or verified exact-commit replacement; an exact-hit retry can
finish interrupted cleanup without overwriting a snapshot.

Blacksmith maintenance uses the repository secret `BLACKSMITH_CACHE_TOKEN`, an
organization service token with cache-management access. It is supplied only to
the trusted-main maintenance job. CLI 0.5.3 is checksum-pinned and auto-updates
are disabled. Authentication/inventory failures fail closed.

Retention reads all pages, checks the populated replacement before every exact
key/version/scope/variant deletion, and verifies removal. Other namespaces,
PR/feature scopes and LocalVQE caches are untouched. Older overlapping jobs
cannot delete newer snapshots. Each provider serializes maintenance independently;
cleanup failure fails the final check without preventing unrelated tests.

The separate `ci-build-cache-experiment.yml` remains opt-in but defaults to
GitHub. The historical Blacksmith benchmark below was run before the switch to
label-based opt-in; it verifies same-branch reuse, not production main-to-PR
reuse. The new manual main warm-up needs a live run after merge before claiming
that complete path has been verified.

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

Workflow expressions are policy, not a provider-side billing boundary against
edited YAML. Review workflow changes before authorizing contributor runs.
Organization-managed security checks and external reviews are configured
separately and are not accelerated by the PR label.
