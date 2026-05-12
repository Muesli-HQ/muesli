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

Useful dev commands:

```bash
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh          # Build and launch MuesliDev
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh --reset  # Re-run onboarding, keep data
./scripts/dev-reset-permissions.sh                # Reset macOS privacy permissions for MuesliDev
```

If you do have your own signing certificate, you can override the identity:

```bash
MUESLI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/dev-test.sh
```

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
- Avoid committing generated build artifacts, app bundles, model files, or
  local application data.
