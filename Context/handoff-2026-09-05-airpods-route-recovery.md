# Context Handover — AirPods Route Recovery

- Session Date: 2026-09-05 (Asia/Kolkata)
- Repository: `/Users/pranavhari/Desktop/hacks/muesli`
- Branch: `codex/meeting-recording-attribution-guard`

---

## Session Objective

Understand and reduce the CoreAudio pressure, microphone capture failures, and UI stalls reported around meeting recording and audio-device changes. Preserve the reliable meeting-detection and one-global-tap design, remove unnecessary attribution work, and make an active meeting recover safely when AirPods connect or disconnect. The immediate unfinished objective is to live-validate the latest DevC AirPods recovery implementation before committing or pushing it.

## What Got Done

### Historical and production context established

- The investigation began from reports that connecting or disconnecting microphones/Bluetooth headphones can make Muesli stop working until restart. The user also supplied GitHub issues `#381`, `#480`, and `#484`, plus a user report in Downloads describing prolonged CoreAudio/system slowness.
- PR `#491` (now merged into `origin/main` at `4e32a481`) hardened meeting capture: one global CoreAudio tap per meeting, evidence-driven recovery, reduced VQE/AEC CPU work, and suppression of full process attribution while recording. It did not redesign idle meeting detection, fix the floating waveform stop button, or guarantee every microphone-route failure.
- TelemetryDeck was queried during the investigation. The data supported elevated microphone-failure incidence but did not prove that all failures have one cause. Never copy the short-lived PAT from the conversation into source, tests, logs, or handoffs.
- Earlier profiling showed that deliberate full CoreAudio process attribution can drive `coreaudiod` to roughly 112–159% transient CPU. A separate long-lived Muesli instance under another macOS account was also seen performing attribution approximately every nine seconds and causing shared `coreaudiod` spikes. Multi-instance DevB/DevC testing can therefore confound attribution: the app consuming CPU need not be the app transcribing.
- Repeated normal stops, abrupt quits, SIGKILL experiments, and AirPods-triggered SIGKILL did not deterministically leave a permanent leaked global recording tap. The stronger evidence is that expensive attribution and route churn can pressure shared CoreAudio, while microphone graphs can become unhealthy during route changes.

### Committed lifecycle and attribution work on this branch

The branch is based directly on current `origin/main`, is `0` behind and `3` commits ahead, and the three commits are already on `origin/codex/meeting-recording-attribution-guard`:

1. `f516a5b9 Refine meeting detection lifecycle modes`
2. `e4136099 Bound CoreAudio meeting attribution by activity episode`
3. `0bc8dc09 Keep meeting liveness attribution authoritative`

This work replaces scattered lifecycle booleans with a deliberately small meeting-detection lifecycle model, bounds expensive CoreAudio attribution to an activity episode, and retains authoritative source liveness so an active Google Meet is not declared ended merely because a weaker signal disappears. State-transition tests encode invalid transitions rather than relying on call-site discipline.

The design intentionally does **not** put CoreAudio/browser work on the MainActor or inside a UI-stopping actor. State ownership is serialized, but slow observation and side effects remain outside the state transition itself.

Live checks completed before the AirPods work:

- Google Meet was detected and transcription started.
- An early iteration incorrectly auto-stopped while Meet was still live; the liveness-authority fix corrected that.
- On retest, ending Google Meet produced the top-right “signal lost” notification and its Stop Transcribing action worked.
- Zoom start detection and meeting-end behavior were also exercised successfully.
- Muesli-owned microphone use (dictation, handsfree, CUA, Quill, and similar modes) must stay distinct from external-meeting attribution; microphone activity alone is not proof of a meeting.

### First AirPods recovery implementation

After reproducing a freeze on AirPods connection, the first uncommitted implementation made route processing single-owner and burst-aware:

- `AudioRouteController` classifies route signals as default-output, default-input, or inventory events; coalesces bursts with a 1.5-second settle delay and 3-second maximum; and uses cached inventory for default-device changes instead of immediately re-enumerating every CoreAudio device.
- Unused device name/sample-rate reads were removed from output-route description.
- `StreamingMicRecorder` now separates “observe configuration changes” from “recover after them.”
- Meeting child recorders disable their own configuration-change observation; the route-aware outer recorder is the sole restart owner. This prevents a child `AVAudioEngine` observer from racing the higher-level handoff and creating a restart feedback loop.
- Route callbacks avoid a redundant second routing-cache refresh in `DictationAudioSessionManager`/`MuesliController`.
- Focused and full automated tests passed, but the subsequent live AirPods test still froze. Therefore this first layer was necessary but insufficient.

### Second AirPods recovery implementation — built, not yet live-proven

The latest uncommitted layer removes the remaining synchronous HAL dependency from the recovery trigger:

- `SystemAudioCapturing` exposes a lightweight `onRouteChange` signal.
- `CoreAudioSystemRecorder` emits the default-output change on a dedicated signal queue. It timestamps the transition but does not rebuild the global system-audio tap. This preserves the intended one-global-tap-per-meeting behavior.
- `MeetingSession` wires the signal to `MeetingSystemAudioWatchdog` and clears it across failed start, discard, and stop paths.
- `MeetingSystemAudioWatchdog.noteRouteChange()` records a pending microphone probe. After the existing route-settling window, the next watchdog tick reads only cached `lastMicCallbackAt`; it does not call CoreAudio/HAL. If callbacks are absent or at least three seconds stale, it emits `mic_callbacks_stale_after_audio_route_change` and asks the existing `MeetingMicRecoveryCoordinator` for its bounded safe handoff.
- The safe handoff retains the old recorder until a candidate delivers its required callback/non-zero samples. Existing timeouts, single-pending-candidate policy, cooldown, and per-episode retry cap prevent graph accumulation.
- Added tests cover route-change notification without system-tap rebuild, stale/fresh/deferred mic probes, coalescing/cached inventory, avoiding duplicate HAL refresh, and the single recovery owner.

All **2,004** native tests in **176** suites passed with this latest implementation. DevC was rebuilt, signed, installed, and launched from the complete LocalVQE runtime. Signature and LocalVQE runtime verification passed. This is automated/build evidence only; the latest recovery path has not yet survived a physical AirPods connect/disconnect test.

### DevC build and runtime state

- Installed app: `/Applications/MuesliDevC.app`
- PID immediately after the latest rebuild: `36241` (re-resolve before profiling; it may have changed or exited).
- LocalVQE source ref: `134aa7fd73d6a61dcab24c4f0c70bc49a38c0494`
- Complete runtime: `/Users/pranavhari/Library/Caches/muesli-localvqe/runtime/134aa7fd73d6a61dcab24c4f0c70bc49a38c0494/arm64/lib`
- Correct build form:

  ```bash
  MUESLI_LOCALVQE_LIB_DIR=/Users/pranavhari/Library/Caches/muesli-localvqe/runtime/134aa7fd73d6a61dcab24c4f0c70bc49a38c0494/arm64/lib ./scripts/dev-test.sh --lane C --local-only
  ```

- Runtime verifier: `/Users/pranavhari/.codex/skills/muesli-dev-build-lanes/scripts/verify_localvqe_runtime.sh`
- A warm SwiftPM cache does not imply that a fresh worktree contains the generated LocalVQE dylibs. The dev-build skill was updated during this conversation to prevent repeating that packaging failure.
- Latest clean profile directory: `/private/tmp/muesli-devc-airpods-route-recovery.2gFuVO`
- Baseline at approximately 13:34:22 IST: DevC `0.4%` CPU, RSS `185264 KB`; `coreaudiod` and `audiomxd` approximately `0%`.
- Process inspection was sandbox-limited at handoff time, so verify whether `/private/tmp/muesli-devc-detection-profiler.sh` is still running before relying on this capture.

## What Didn't Work

- Treating abrupt process death as the primary reproducer did not establish a persistent leaked tap. Normal quit, “Quit Anyway,” terminal kill, SIGKILL, and AirPods-triggered SIGKILL generally left teardown clean or allowed CoreAudio state to clear.
- Repeated AirPods cycling can increase reproduction probability, but it is not required to understand a deterministic captured failure. A single instrumented route transition is preferable once timestamps and stacks are available.
- A per-process “is system output active” playback monitor/watchdog gate was explored and rejected after historical verification. Muesli intentionally owns one global process tap for a meeting; creating per-process taps or tearing the tap down during ordinary silence would be a regression and adds attribution pressure.
- The first AirPods fix—burst coalescing, cached inventory, and a single mic-restart owner—did **not** solve the live freeze. One synchronous HAL property read was enough to wedge the route-inspection queue while CoreAudio was unhealthy.
- The first Google Meet lifecycle refactor briefly auto-stopped while the meeting was still live because it treated a weaker attribution result as authoritative. Commit `0bc8dc09` corrected the authority model; keep this regression covered.
- A DevC rebuild initially lacked the complete LocalVQE dylib set even though compilation caches were warm. Rebuilding/pointing at the complete pinned runtime fixed packaging. Never use `MUESLI_ALLOW_MISSING_LOCALVQE=1` for a normal signed lane.
- The floating waveform Stop button remained unresponsive in separate tests. The status-bar stop path worked. This likely relates to old PR `#374`, but it is explicitly out of scope here.
- Acoustic echo cancellation and transcript quality were intentionally separated from OS audio-route lifecycle. Do not dilute this work with AEC tuning unless new evidence directly connects it to the route deadlock.

## Key Decisions

- Preserve exactly one global system-audio tap for the duration of a meeting. Silence and ordinary route changes do not recreate it; rebuild only on positive failure evidence.
- Use event-driven signals and cached timestamps for the recovery decision. Never synchronously query HAL from MainActor/UI paths, from the system-tap sample queue, or as a prerequisite for noticing that callbacks stopped.
- Keep one owner of microphone graph recovery. Nested recorders may protect their own graph operations but must not independently initiate competing route restarts.
- Recovery is a bounded handoff, not “stop everything and hope”: keep the last working graph until the candidate demonstrates audio/callback viability.
- Meeting detection may still need a low-frequency bounded resynchronization for missed OS/browser events, but full CoreAudio process attribution must be activity-episode bounded and suppressed during recording except where authoritative meeting-end liveness requires it.
- Treat Muesli’s own mic consumers separately from external meeting detection.
- Do not commit or push the current 12-file AirPods diff until the physical DevC route-change test passes or the remaining failure is captured with a fresh stack.

## Lessons Learned

- High `coreaudiod` CPU does not by itself mean Muesli leaked four system taps. Full process attribution, multiple installed/running Muesli variants, a process under another macOS account, default-device aggregates, and mic graph churn all affect the shared daemon.
- The system tap and microphone path have different route semantics. The global process tap can survive a default-output change while AVAudioEngine/HAL input graphs lose callbacks and need a guarded handoff.
- Debouncing reduces work but cannot make a blocking HAL call safe. A single `AudioObjectGetPropertyData` can wait behind CoreAudio’s command gate for many seconds.
- Physical Bluetooth route transitions are required evidence. Passing unit tests proves policy and callback wiring, not that macOS will avoid or recover from a HAL stall.
- Build verification must cover packaged runtime contents and signature, not merely successful compilation.
- Lifecycle correctness depends on explicit signal authority. “Something became inactive” is not interchangeable with “the meeting ended.”

## Nuances & Edge Cases

- First reproduced freeze profile: `/private/tmp/muesli-devc-airpods-route.qs1Al1`; stack sample: `/private/tmp/muesli-devc-airpods-route.qs1Al1/MuesliDevC-hung.sample.txt`.
  - Main thread was blocked in `AVCaptureHALDevice._refreshConnectionID -> _removePropertyListeners -> AudioObjectRemovePropertyListener -> CoreAudio guard wait`.
  - The dictation route queue was simultaneously blocked building a full route snapshot.
  - Multiple AVAudioIOUnit queues were in rebind/start/stop work and logs showed repeating `CADefaultDeviceAggregate` transitions.
- The live test after the first fix is in `/private/tmp/muesli-devc-airpods-fix-live.jdPTKD`; stack: `/private/tmp/muesli-devc-airpods-fix-live.jdPTKD/MuesliDevC-post-airpods.sample.txt`.
  - Markers: profiler armed 13:21:41; AirPods connected 13:22:05; AirPods cased 13:25:27; Google Meet ended 13:26:08.
  - `coreaudiod` stayed around 110–150% and DevC around 60–90% for several minutes.
  - Remaining block: `refreshRouteCache -> makeRouteSnapshot -> currentOutputRouteClassification -> transportType -> AudioObjectGetPropertyData`, waiting on the CoreAudio `HALB_CommandGate` mutex.
  - Only one Muesli default aggregate episode was visible around each physical transition. This contradicted the hypothesis that the live freeze was caused by repeated global system-tap creation.
  - Casing AirPods allowed `coreaudiod` to fall to roughly 3%, but that does not count as recovery: the user also ended the meeting, and the route was reversed.
- `MeetingDetection` fallback evaluations also took 7–23 seconds while HAL was unhealthy. The lifecycle loop itself should remain nonblocking; expensive observation must not execute inline with state ownership.
- The current watchdog threshold is intentionally based on callback staleness. Verify it does not restart the mic for a fresh callback stream and does not fire while the route-settling gate is active—tests cover both, but live logs should confirm.
- macOS itself may still stall `coreaudiod`. The achievable guarantee is that Muesli does not amplify the stall, does not freeze its UI waiting on HAL, and performs bounded mic recovery after the route signal. This implementation cannot guarantee that third-party drivers or CoreAudio never fail.
- The Google Meet “signal lost” notification is expected when the detected meeting source ends while transcription continues; it should not appear merely because AirPods changed route.

## Codebase Map (Files Touched)

### Modified

- `native/MuesliNative/Sources/MuesliNativeApp/AudioRouteController.swift`
  - Route event classification, cached inventory, burst coalescing, bounded settle timing, and serialized route cache refresh.
- `native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift`
  - Lightweight route callback and dedicated signal queue; default-output changes no longer rebuild the global tap.
- `native/MuesliNative/Sources/MuesliNativeApp/DictationAudioSessionManager.swift`
  - Optional routing-cache refresh so route callbacks do not immediately repeat a HAL query.
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingMicRecording.swift`
  - Meeting child recorders opt out of independent configuration-change observation.
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift`
  - Wires/clears the system-audio route signal to the meeting watchdog.
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingSystemAudioWatchdog.swift`
  - Pending post-route mic probe and cached callback-staleness bridge to bounded mic recovery.
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliController.swift`
  - Route warm-up avoids duplicate cache refresh.
- `native/MuesliNative/Sources/MuesliNativeApp/StreamingMicRecorder.swift`
  - Separates observing input configuration changes from performing recovery.
- `native/MuesliNative/Tests/MuesliTests/CoreAudioSystemRecorderTests.swift`
  - Verifies lightweight route notification/no global-tap rebuild.
- `native/MuesliNative/Tests/MuesliTests/DictationAudioRouteControllerTests.swift`
  - Covers route-event coalescing and cached inventory behavior.
- `native/MuesliNative/Tests/MuesliTests/DictationAudioSessionManagerTests.swift`
  - Covers suppression of the duplicate routing-cache refresh.
- `native/MuesliNative/Tests/MuesliTests/MeetingSystemAudioWatchdogTests.swift`
  - Covers stale, fresh, and settling post-route microphone probes.

At handoff, these 12 files are modified but uncommitted: **345 insertions and 36 deletions**. Preserve them; do not reset or overwrite them.

### Read

- `Context/handoff-2026-09-03-meeting-audio-capture-hardening.md`
- `Context/handoff-2026-09-03-meeting-attribution-suppression-followup.md`
- `scripts/muesli_spm_cache.sh`
- `scripts/localvqe_runtime.sh`
- `scripts/dev-test.sh`
- `/Users/pranavhari/.codex/skills/muesli-historical-context/SKILL.md`
- `/Users/pranavhari/.codex/skills/muesli-dev-build-lanes/SKILL.md`

### Related

- PR `#491`: merged meeting audio capture hardening and immediate base of this branch.
- PR `#374`: old floating-waveform stop-button work; separate follow-up.
- Issues `#381`, `#480`, `#484`: microphone/device failure and AEC CPU reports that motivated investigation. Do not claim they are all closed by this route fix without production evidence.
- Meeting lifecycle implementation and tests introduced by commits `f516a5b9`, `e4136099`, and `0bc8dc09`.
- Profiling script used during live runs: `/private/tmp/muesli-devc-detection-profiler.sh`.

## Next Steps

1. Check `git status` first and preserve all 12 modified files plus this handoff. Confirm the branch remains based on current `origin/main`; fetch/rebase only if upstream changed, and do not discard local edits.
2. Re-resolve the DevC PID and check whether the clean profiler for `/private/tmp/muesli-devc-airpods-route-recovery.2gFuVO` is still alive. If not, start a fresh capture and write exact user-action markers to `markers.log`.
3. Put AirPods in the case/disconnect them. Start a Google Meet, manually start transcription in DevC, speak, and confirm both waveform movement and hover live preview before changing the route.
4. Connect AirPods once. Do not case them to escape the failure. Wait at least 10–15 seconds, keep speaking, and verify:
   - UI/waveform/hover preview stay responsive or recover;
   - exactly one post-settle `mic_callbacks_stale_after_audio_route_change` recovery occurs only if callbacks actually became stale;
   - the global system tap is not recreated;
   - no repeated candidate graphs accumulate;
   - `coreaudiod` and DevC CPU settle rather than remaining above one core.
5. If it sticks, immediately capture a five-second sample of the current DevC PID before altering the route, retain unified logs, and identify whether any remaining MainActor/route queue/HAL call is blocking. Do not infer success from casing AirPods.
6. If connection recovers, case/disconnect AirPods and perform the same checks for the reverse transition.
7. End Google Meet while transcription remains active and verify the “signal lost” notification. Stop from the notification, then confirm mic/system taps and CPU tear down.
8. Run the full native suite again after any change. Rebuild DevC with the pinned complete LocalVQE runtime, verify packaged dylibs and signature, and repeat the physical transition once.
9. Only after a clean live pass, inspect the diff, commit the 12-file AirPods recovery as a coherent change, push the branch, and create/update its PR. Clearly distinguish the three already-pushed lifecycle commits from the latest uncommitted AirPods layer.
10. Keep separate follow-ups for the floating waveform Stop button (`#374`), broader idle detection/attribution redesign, and AEC/transcript quality.

## Open Questions

- Does the latest cached-callback watchdog recover both AirPods connection and disconnection without any synchronous HAL read entering the critical recovery path?
- Can `AVCaptureHALDevice` still block MainActor independently of Muesli’s route inspection, and if so, which Muesli API call instigates that AVFoundation listener removal?
- During a failing route transition, does the old mic recorder remain usable long enough for safe handoff, or does the OS invalidate both old and candidate graphs until the Bluetooth profile stabilizes?
- Is the three-second stale-callback threshold correct across slow Bluetooth negotiation, USB interfaces, aggregate devices, and muted-but-running input streams?
- Can the meeting-detection fallback path still synchronously touch HAL while CoreAudio is unhealthy, despite the lifecycle state machine being nonblocking?
- After local validation, do TelemetryDeck event names/reasons give enough production observability to distinguish permission errors, graph-start failures, callback starvation, and recovery exhaustion without collecting sensitive audio/device data?
- Should the activity-episode detection redesign and this AirPods route recovery remain one PR or be split after review? They share the CoreAudio-pressure goal but have different regression surfaces.
