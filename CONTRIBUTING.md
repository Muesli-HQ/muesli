# Contributing to Muesli

Thanks for helping improve Muesli. This project is a native macOS app built
with SwiftPM, AppKit, SwiftUI, and a small set of shell scripts around local
builds and CI shards.

## Requirements

- macOS 14.2 or newer
- Xcode 16 or newer
- Apple Silicon Mac for the main app workflows

## Local Development Build

Maintainer release builds are signed with a Developer ID certificate that
external contributors do not have. For local development, build the isolated
dev app without signing:

```bash
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh
```

That installs `/Applications/MuesliDev.app` with bundle ID `com.muesli.dev`
and stores data under `~/Library/Application Support/MuesliDev/`, so it does
not touch your production Muesli install or data.

By default, `scripts/dev-test.sh` uses local-only entitlements. Maintainer
machines keep CloudKit profiles outside this repository under a sibling
`muesli-ios/secrets/` directory, but those profiles are used only when
`--cloud-entitlements` is passed. External contributors should not need Apple
Developer account access for ordinary local development.

Useful dev commands:

```bash
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh                # Build and launch MuesliDev
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh --reset        # Re-run onboarding, keep data
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh --local-only   # Force local-only entitlements
./scripts/dev-reset-permissions.sh                      # Reset macOS privacy permissions for MuesliDev
```

If you do have your own signing certificate, you can override the identity:

```bash
MUESLI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/dev-test.sh
```

Cloud-entitled local builds require a provisioning profile whose App ID matches
the selected bundle ID and whose certificate matches the signing identity:

```bash
MUESLI_PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
MUESLI_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
MUESLI_CODESIGN_TIMESTAMP=none \
  ./scripts/dev-test.sh --cloud-entitlements
```

If `--cloud-entitlements` is passed explicitly and no matching profile is
available, the script fails before building. That is expected; use
`--local-only` for contributor builds that do not exercise iCloud sync.
Maintainers switching an existing dev app from Developer ID/local-only signing
to Apple Development/CloudKit signing may need to regrant macOS privacy
permissions once because macOS tracks permissions against the app's signing
requirement.

## Release Signing

Official preprod and stable release scripts require maintainer-only Developer
ID provisioning profiles:

- `com.muesli.preprod` for `scripts/release-preprod.sh`
- `com.muesli.app` for `scripts/release.sh`

Those profiles are not committed to the repository. Maintainers pass them with
`MUESLI_PROVISIONING_PROFILE`; contributors should not need to run these
release scripts for normal PR validation.

## SwiftPM Build Cache

SwiftPM writes build artifacts to `native/MuesliNative/.build` by default,
which can become large across worktrees. Use a shared scratch path for local
testing:

```bash
MUESLI_SWIFTPM_SCRATCH_PATH="$HOME/Library/Caches/muesli-spm/dev" \
  MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh
```

Do not run concurrent builds from different worktrees into the same scratch
path. Use separate names such as `dev`, `test`, or `agent-1`.

## Tests

Run the native test package:

```bash
swift test --package-path native/MuesliNative
```

For CI-sized local checks, use the shard script:

```bash
./scripts/run_ci_test_shard.sh core
./scripts/run_ci_test_shard.sh dictation-transcription
./scripts/run_ci_test_shard.sh meetings
```

For direct SwiftPM test runs with a shared cache:

```bash
swift test --package-path native/MuesliNative \
  --scratch-path "$HOME/Library/Caches/muesli-spm/test"
```

## Pull Requests

- Keep changes focused and include tests for behavioral changes.
- Mention the test commands you ran in the PR description.
- Use `MUESLI_SKIP_SIGN=1` for local app verification unless you have a valid
  signing identity.
- Use `--local-only` unless your change specifically needs iCloud/CloudKit
  entitlements.
- Avoid committing generated build artifacts, app bundles, model files, or
  local application data.
