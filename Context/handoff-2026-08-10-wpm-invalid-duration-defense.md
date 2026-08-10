# WPM invalid-duration defense handoff (2026-08-10)

## Scope

This branch makes macOS WPM calculations robust to historical synced dictations that contain words but no valid measured duration. It does not alter sync transport or delete/rewrite user records.

## Branch

- Repository: `muesli`
- Branch: `codex/wpm-invalid-duration-defense`
- Base: `origin/main` at `b4b092d6`
- Code change: Ignore untimed records in WPM metrics

## Root cause and behavior

Historical iOS CloudKit payloads wrote `durationSeconds = 0` and omitted start/end times. Once Production backlog synchronization began working, macOS added those rows' word counts to the WPM numerator while their zero durations contributed nothing to the denominator, producing values such as `116671` WPM.

The fix:

- continues counting every record and word in total-word/session metrics;
- computes WPM using only rows with `duration_seconds > 0` for both numerator and denominator;
- applies the same rule to dictation, meeting, and Insights pace aggregates.

## Validation

- Focused regression tests passed.
- Full `DictationStoreTests|InsightsTests` run passed: 144 tests.
- Privacy-safe aggregate-only validation against the existing MuesliDev database found 2,591 rows and 92,416 total words, but only 11 words attached to positive measured duration. Under the corrected formula the current WPM is approximately 139 instead of six digits.
- No transcript text or record identifiers were queried.
- `/Applications/MuesliDev.app` was rebuilt over the existing `com.muesli.dev` identity with explicit Production CloudKit entitlement for `iCloud.com.mueslihq.muesli`; existing Application Support data was preserved.

## Companion iOS repair

The iOS branch `codex/ios-cksyncengine-migration` now uploads recoverable start/end/duration timing and performs a one-time, environment-scoped repair for existing eligible rows. The Mac defense remains necessary for records whose historical timing cannot be recovered.

## Remaining physical checks

1. Let the updated Production-entitled MuesliDev iOS build run its repair.
2. Confirm the Mac dashboard immediately shows a plausible WPM.
3. Sync a new timed iPhone note and confirm WPM remains plausible after receipt.
