# PR #333 focused #320 reduction

## Scope decision

The earlier branch tip combined the original #320 fix with a 39-file meeting lifecycle expansion in `6d515c45`, then added a large follow-up layer in `561afad3`. The broad tip is preserved locally as `archive/pr333-full-lifecycle-20260720` at `5c36d65b`.

The active branch now preserves contributor history but reverses the broad lifecycle expansion. Its net diff against current `origin/main` is intentionally limited to meeting microphone route recovery, the Meetings microphone selector, concise copy and live-preview semantics, and privacy-safe failure telemetry.

## Focused behavior

- Meeting AVAudioEngine capture can rebuild after an input configuration change.
- Objective-C exceptions raised by AVFAudio graph mutations are converted to Swift errors for meeting capture only.
- Dictation uses the same default-off recorder path as `origin/main`; it does not opt into meeting route recovery.
- Meetings store a microphone choice independently from Dictation. Existing users default to Automatic instead of inheriting a Dictation device.
- An active meeting keeps the current recorder alive while a replacement starts. The handoff completes only after the replacement produces its first audio buffer.
- Failed or timed-out replacements are cancelled and the existing recorder continues.
- Generation checks reject stale replacement callbacks during rapid route changes, pause, stop, and discard.
- Meeting microphone capture failures emit allowlisted TelemetryDeck diagnostics without device names, UIDs, transcript text, paths, or raw error descriptions.

## Settings semantics

- `Show transcript on hover` controls whether recent completed transcript segments appear beside the waveform.
- `Live preview model: Off` disables low-latency streaming partials. It does not hide already completed transcript segments.
- Turning preview off during a meeting keeps the existing mainline behavior: active streaming partial sessions stop and partial tails clear.
- Turning preview on or changing its model still takes effect on the next meeting. That separate preview-engine restart lifecycle is outside #320.

## Validation target

Validation covers the focused route, config, and diagnostic suites, the required meetings CI shard, the complete Swift package test suite, and a real meeting that changed from the built-in microphone to AirPods while recording.

## Follow-up hardening

The focused branch now closes three meeting-only lifecycle gaps without restoring the broad `6d515c45` implementation:

- An active microphone failure enters a terminal failed state and immediately rebuilds the same selected route. A later same-route selection can retry if the first recovery fails. The replacement becomes active only after its first non-empty buffer.
- Replacement preparation and startup run on a dedicated worker lane. Its wall-clock timeout is scheduled before startup, and stop or discard detaches pending work without waiting for a blocked CoreAudio start or disposal.
- Meeting-enabled `StreamingMicRecorder` reads the input format and selects an explicit input device through the Objective-C exception bridge. Dictation retains its existing default path.

Deterministic coverage now includes active failure recovery, failed same-route retry, blocked-start timeout, stop during blocked startup, discard during blocked startup, rapid A to B to C route changes, pause during a pending handoff, active failure during a pending handoff, stop and discard racing with first-buffer promotion, repeated timeouts without stale promotion, failed AVAudioEngine restart state, stale callback rejection, and protected AVFAudio input reads and routing.

The route-aware recorder suite is serialized at the suite level because several cases intentionally block dedicated dispatch workers to prove stop, discard, and timeout behavior. Concurrency remains inside each test, while unrelated race harnesses no longer starve one another on smaller CI runners.

The four suites that exercise this work are now part of the required meetings CI shard:

- `AudioGraphExceptionBridgeTests`
- `DiagnosticIncidentTests`
- `DictationAudioRouteControllerTests`
- `RouteAwareMeetingMicRecorderTests`

`scripts/test_ci_test_shards.sh` also runs in required CI. It discovers every Swift Testing `@Suite`, rejects filters that no longer match a suite, and rejects any newly added suite that is missing from all required shards. The 82 suites that predate sharding are recorded in a checked baseline so this guard can be introduced without silently expanding the scope of every existing pull request.

Validation on 21 July 2026:

- `RouteAwareMeetingMicRecorderTests`: 19 passed.
- `AudioGraphExceptionBridgeTests`: 2 passed.
- Required meetings CI shard: 335 tests in 21 suites passed.
- Complete Swift package: 1,428 tests in 139 suites passed under concurrent execution.
- CI shard assignment guard: 57 assigned suites and 82 legacy-unsharded suites verified.
- The eSSD sparse-bundle cache was not mounted, so validation reused `/private/tmp/muesli-spm-pr333-greploop` instead of creating a new local build cache.

## Hardware validation

The reduced DevA build passed the AirPods route-change scenario on 21 July 2026. Meeting 32, `India Student Protest Coverage`, recorded for 147.3 seconds from 13:19:09 to 13:21:36 PDT and completed with a 571-word transcript. CoreAudio moved the input route from device 142 to 156 to 161 around 13:19:42 to 13:19:43, including the AirPods sample-rate transition from 48 kHz to 24 kHz. Local `You` speech is present before and after the transition through 13:21:18. Muesli did not crash or report a capture failure.
