# Issue #322 meeting microphone handoff

## Published work

- Issue: [#322 — Google Meet Microphone Inconsistency](https://github.com/Muesli-HQ/muesli/issues/322)
- PR: [#327 — Prevent meeting capture from disrupting the default microphone](https://github.com/Muesli-HQ/muesli/pull/327)
- Focused branch: `codex/fix-322-meeting-microphone`
- Base: `origin/main`

The PR contains five focused changes:

1. Avoid blocking meeting startup on CoreAudio route refresh.
2. Use the system-default streaming recorder when the desired meeting mic is already the system default.
3. Suppress repeated prompts for a meeting session that has already started recording.
4. Refresh cached routes when the CoreAudio device inventory changes, including selected-mic unplug/reconnect.
5. Apply cached microphone selections atomically so an immediate meeting start cannot consume the prior device ID while asynchronous route verification is pending.

## Diagnosis

Muesli represented the built-in/default microphone as an explicit meeting-device preference. This selected the app-scoped `AudioQueue` recorder even when the same physical microphone was already the macOS default used by the meeting client.

The deterministic diagnostic harness reproduced the issue shape:

- system-audio process tap started successfully
- microphone `AudioQueueStart` blocked for about 15 seconds
- start returned `kAudioQueueErr_CannotStart` (`-66681`)
- failed-queue cleanup blocked for about another 30 seconds

This supports the unnecessary explicit microphone graph and its CoreAudio lifecycle as the cause of the startup-order race. The fix is shared by all supported meeting applications and browsers; it is not Google Meet-specific.

A follow-up review found a narrower cache-ordering race: changing the selected microphone stored its UID immediately but left the prior device ID in the meeting snapshot until the route queue completed another CoreAudio inspection. The controller now caches UID-to-device-ID mappings, applies a cached selection under the same lock as the meeting snapshot, and reconciles every asynchronous refresh against the latest selected UID before committing it.

## Scope decision

The broader investigation branch is preserved locally as `codex/diagnose-issue-322-meeting-mic` at `223fb511`. It contains the opt-in stress harness and detailed meeting lifecycle diagnostics used to reproduce the failure.

Those diagnostics were intentionally excluded from PR #327 because some instrumentation still performed release-time callback bookkeeping and an additional `AudioQueueGetProperty` in the timing-sensitive startup path. The focused PR also excludes the unrelated speculative-dictation experiment and its revert history.

## Validation

- Historical local validation on commit `76b1fe8cbe533738baec37580fefebdf161e1988` from `codex/fix-322-meeting-microphone`: 85 focused tests passed across route selection, recorder behavior, meeting candidate resolution, media-session tracking, prompt suppression, and selected-mic hot-plug behavior.
- Historical full GitHub CI for `76b1fe8cbe533738baec37580fefebdf161e1988` passed in [run 29598233464](https://github.com/Muesli-HQ/muesli/actions/runs/29598233464). That run predates later PR-tip changes and does not validate the latest implementation.
- Local validation on commit `7e558ecf6174f4d5521a1964c82dedde17f40990` after the selected-mic cache hardening: 88 tests passed across the same five route, recorder, candidate-resolution, media-session, and prompt-state suites, including deterministic immediate-selection and unavailable-device cache regressions.
- Full GitHub CI for `7e558ecf6174f4d5521a1964c82dedde17f40990` passed in [run 29608356208](https://github.com/Muesli-HQ/muesli/actions/runs/29608356208).
- Muesli-first then Google Meet: both clients shared the built-in mic and participants heard the user.
- Google Meet-first then Muesli auto-detection: Muesli used `systemDefaultStreaming`; microphone and system-audio capture remained healthy.
- Discard while the external meeting remained active: teardown completed normally and the same session did not prompt again after cooldown.
- Chrome, Muesli, and CoreAudio were not restarted between the relevant live lifecycle transitions.

Earlier full-suite runs were noisy under combined system load, with independently passing flakes in streaming VAD, Nemotron timeout, and clipboard tests. PR CI is the source of truth for the complete suite.

## Follow-up

- Let CI and review rerun on the latest PR #327 commit before merging.
- If #322-like behavior returns, use the preserved diagnostic branch to collect a trace, but do not merge its release-time instrumentation without removing the callback/startup overhead.
- Repeat both startup orders with a non-default external microphone before release if hardware is available; the explicit route is intentionally retained for that case.
