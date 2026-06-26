# Muesli Review Standards

This document is advisory. It captures review priorities and recurring bug
patterns in Muesli, but it is not exhaustive. Reviewers should still flag new
correctness, privacy, performance, lifecycle, release, and UX risks even if they
are not named here.

Use these standards as anchors for judgment, not as a whitelist. The goal is to
make reviews stricter on the failure modes that matter most for a latency-
sensitive macOS audio app while avoiding noise around explicit product choices.

## Review Philosophy

Muesli is a local-first macOS app for dictation, meeting recording, transcription,
and automation. Most serious regressions in this codebase are lifecycle bugs, not
syntax bugs: UI stalls, SwiftUI invalidation loops, stale async callbacks, audio
session races, passive detection false positives, memory growth, and permission
or persistence drift.

When reviewing, prioritize:

1. No memory leaks or unbounded resource growth.
2. No SwiftUI/AppKit layout loops.
3. No expensive synchronous work on `MainActor`.
4. No audio, dictation, or meeting lifecycle races.
5. No privacy leaks of user content.
6. No permission, signing, update, or persistent-state regressions.

## Severity Levels

- **P0**: Data loss, privacy leak, crash on launch, broken signing/notarization,
  broken auto-update, corrupt persistent state, or a regression that can lose
  user audio/transcripts.
- **P1**: User-visible feature regression, unbounded memory/CPU growth,
  MainActor blocking in a hot path, permission bypass, broken audio/dictation
  lifecycle, or monitor behavior that can repeatedly prompt/record/detect the
  wrong thing.
- **P2**: Edge-case UX bugs, missing resilience in lower-frequency paths,
  incomplete tests for changed behavior, or maintainability issues likely to
  cause future bugs.
- **P3**: Naming, comments, small cleanup, stylistic consistency, or low-risk
  refactors.

Do not label a product preference as P1 unless it violates an explicit invariant
or creates a correctness, privacy, performance, or data-loss risk.

## Product Decision vs Code Defect

Reviewers must distinguish product decisions from implementation defects.

Examples of blockers:

- A feature starts without the required macOS permission.
- A timer performs expensive synchronous work on the main thread.
- User content is logged or transmitted unexpectedly.
- A queue, cache, snapshot list, transcript list, or audio buffer is unbounded.
- A stale callback can mutate a newer recording, meeting, import, or sync.

Examples of product feedback:

- Preferring one prompt instead of several when the queue is intentionally capped.
- Preferring a different visual treatment for a product-approved prompt.
- Wanting a feature under a different settings section when copy and behavior are
  already explicit.
- Wanting a different default when the current default is deliberate and tested.

If behavior matches an explicit product decision, classify the concern as product
feedback unless it also violates a technical invariant.

## Privacy & Data Handling

Never log, persist unexpectedly, or transmit private user content. Sensitive data
includes transcript text, dictated text, correction pairs, meeting notes, screen
text, clipboard contents, API keys, OAuth tokens, file contents, and raw prompts
or responses.

Acceptable debugging metadata includes counts, durations, booleans, state names,
reason codes, non-content identifiers, and redacted error categories.

Any new path that sends user content to a remote service must be explicit,
gated, documented in UI or settings where appropriate, and covered by tests or a
clear validation plan.

Local-only processing is materially different from network transmission, but it
still needs correct permission gating and clear user-facing copy when it reads
from other apps, the screen, the clipboard, microphone, calendars, or files.

## macOS Permissions

Be precise about permission type:

- Microphone permission is for audio recording.
- Accessibility permission is for AX text/control and some focused-app context.
- Screen Recording permission is for screenshots or screen pixels.
- System audio capture through the CoreAudio tap path uses audio-capture TCC
  (`kTCCServiceAudioCapture`) and does not require Screen Recording.
- Calendar permission is for EventKit calendar data.
- Apple Events or ScriptingBridge access can control or query other apps and must
  not launch apps unexpectedly.

Do not conflate Accessibility with Screen Recording. If a feature uses AX text,
review AX trust and restart behavior directly instead of requiring screen capture
unless pixels are actually read.

If a permission requires app restart or relaunch, review the full pending-intent
flow: request, persistence, process identity, timeout, post-relaunch reconcile,
and failure/denial path.

Rebuilding or relaunching dev builds should preserve app data and permissions
unless the user explicitly asks for a reset.

## MainActor & UI Responsiveness

Block PRs that introduce expensive or potentially blocking work on `MainActor` in
timers, polling loops, settings refreshes, hotkey paths, audio startup, monitor
loops, or SwiftUI lifecycle callbacks.

High-risk APIs and work include:

- ServiceManagement / `SMAppService`
- EventKit
- CoreAudio queries and audio graph setup
- Accessibility traversal
- AppleScript / ScriptingBridge
- LaunchServices/process scanning
- file IO
- network calls
- model inference or warmup
- spell checking on many candidates
- large text diffing or alignment
- sync engines and CloudKit work

Expected pattern:

- MainActor owns UI state and small state transitions.
- Background actors/tasks collect signals or perform heavy work.
- MainActor receives small pure values for rendering.
- Long-running work has cancellation and does not hold UI locks.

## SwiftUI & AppKit Layout Safety

SwiftUI and AppKit lifecycle callbacks can create CPU and memory failures even
when individual operations look small.

Reviewers should flag unconditional state writes from:

- `GeometryReader`
- `PreferenceKey` / `onPreferenceChange`
- `onAppear` / `onChange`
- animation completion callbacks
- repeating timers
- async `Task` callbacks
- AppKit delegate callbacks bridged into SwiftUI state

State writes from layout or lifecycle callbacks must be guarded by equality,
threshold, identity, or explicit no-op checks. Avoid generating fresh IDs during
view recomputation unless identity changes are intentional.

Known pattern from repo history: a `GeometryReader` and `onPreferenceChange` loop
that repeatedly mutated `@State` caused a SwiftUI layout loop, 100% CPU, and
multi-GB memory growth. Review similar changes aggressively.

## Memory & Resource Stability

Reviewers must look for unbounded growth in:

- arrays, dictionaries, queues, caches, and sets
- transcript chunks and meeting turns
- audio buffers and `Float` arrays
- tasks, continuations, callbacks, and observers
- AX snapshots or screen/context samples
- model/session resources
- sync tombstones and pending operations

Long-lived collections need one of:

- explicit cap
- pruning/windowing
- lifecycle cleanup
- bounded persistence
- documented reason why growth is limited by another invariant

Timers, observers, delegates, audio taps, tasks, and notification subscriptions
must be invalidated or cancelled on teardown. Closures stored by controllers,
views, timers, or panels should avoid retain cycles.

For meeting/audio features, memory should be validated with realistic meeting
duration, not only unit tests.

## Audio, Dictation & Meeting Lifecycle

Audio and meeting lifecycle changes are high risk. Reviewers should flag:

- stale delegate callbacks affecting newer recordings
- missing run IDs, session IDs, or meeting IDs before applying async results
- cleanup that can tear down a newer active session
- route changes without teardown and restore invariants
- blind media play/pause toggles
- meeting and dictation competing for the same mic/session
- system audio, mic, or AEC failures that are swallowed silently
- finalization paths that can block on hidden modal UI
- startup paths that show "ready" before first audio is captured

Expected pattern:

- Session identity is checked before applying async results.
- Start, stop, cancel, failure, and route-change paths are idempotent.
- Cleanup restores overridden input/output state.
- Failures are surfaced or recorded in state.
- Focused tests cover state-machine transitions and stale callbacks.

## Monitors & Passive Detection

Passive monitors must be conservative. They should not infer user intent from
weak global signals alone.

Reviewers should flag:

- monitors started under the wrong feature flag
- polling without bounded interval, total window, traversal, or cancellation
- fallback probes that can launch closed apps
- global mic/audio/browser activity treated as meeting intent without stronger
  evidence
- cached stale state treated as current
- no cancellation when a related feature is disabled
- repeated prompts without debounce, caps, or user controls

Acceptable polling requires a clear budget: interval, total duration, node/work
cap, memory cap where relevant, and cancellation path.

## Persistence & Migration

Persistent model changes must tolerate old configs and partially corrupt optional
metadata.

Reviewers should flag:

- one corrupt item wiping an entire collection when item-level resilience is
  possible
- missing defaults for new config fields
- unbounded persisted lists
- schema changes without decode tests
- migrations that can lose custom words, transcripts, meetings, settings, auth
  state, or sync identity
- app data changes that make dev rebuilds appear like permission resets or
  onboarding resets

For small capped state, config JSON can be acceptable. For large, frequently
queried, or growing history, prefer structured storage.

## Logging & Telemetry

Logs should make debugging possible without exposing user content.

Prefer:

- counts
- durations
- state names
- reason codes
- booleans
- non-content IDs
- redacted error categories

Avoid:

- transcript text
- dictated text
- correction pairs
- clipboard contents
- screen text
- API keys or tokens
- prompts, responses, or meeting content

Telemetry must be anonymous or explicitly consented to, and should not include
private content.

## Build, Signing & Release Safety

Signing, entitlements, provisioning profiles, Sparkle metadata, release scripts,
bundle IDs, iCloud containers, app groups, and update URLs are high-risk.

Reviewers should flag:

- changed bundle identifiers or entitlements without explanation
- changed iCloud/app-group access without matching provisioning intent
- release metadata that does not match artifacts
- scripts that write package-local SwiftPM `.build` artifacts in many worktrees
  when a shared scratch path is expected
- dev-lane changes that reset permissions or app data unexpectedly

Use shared SwiftPM scratch paths for local and CI-heavy work where supported.

## Testing Expectations

Tests should scale with risk.

- Persistence changes need decode, default, and round-trip coverage.
- Detector logic needs true-positive and false-positive tests.
- Audio lifecycle changes need state-machine and stale-callback tests.
- Monitor changes need false-positive, cancellation, and bounded-work tests.
- SwiftUI/AppKit logic should extract pure decision helpers where full UI tests
  are brittle.
- Performance fixes should include the sampled root cause in the PR body when
  possible.

Do not demand brittle full UI tests unless the repo has a reliable harness for
that UI surface. Prefer focused pure tests plus manual validation notes for
non-activating AppKit panels and OS permission prompts.

## Known Regression Classes In This Repo

These examples are not exhaustive, but reviewers should use them as high-signal
patterns:

- Settings polling caused UI stalls by calling ServiceManagement status from a
  1-second timer.
- Meeting detection caused jank when CoreAudio, AppleScript/AX, LaunchServices,
  and EventKit work ran on the main actor.
- SwiftUI marquee layout entered an invalidation loop from unconditional
  `@State` writes in layout callbacks.
- Live transcript and AEC work previously needed memory-growth fixes and
  monitoring.
- Meeting and dictation audio paths repeatedly needed stale callback, route
  change, and cleanup hardening.
- Browser and calendar meeting detection had false positives from weak or stale
  signals.
- Hidden modal prompts during recording finalization blocked lifecycle flows.
- Browser probing by bundle ID risked relaunching apps the user had closed.

## What Not To Block On By Default

Do not block solely because:

- a bounded polling loop exists and an event stream might be cleaner
- small capped state is stored in config JSON
- a product-approved UX behavior differs from reviewer preference
- a broad refactor would be nice but is unrelated to the PR
- full UI automation is missing for an AppKit or OS-permission surface without a
  reliable harness

These can still be comments, follow-ups, or product feedback.

## Reviewer Checklist

Before approving, check:

- [ ] Does any timer, polling loop, or settings refresh call expensive APIs on
      `MainActor`?
- [ ] Does any SwiftUI layout or lifecycle callback mutate state
      unconditionally?
- [ ] Are all long-lived arrays, queues, caches, snapshots, and buffers bounded
      or cleaned up?
- [ ] Are timers, observers, tasks, delegates, and panels cancelled or
      invalidated?
- [ ] Can stale async callbacks affect a newer meeting, dictation, import, sync,
      or prompt session?
- [ ] Does audio startup and teardown preserve route, media, and recording state?
- [ ] Can passive detection produce false positives from weak or global signals?
- [ ] Does disabling a feature stop in-flight monitoring or background work?
- [ ] Are persistent config or database changes backward-compatible?
- [ ] Are private user contents excluded from logs and telemetry?
- [ ] Are permission prompts and restart/reconcile flows explicit and correct?
- [ ] Are release, signing, entitlement, and app identity files untouched or
      clearly justified?
