# Advisory macOS UI-rendering CI

This repository defines the contract for two macOS visual suites:

- `snapshot`: controlled SwiftUI/AppKit rendering-state coverage.
- `e2e`: launch-and-screenshot XCUITest flows through the visual test host.

They are **advisory**. A `changed` image or `missing_baseline` is review evidence,
not a merge failure. A compilation failure, crash, timeout, missing capture,
malformed fixture, incomplete suite result, or renderer-profile mismatch is an
operational error and the runner returns nonzero. This contract does not add a
GitHub Actions workflow, check run, commit status, review, or branch-protection
requirement.

## Current enablement

`ci/ui-rendering-profile.json` is intentionally disabled. The exact Vorflux
Apple Silicon macOS desktop profile has not been verified, so no unattended run
is enabled. In particular, this repository has not verified an unlocked Aqua
session, screenshot authorization, macOS XCUITest support, exact OS/Xcode
builds, display/scale/color profile, or credential-free disposable-worker
boundary. Do not replace the `null` profile values or `baseline_id` with guessed
host values.

The Vorflux automation identifier is **not assigned**. It must be recorded here
only after the required host and isolated-worker capability gate are verified.
Until then, dispatchers must report the run as not executed rather than falling
back to GitHub runners or a developer Mac.

## Change classification

The trusted dispatcher supplies a complete three-dot, merge-base diff in this
strict JSON shape:

```json
{
  "schema_version": 1,
  "complete": true,
  "changes": [
    {"status": "modified", "path": "native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift"},
    {"status": "renamed", "old_path": "native/VisualTesting/Fixtures/v1/a.json", "path": "native/VisualTesting/Fixtures/v1/b.json"}
  ]
}
```

Allowed statuses are `added`, `modified`, `deleted`, `renamed`, and `copied`.
Rename and copy records require both `old_path` and `path`; all other records
require only `path`. The classifier rejects extra fields, relative traversal,
incomplete diffs, unsupported versions, and malformed JSON with exit code 2.
It checks both sides of rename/deletion records.

```sh
python3 scripts/classify_ui_changes.py --input changed-files.json
```

The result is JSON with `decision` (`run` or `skip`), matched policy categories,
and unmatched paths. `scripts/ui_rendering_paths.json` is the reviewed path
policy for UI, state, assets, fixtures/baselines, project files, and this
rendering infrastructure. Pure documentation, CLI, ASR/audio backend,
release-only, site, and unrelated workflow changes are not listed and skip.
The dispatcher must read this policy from its pinned default-branch revision,
never from a PR checkout, and must retain the classifier-policy SHA together
with the head/base/merge-base and baseline revisions.

## Local runner and profile verification

On a verified disposable macOS host, the credential-free entry point is:

```sh
scripts/run_ui_rendering_tests.sh --output visual-results \
  --trusted-baseline-root /Volumes/vorflux-ui-baselines/muesli \
  --trusted-baseline-revision <40-lowercase-hex-sha> \
  --expected-cases /Volumes/vorflux-ui-contracts/muesli-cases.json
```

The dispatcher supplies the baseline root, pinned target-branch revision, and
case contract. The baseline root must be absolute, outside the PR checkout,
mounted read-only to the worker, and never be copied from or read through the
PR checkout. The runner records its resolved root, baseline profile ID, and
pinned revision in every completed suite result and the summary.

The dispatcher-owned case contract is strict and complete:

```json
{"schema_version":1,"suites":{"snapshot":["settings-dark"],"e2e":["recording-indicator-picker-dark"]}}
```

Its file must also be absolute and external to the PR checkout, so a pull
request cannot omit a case it should render.

It creates isolated fixture data and scratch directories, exports
`MUESLI_VISUAL_TESTS=1`, and supplies `MUESLI_UI_RENDERING_RESULT` to each
suite. It sets an absolute `MUESLI_VISUAL_BASELINE_DIR` below the dispatcher
root and passes `MUESLI_VISUAL_BASELINE_ROOT`,
`MUESLI_VISUAL_BASELINE_REVISION`, `MUESLI_VISUAL_BASELINE_PROVENANCE_JSON`,
`MUESLI_VISUAL_RENDERER_PROFILE_JSON`, and the expected-case contract to both
suites. PR code cannot choose the reference, profile, or case set. The
E2E default scenario is `recording-indicator-picker-dark` with window
identifier `window.visual-test`; a trusted operator may override those two
environment variables for a known manifest case. It runs commands from the
repository root, applies a 30-minute per-suite timeout by default (configurable
between 60 and 7200 seconds), recursively terminates descendant processes on
timeout or interruption without relying on `setsid`, never invokes
GitHub/Vorflux APIs, and never uploads artifacts or comments on a PR. It
preserves suite exit failures and always attempts to produce
`visual-results/summary.json` and `index.html`.

Before enabling the profile, verify repeated fresh-process captures for
onboarding, settings, rich meeting content, compact layouts, and translucent
panels. Record observed—not inferred—architecture, macOS version/build, Xcode
version/build, display JSON, backing scale, color space, locale, calendar, time
zone, and appearance in the `expected` object. Set the separate `baseline_id`
to the matching safe baseline directory name. The runner probes those values
and rejects mismatches before it starts untrusted test code. It also requires
macOS, `arm64`, Xcode/Swift/XcodeGen, and `screencapture`; it captures and
discards one preflight image to verify screenshot authorization before running
untrusted suite code.

The standard suite commands are SwiftPM filtering `MuesliSnapshotTests` and an
XcodeGen-generated `MuesliVisualTests` Xcode scheme. A trusted local operator can temporarily
set `MUESLI_UI_SNAPSHOT_COMMAND` or `MUESLI_UI_E2E_COMMAND` to diagnose a
suite; automation should use the checked-in commands. Each successful suite
must write this versioned result at `MUESLI_UI_RENDERING_RESULT`:

```json
{
  "schema_version": 1,
  "suite": "snapshot",
  "status": "completed",
  "renderer_profile": {"architecture": "arm64", "macos_build": "observed-on-verified-host", "...": "all renderer keys"},
  "baseline_provenance": {"root": "/external/read-only/root", "revision": "40-lowercase-hex-sha", "baseline_id": "verified-profile"},
  "expected_cases": ["settings-dark"],
  "cases": [{"id": "settings-dark", "status": "changed", "artifacts": {"expected": "cases/snapshot/settings-dark/expected.png", "actual": "cases/snapshot/settings-dark/actual.png"}}]
}
```

Case statuses are `matched`, `changed`, `missing_baseline`, and
`incompatible_environment`. Completed results must name both suites, contain
their non-empty expected case list, report every expected case exactly once,
and carry a complete observed renderer profile. Artifact paths must be relative
to the report directory, may only name `expected`, `actual`, or `diff`, and
must exist before an advisory report is written; `matched` and `changed` cases
must include an existing expected artifact. The report generator rejects
traversal, missing artifacts, empty/incomplete profiles, and untrusted HTML.
Suite `harness_error` or `skipped` results contain no cases and include a
diagnostic `error` string.

Generate a report from suite results directly with:

```sh
python3 scripts/ui_rendering_report.py \
  --input visual-results/raw/snapshot.json \
  --input visual-results/raw/e2e.json \
  --expected-renderer-profile /trusted/observed-renderer-profile.json \
  --expected-cases /trusted/muesli-cases.json \
  --trusted-baseline-root /trusted/muesli-baselines \
  --trusted-baseline-revision <40-lowercase-hex-sha> \
  --output visual-results
```

`summary.json` is the publisher input and `index.html` is a static gallery.
The publisher may upload the bounded result directory and `.xcresult` bundles,
then maintain one bot-owned, SHA-labelled advisory PR comment. It must recheck
the head SHA and run generation before publishing. Artifact retention and reader
URLs are Vorflux policy, not guaranteed by this repository; document the actual
retention period and URLs with the automation identifier when the service is
enabled. Do not publish credentials, recordings, copied user data, fixture
databases, or unbounded logs.

## Baselines and exclusions

Trusted target-branch references are dispatcher-provided, read-only external
directories keyed by the verified renderer profile and pinned revision. A PR
may propose, but cannot redefine, its expected image. Capture expected/actual/diff
PNGs and metadata per case. Keep stable IDs, fixture hashes, dimensions, scale,
resource fingerprints, and justified tolerances in the scenario manifest.

The suites simulate fixture permissions and audio states; they do not claim to
validate real TCC grants, hardware capture, cloud services, network services,
or audio quality. Fork PRs may run only on a truly isolated, credential-free
disposable worker; otherwise report them as not executed.

## Contract tests

The repository checks its Linux-compatible pieces without macOS UI tooling:

```sh
python3 scripts/test_classify_ui_changes.py
python3 scripts/test_ui_rendering_report.py
python3 scripts/test_run_ui_rendering_tests.py
```

On non-macOS or while the profile is disabled, the runner intentionally exits
nonzero after writing a structured harness-error fallback. That is expected and
does not mean a visual difference was found.
