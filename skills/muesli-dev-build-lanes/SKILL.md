---
name: muesli-dev-build-lanes
description: Use when working on Muesli local dev builds, fixed dev lanes, parallel worktrees, SwiftPM scratch paths, app bundle IDs, app support directories, signing, entitlements, iCloud/APNs-capable builds, or local-only builds that should omit cloud entitlements.
---

# Muesli Dev Build Lanes

## Overview

Use this skill to build and reason about local Muesli dev apps across multiple worktrees without overwriting app bundles, sharing support data, or accidentally requiring iCloud/APNs entitlements.

## Core Workflow

1. Read `AGENTS.md` first for current scratch-path and lane policy.
2. Inspect `scripts/dev-test.sh`, `scripts/build_native_app.sh`, and `scripts/muesli_spm_cache.sh` before changing build behavior.
3. Preserve default `./scripts/dev-test.sh` behavior unless explicitly changing the default dev app.
4. Prefer fixed lanes `A`, `B`, and `C`; do not create arbitrary branch-named bundle IDs unless the user explicitly accepts repeated macOS permission prompts.
5. Do not delete app support data or reset TCC permissions unless explicitly asked.

## Lane Mapping

Default dev app:

```text
App:        /Applications/MuesliDev.app
Bundle ID:  com.muesli.dev
Support:    ~/Library/Application Support/MuesliDev
```

Fixed lanes:

```text
A -> MuesliDevA, com.muesli.dev.a, process MuesliDevA, ~/Library/Application Support/MuesliDevA
B -> MuesliDevB, com.muesli.dev.b, process MuesliDevB, ~/Library/Application Support/MuesliDevB
C -> MuesliDevC, com.muesli.dev.c, process MuesliDevC, ~/Library/Application Support/MuesliDevC
```

## Entitlement Modes

Use local-only entitlements when testing non-sync features:

```bash
./scripts/dev-test.sh --lane A --local-only
```

Named lanes default to local-only entitlements. This uses `scripts/MuesliLocalOnly.entitlements` and clears provisioning/APNs env for the build.

Use cloud entitlements only when iCloud/APNs behavior is under test and the bundle ID has a matching Apple Developer profile:

```bash
MUESLI_PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
MUESLI_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
MUESLI_CODESIGN_TIMESTAMP=none \
./scripts/dev-test.sh --lane A --cloud-entitlements
```

Plain `./scripts/dev-test.sh` keeps the existing cloud-entitlement-capable `MuesliDev` behavior.

## Build Cache Rules

Use the shared SwiftPM scratch path resolver. For direct SwiftPM commands, pass `--scratch-path` yourself. Never run concurrent worktrees into the same scratch path.

If `/Volumes/MuesliBuildCache/muesli-spm` is mounted, prefer it. Otherwise scripts fall back to `~/Library/Caches/muesli-spm`.
