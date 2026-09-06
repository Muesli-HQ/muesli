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


## Astra continuation — 2026-09-05, 15:41 IST

### Checkout and first physical retest

- On resumption the checkout was clean. The previous 12-file implementation and this handoff had already been committed as `923615b405b500d5fa52781809fd8dd50b89978d` (`Harden meeting audio route recovery`). No reset, rebase, or overwrite was performed. Remote main was verified unchanged at `4e32a481b729a1e6dd1ac55a334c8fc1971eb1bc`.
- Fresh capture: `/private/tmp/muesli-devc-airpods-astra.icTfIa`, original DevC PID `36241`.
- User confirmed working waveform and hover preview before connection. CoreAudio logs show a new default aggregate at 15:30:44; user reported AirPods connected at 15:31. Exact user-action time was not supplied; markers distinguish report times from observed events.
- **Physical connection test FAILED.** User reported delayed YouTube playback and DevC stopped updating. CoreAudio sustained about 105–117% CPU. The first post-connect sample had a responsive main loop, but the next sample captured all main-thread samples in `__DeviceIsAliveListener_block_invoke -> AVCaptureHALDevice._refreshConnectionID -> _removePropertyListeners -> AudioObjectRemovePropertyListener -> CAGuard::WaitFor`.
- Samples: `DevC-before-route.sample.txt`, `DevC-airpods-connected.sample.txt`, and `DevC-airpods-sustained.sample.txt` in the capture directory. The first connected sample also spent substantial route-queue time re-reading device names inside the input-device sorting comparator. AVAudioIOUnit rebinds were waiting on HAL gates.
- Casing AirPods eventually restored live preview and YouTube playback. This is reversal of the failing route, **not** a clean connection recovery. User ended Meet and confirmed the signal-lost notification appeared. DevC subsequently reached idle CPU; CoreAudio was about 3%.
- The original app launch had stderr connected to `/dev/null`, so exact watchdog/handoff counts cannot be established from that run. Unified logs and CPU evidence were retained. A daemon stack could not be obtained: `sample` required elevated process privileges, and `sudo -n` reported a password was required. No daemon restart was attempted.

### Corrections now uncommitted

- `CameraActivityMonitor.swift`: replace `AVCaptureDevice.DiscoverySession` plus private `_connectionID` KVC with public CoreMediaIO device/input-stream enumeration. Camera driver operations and listeners run on a serial worker, while MainActor holds cached state. A generation check rejects late events after stop/restart. AVFoundation discovery is the identified in-repo device-enumeration caller and a plausible source of the captured framework listeners; physical retesting must establish whether removing it eliminates the freeze.
- `AudioRouteController.swift`: sort already-fetched input names without HAL calls in the comparator; built-in candidates fetch each sort name once.
- `CameraActivityMonitorTests.swift`: regression coverage for a blocked discovery worker, responsive stop, late callback rejection, main-actor publication, and idempotent start.
- No changes to global tap lifetime, AEC policy, or the committed recovery layer.

### Automated/build evidence and pending physical validation

- Focused run: **40 tests / 3 suites passed** (`/private/tmp/muesli-astra-focused-tests.log`).
- Full native run after concurrency-warning cleanup: **2,007 tests / 177 suites passed** (`/private/tmp/muesli-astra-full-tests.log`), scratch path `/Users/pranavhari/Library/Caches/muesli-spm/worktrees/muesli/devC-test`.
- Rebuilt with the handoff's pinned complete LocalVQE runtime using `./scripts/dev-test.sh --lane C --local-only`; build log `/private/tmp/muesli-astra-devc-build.log`.
- Installed bundle deep signature and App Intents metadata verified. Functional LocalVQE verifier passed on both pinned source runtime and installed bundle (CPU backend loaded, 16 kHz / 256-sample hop context).
- Fresh rebuilt DevC PID `55709` (re-resolve). Capture `/private/tmp/muesli-devc-airpods-camera-fix.43hC19` armed at 15:40:56, including `devc-stderr.log` and `devc-stdout.log` via `open --stdout ... --stderr ...`. Profiler tool session `98058`.
- User has been asked to establish a working Meet/transcription baseline with AirPods cased before the connection cue. **The corrections have not yet passed a physical route-change test.** Continue connect, sample if stuck before reversing the route, then disconnect and meeting-end verification. Do not commit/push these corrections on automated success alone.


### Second physical retest and teardown correction — 15:59 IST

- The rebuilt camera-observer version detected camera ON and started exactly one global tap (`186`, aggregate `187`). On AirPods connection, stderr recorded one route-independent default-output notification and no system-tap rebuild. One route handoff timed out; there was no `mic_callbacks_stale_after_audio_route_change` request in the capture.
- User reported audio initially remaining on MacBook speakers and stalled preview, then audio/preview working after about 30 seconds with AirPods connected. Playback subsequently stalled again. **This was NOT a sustained physical pass.** CoreAudio remained around 105–115% CPU. `DevC-connected.sample.txt` and `DevC-recurrent-stall.sample.txt` show the main thread servicing the event loop, unlike the old AVCaptureHALDevice freeze; route inspection and AVAudioIOUnit rebinding still wait in HAL.
- User pressed Stop while leaving Meet/AirPods active. UI accepted it, playback still stalled, the previous meeting remained transcribing, and a new meeting-detection notification appeared. `DevC-stop-stalled.sample.txt` proves `MeetingSession.stop -> RouteAwareMeetingMicRecorder.stop -> StreamingMicRecorder.stop -> removeTap -> AVAudioEngineImpl::RemoveTapOnNode -> InitializeActiveNodesInInputChain` blocked on a recursive mutex. Because shutdown was sequential, the global system tap had not been stopped.
- DevC PID `55709` was terminated with SIGTERM at about 15:51:10 after capturing the blocked stop. CoreAudio logs confirm its global tap and default aggregate were deactivated. CoreAudio stayed above one core even after DevC exited and user closed Meet/YouTube. No other desktop Muesli variant appeared in the process inventory.
- User supplied an administrator daemon sample: `/private/tmp/muesli-devc-airpods-camera-fix.43hC19/coreaudiod-after-devc-exit.sample.txt.` (the final period is part of the actual filename). It shows HAL IO/control-list reconciliation waits and extensive property/IO-context requests. It does not identify Muesli as the sole source of continuing daemon pressure.
- Additional uncommitted corrections: `MeetingCaptureShutdown.swift` starts microphone/system shutdown independently on dedicated queues; `MeetingSession.stop()` uses it so a blocked mic cannot prevent requesting system-tap teardown. `StreamingMicRecorder` now stops the engine before removing its input tap during stop/cancel/configuration recovery. `MeetingCaptureShutdownTests.swift` tests independence with a deliberately blocked mic and preservation of each return value.
- New full-suite attempt compiled successfully but **hung in real HAL reads** on the unhealthy daemon. `/private/tmp/muesli-astra-shutdown-full-tests.log` is an incomplete run, not success. Samples: `/private/tmp/muesli-astra-test-runner.sample.txt` (runner `61235` blocked in controller initialization/device inspection and audio-bridge tests), `/private/tmp/muesli-astra-test-driver.sample.txt`. Runner and driver `60823` were terminated after diagnosis.
- User has been asked to restart CoreAudio via `sudo killall coreaudiod` for a clean baseline. Await their reply, re-resolve daemon PID, rerun the full suite, rebuild/verify DevC with the pinned runtime, then physical retest. The installed app at this point includes the camera/sorting correction but not the latest teardown correction and is not running. Nothing from this continuation has been committed or pushed.


### Final build checkpoint — 16:03 IST

- User reported audio flowing again without restarting CoreAudio, but CPU remained around 100–107%. No CoreAudio restart has yet been confirmed.
- Final teardown-corrected DevC rebuilt successfully (`/private/tmp/muesli-astra-devc-shutdown-build.log`), installed with complete pinned LocalVQE runtime, deep signature and App Intents metadata verified. Functional installed-runtime verification passed. Launched PID `63587`; re-resolve before use. This launch is into the still-unhealthy daemon and does not prove live readiness.
- Final focused run: **20 tests in 3 suites passed** (`/private/tmp/muesli-astra-final-focused-tests.log`): camera isolation, system watchdog, and independent capture shutdown. This is not a replacement for the incomplete full-suite attempt.
- `MeetingCaptureShutdown` requests shutdown independently but still awaits both native operations; it does not promise to interrupt a permanently blocked HAL call or impose a finalization deadline. Full-suite and physical Stop validation remain necessary.
- User has been asked to either restart CoreAudio now and complete verification or save state for later. Preserve all eight modified/new files; no commit or push has occurred.

### Verification retry — 16:09 IST

- CoreAudio briefly settled to 0.2–0.4% at 16:04 with unchanged PID `403`, without a restart. By 16:07 it was back above 100% with DevC idle; spontaneous playback resumption is not a stable baseline.
- Final full-suite retry `/private/tmp/muesli-astra-final-full-tests.log` again blocked in real CoreAudio reads. Fresh sample `/private/tmp/muesli-astra-final-test-runner.sample.txt` confirms MainActor controller initialization waiting on default-device HAL IPC. Runner `67061` and driver `67041` were stopped after capture. This run is incomplete, not a test pass.
- Latest complete full-suite success remains 2,007 tests before the teardown correction; latest focused success is 20 tests including that correction. Final DevC packaging/signature/functional LocalVQE verification passed; physical connect/disconnect/Stop validation remains unpassed.
- Do not repeat full-suite or physical testing until a healthy audio baseline is established. User has not confirmed a CoreAudio restart. Preserve current source, installed final DevC, and all profiles. No commits or pushes.

## Event-driven containment implementation — 2026-09-05, 16:54 IST

### User direction

- User rejected restarting CoreAudio as a release acceptance criterion. No daemon restart was performed; PID `403` remained alive and around 100% CPU throughout this implementation.
- User explicitly requested implementing the targeted UI, capture-lifecycle and graph-lifetime fixes before the next physical test, with **no continuous polling**. The proposal to experiment with explicitly bound microphone capture remains a separate investigation; no backend/routing-policy change was made here.

### Current uncommitted implementation

- `AudioRouteController`: initialize with an unknown snapshot and perform initialization, listener registration/removal, route inspection and cache refresh on the route worker. Dictation/meeting/UI getters read cached state; no synchronous route-queue join. Device selection and route policy remain unchanged.
- `MicrophoneActivityObserver.swift` / `MeetingMonitor`: a small MainActor facade caches microphone device identity; a dedicated worker owns HAL reads and microphone/default-device listeners. Generation checks reject callbacks from a stopped/restarted observer. This complements the earlier camera isolation.
- `MeetingAudioRecoveryDeadlines.swift` / watchdog / session: removed the session's one-second repeating watchdog timer. Route, handoff outcome and explicit capture-failure events arm one finite verification window with checks at 3, 8, 20, 40 and 60 seconds. Bursts coalesce without extending the window. Checks read existing cached callback timestamps and recorder state, with no HAL enumeration or inference. The microphone probe remains eligible throughout the window to catch delayed recurrence after an initially fresh callback. Pause/Stop cancel pending checks; resume is an explicit new event. Exhausted system-failure episodes retain their budget so the final rebuild's error cannot open a fresh retry loop. Arbitrary later callback loss without a new event is deliberately NOT continuously monitored.
- `MeetingMicRecording`: timed-out candidates are synchronously invalidated and remain counted while native start or retirement is outstanding. Route changes defer replacement creation until those operations return. Startup and retirement use a DispatchGroup; `waitForQuiescence()` is a separate join used only on the shutdown worker. Existing fast cancel/stop semantics for pending candidates remain covered.
- `MeetingCaptureShutdown`: start both driver shutdowns independently, wait up to 12 seconds for finalization, and return completed track results on timeout. Actual `onQuiesced` notification fires once only after both operations return; the microphone operation includes retired graph quiescence. This DOES NOT interrupt a blocked native call.
- `MeetingSession` / `MuesliController`: show `Stopping Audio` before capture teardown. Keep a capture shutdown token and meeting identity until actual quiescence, suppress meeting prompts/new recording/prewarming, and gate dictation/CUA/Quil even after transcript processing has ended. On timeout, report an audio-device failure and continue processing already-finalized chunks; do not claim hardware stopped. Discard cannot clear an outstanding shutdown token. Native operations completing late release the gate; late whole-track files remain in temporary storage rather than being deleted while a driver may own them.
- Original one-global-system-tap design, LocalVQE/AEC/inference policy and prior camera/stop-before-removeTap corrections are preserved. No reset, commit or push.

### Verification and installed app

- Initial focused regression run: **74 tests in 7 suites passed** (`/private/tmp/muesli-event-driven-focused.log`). Includes deliberately blocked HAL reads, observer generations, delayed callback starvation, finite deadline scheduling, timeout/quiescence distinction, and retained graph capacity.
- Full native attempt: `/private/tmp/muesli-event-driven-full.log` **incomplete**. Sample `/private/tmp/muesli-event-driven-full.sample.txt` shows MainActor servicing its event loop (the prior route-initialization freeze is gone). The two `AudioGraphExceptionBridgeTests` remain blocked in real AVAudioEngine/HAL calls; route-listener workers also wait on HAL. Driver `85183` and runner `85203` were stopped after capture.
- Final broad run excluding ONLY those two tests: **2,017 tests in 179 suites passed**, exit 0, `/private/tmp/muesli-event-driven-final-suite.log`. Two final regressions cover the shutdown token continuing to gate audio after transcript processing and an exhausted verification window retaining its retry budget. This is NOT a complete full-suite success. No tests were deleted/disabled in source.
- DevC rebuilt/installed/launched successfully with pinned LocalVQE runtime: `/private/tmp/muesli-event-driven-devc-build.log`. Xcode App Intents metadata present, deep strict signature valid, functional source and installed runtime checks passed (`/private/tmp/muesli-event-driven-runtime-source.log`, `/private/tmp/muesli-event-driven-runtime-installed.log`). Runtime ref/path unchanged from above.
- Installed DevC PID `88865` immediately after build; re-resolve. Startup sample `/private/tmp/muesli-event-driven-devc-startup.sample.txt` shows main event loop processing normally despite the existing daemon condition. This is startup containment evidence, NOT physical route-change validation.
- Old diagnostic profiler PID `55704` was stopped after verification. The app remains running; its script launch uses default stderr, so relaunch with captured stdout/stderr and arm a fresh profile before the next physical test.

### Next validation

- Physical AirPods connect/disconnect, delayed recurrence, Stop and subsequent recording remain UNPASSED for the final build. Do not present the code or runtime checks as release readiness.
- Preserve the failing daemon state. On the next physical session, capture baseline health and app/daemon stacks around the transition; test UI response separately from waveform/transcript progress and system playback. No admin restart is part of acceptance.
- Run the two real-HAL tests/full suite when the environment allows them to complete without hiding a failed physical route test.

## Third physical round armed — 2026-09-05, 17:12 IST

- User requested repeating the AirPods scenario. CoreAudio had spontaneously returned to idle CPU with unchanged PID `403`; no reset or reboot was performed. Recent DevC logs showed idle meeting detection.
- Fresh profiler `/private/tmp/muesli-devc-airpods-event-driven.a4wl1u` armed 17:11:42. Profiler tool session `5241` is running. App stdout/stderr are captured in this directory.
- Only idle DevC was relaunched; new PID `93685`, launch marker 17:12:12. At 17:12:16–17:12:17, DevC ~0.4% and CoreAudio 0.0% CPU. Pinned final build from the preceding implementation remains installed.
- User has been asked to keep AirPods cased and establish Meet + transcription + quiet YouTube speaker playback, speak for 15 seconds, and confirm all three (playback/waveform/hover preview) before the connection cue. Await baseline confirmation. No route-change pass claimed.

### Third round baseline failed with concurrent DevA — 18:02 IST

- User reported severe Meet joining/microphone delay, DevC still opening, and screenshot of `System audio capture failed / Process tap creation failed (status: 0)`. User explicitly said they would remove DevA themselves if running; **do not stop or remove DevA**.
- Read-only process inventory confirmed DevA PID `98077`, running since approximately 17:18, alongside DevC `93685`. CoreAudio PID `403` was again around 110–118% CPU. Two iOS simulator app variants/extensions also existed; those are not desktop DevA/DevC. No process was stopped or app removed in this investigation.
- Capture directory remains `/private/tmp/muesli-devc-airpods-event-driven.a4wl1u`. Saved read-only `DevA-concurrent.sample.txt`, `DevC-baseline-failure.sample.txt`, and `DevA-recent.log`.
- DevA sample directly shows `AudioAttributionService.activeInputProcesses(refresh:) -> AudioProcessAttributionCollector.activeInputProcesses() -> HAL property reads`. Its recent logs repeatedly report `refresh_audio=true` with `audio_ms` around 8,700–20,340 ms, including fallback-triggered scans. This is concrete competing audio-attribution activity, not proof that DevA alone caused every stall. The profiler did not originally sample DevA CPU; process inventory and its own logs now provide identity/timing.
- CPU history: 17:15–17:16 near idle; from ~17:18 recurring substantial CPU intervals, before DevC meeting startup at 17:58:03. At 17:58–18:00 CoreAudio sustained ~103–111% minute means. This prevents treating this as an isolated final-DevC physical route-change test.
- DevC stderr shows meeting model loading completed quickly (~17:58:04), followed by repeated VAD rotation while startup waited; then `tapCreationFailed(0)`, discard, and a second failing permission attempt. The source guard combines `status == noErr` with `tapID != kAudioObjectUnknown`; error status 0 therefore represents success status plus no usable tap identifier. `presentMeetingStartFailureAlert` currently gives permission instructions for every `RecorderError`. Permission denial is NOT established by this evidence. A follow-up correction should distinguish invalid returned tap identity from actual denied access and avoid misleading permission retries/advice.
- User has been asked to quit only DevA themselves, leaving Meet/DevC unchanged and AirPods cased, then report whether microphone/playback improves. Profiler remains running (PID `93286`, session `5241`). Await user confirmation; check process exit and daemon activity, then re-establish baseline before any AirPods connection cue. No new build or CoreAudio reset in this round.

### DevA exited; daemon back at idle — 18:11 IST

- User confirmed they quit DevA. Read-only inventory now shows only desktop DevC PID `93685`; DevA `98077` has exited. CoreAudio is still PID `403` and currently 0.0% CPU; no daemon reset occurred.
- Captured CoreAudio log records DevA's default aggregate `CADefaultDeviceAggregate-98077-0` deactivating at 18:01:29.458. This is the observed native-device event, not an exact user-action timestamp. User confirmation marker is later.
- Latest DevC stderr still ends with the prior failed startup/discard and subsequent detection activity. No successful replacement meeting recording has yet been established. Next step: confirm a fresh working Meet + DevC transcription + speaker playback baseline with AirPods cased and DevA absent, then cue connection. Existing profiler/session and stderr capture remain active.

### Third round: connection failure with DevA absent — 18:24 IST

- User started DevC transcription from a fresh detection notification, then connected AirPods before the requested baseline confirmation. Do not call this a fully controlled baseline: preconnection transcription was user-confirmed, but waveform, own-speech preview and playback were not all independently confirmed together. DevA remained absent; only desktop DevC PID `93685` was present. CoreAudio PID `403` was never restarted.
- Global capture started successfully: process tap `212`, aggregate `213`, native tap activation at 18:13:18.864 and writers ready at 18:13:19.361. Stderr contains exactly one default-output notification and no system-tap rebuild. Default-device aggregate activation for DevC was recorded at 18:14:07.774; this does not identify the exact physical connection moment. Marker timestamps are when reports were recorded, not exact hardware transition times.
- CoreAudio CPU means: 18:11 0.0%, 18:12 11.7%, 18:13 68.0%, 18:14 126.3%, 18:15 116.4%, 18:16 122.2%, 18:17 103.1%, 18:18 108.2%, 18:19 103.6%. User confirmed YouTube playback, preview transcription and waveform stalled with AirPods connected. This reproduces a failure without concurrent DevA; DevA cannot explain all failures.
- Saved `DevC-airpods-connected-final.sample.txt` and `DevC-confirmed-stall.sample.txt` in `/private/tmp/muesli-devc-airpods-event-driven.a4wl1u`. Both show the main thread servicing AppKit's event loop/timers, with system-tap processing and VAD work continuing. The earlier AVCaptureHALDevice MainActor deadlock is not present in these samples. HAL property-notification work is substantial; meeting detection still calls `MeetingSignalCollector.readMicActive` on its worker during evaluations, despite full process attribution remaining suppressed (`refresh_audio=false`). These samples do not by themselves establish a single daemon root cause.
- Stderr: one route handoff failed its five-second no-audio deadline. Raw mic chunks continued briefly through offset ~76 seconds, then stopped. Finite route verification requested `mic_callbacks_stale_after_audio_route_change` twice. Later, when system playback returned, system-track transcription resumed and the existing sample-driven coordinator requested `system_audio_active_after_mic_callbacks_stopped`. Current logging records requests, not whether each was busy/initiated/unavailable; do not infer candidate counts from request count.
- User subsequently reported YouTube audio playing through AirPods, but explicitly confirmed they had NOT pressed Stop and waveform/own-speech preview remained stuck. This is partial system-playback recovery, NOT a microphone recovery or physical route pass.
- User has now been cued to Stop Transcribing from DevC's menu bar while keeping AirPods, Meet and YouTube active, and report whether recording stops/progresses, the 12-second containment warning appears, or it stays stuck. Await this physical action; capture teardown logs/sample before changing the route or rebuilding. Profiler PID `93286`, shell session `5241`, remains active. No source changes besides this handoff during the physical test.

### Third round Stop completed; playback recovered later — 18:28 IST

- User pressed Stop Transcribing (the DevC process did not exit), initially reporting YouTube still stalled. DevC log shows actual CoreAudio tap teardown, partial-session shutdown, final chunk processing and diarization completion. No `capture shutdown deadline exceeded` warning was logged. CoreAudio confirms global aggregate `279282` deactivation at 18:24:47.326. Monitoring was suspended at 18:24:35.333 and returned to discovery at 18:24:48.484; these bound the observed stop transition, not the exact click/native-call durations.
- Transcript processing progressed and later summary generation failed because ChatGPT was not authenticated; that is separate from audio teardown. DevC remained PID `93685`, near idle CPU. `DevC-after-stop.sample.txt` confirms responsive main event loop; its route-refresh worker still waited in HAL property reads. This provides physical evidence that Stop progressed and released the global tap in this run, not proof of instant/bounded daemon recovery.
- Later stderr also shows a replacement mic handoff finally promoted and raw mic chunks resumed before Stop. Raw chunks were silent; user had confirmed own-speech/waveform failure. Do not equate a promoted graph or callbacks with successful speech recovery. Several recovery requests were logged, but request result/busy vs initiated is not logged and must not be inferred.
- CoreAudio remained around 110–120% in samples after Stop, followed by the user's report that YouTube playback finally returned. No daemon reset, restart or application removal was performed. This delayed playback recovery is not a successful AirPods connection test.
- A route-participant aggregate PID `59997` was initially presumed to be Chrome, but process inspection identified WhatsApp. The read-only sample was renamed correctly to `WhatsApp-route-participant-after-DevC-stop.sample.txt`; never attribute it to Chrome. Actual Chrome audio-service PID at 18:27 was `23970` (re-resolve); it was not sampled. Presence of another aggregate alone does not prove culpability. No WhatsApp/browser processes were changed.
- User has been asked to case AirPods with DevC transcription stopped and YouTube still playing, then report speaker-route responsiveness. This is a post-stop disconnect check, not an active-recording disconnect validation. Profiling remains active in the same directory/session pending that report.

### Third round disconnect delayed; retained-graph investigation — 18:33 IST

- User cased AirPods with DevC recording already stopped. YouTube's switch back to speakers stalled/delayed, then the user reported audio returning after roughly one minute or more. This post-stop disconnect is a failure/delayed recovery, not active-recording disconnect validation.
- `DevC-after-casing-stall.sample.txt` saved in the same capture directory. Main thread remains responsive; TWO AVAudioIOUnit queues inside DevC handle hardware-format/Bluetooth property changes after capture stopped, while route inspection waits in HAL. CoreAudio ~110%, DevC ~0.3% at sampling.
- Temporary profiler PID `93286` was stopped after saving these samples. No CoreAudio reset or user application termination occurred. App stdout/stderr may continue growing until DevC exits.
- New concrete code lead: `RouteAwareMeetingMicRecorder.makeChild` installs closures on a recorder that capture the entire `Child` value (`child.id`), and that value strongly owns the same recorder. Weak `self` does not break this recorder -> closure -> Child -> recorder cycle. Tests using only fake drivers have been added to verify deallocation after Stop and after handoff retirement before applying a fix. Do not yet claim the suspected cycle is proven or that removing it guarantees physical recovery.

### Confirmed retention cycle fixed; complete native suite passed — 18:40 IST

- Two new fake-driver tests FAILED on the prior source with three deallocation assertions: a stopped active child, a retired original child, and its replacement after Stop all remained retained. Evidence: `/private/tmp/muesli-mic-retention-before.log`. This establishes a source-level retain cycle independently of physical HAL conditions.
- Corrected `MeetingMicRecording.swift`: recorder sample/error callbacks capture only the UUID, not the `Child` struct that owns the recorder. Scheduled handoff deadlines likewise capture only the candidate UUID so an already stopped candidate need not stay alive until the timer fires. Startup/retirement workers still retain their native objects while those operations run. No backend/routing-policy change and no polling introduced.
- Added a third regression proving a pending child deallocates before an outstanding timeout fires. All **28 microphone handoff tests passed** (`/private/tmp/muesli-mic-retention-after.log`). Tests cover object release, existing callback routing and handoff/retirement behavior.
- Closed only idle DevC PID `93685` with SIGTERM after the physical round and samples were complete, so the old process's leaked graph objects could be released. No other user app was stopped; CoreAudio was not reset. CoreAudio later returned to 0.0% CPU with unchanged PID `403`.
- Full native suite, with NO exclusions: **2,022 tests in 180 suites passed**, 37.275 seconds, exit 0 (`/private/tmp/muesli-mic-retention-full.log`). The two AudioGraphExceptionBridgeTests that previously blocked completed. The external harness allowed 240 seconds but did not time out. This supersedes the earlier 2,017-test partial verification for current source; it does not supersede the failed physical test of the previous build.
- Pinned source LocalVQE functional verification passed (`/private/tmp/muesli-mic-retention-runtime-source.log`). Corrected DevC build is in progress via canonical lane-C local-only command, tool session `26786`, log `/private/tmp/muesli-mic-retention-devc-build.log`. Finish installation/signature/installed runtime verification before calling the build ready.
- Interpretation: retained stopped/retired AVAudioEngine objects are a confirmed defect and a plausible contributor to the captured post-stop Bluetooth property work. Do not yet claim this explains every daemon stall or that physical recovery is fixed. A fresh physical test must establish that corrected DevC survives connect, sustained speech/playback, Stop and disconnect without app/daemon restart.

### Retention-fixed DevC ready — 18:41 IST

- Canonical DevC build/install/launch completed, exit 0 (`/private/tmp/muesli-mic-retention-devc-build.log`). Installed bundle `com.muesli.dev.c` passes deep strict signature verification and contains App Intents metadata.
- Functional LocalVQE verification passed against the INSTALLED runtime and packaged model (`/private/tmp/muesli-mic-retention-runtime-installed.log`), as well as the pinned source runtime noted above. No missing-runtime override used.
- Current DevC PID `27895` at verification, ~0.4% CPU; CoreAudio PID `403` ~0.0%. Re-resolve before profiling. New app was launched by the build script and stderr is not armed for a new test; relaunch idle DevC with `open --stdout ... --stderr ...` into a fresh profile directory before cueing another physical transition.
- Latest full verification remains **2,022/180 passed, no skipped suites**. `git diff --check` clean. All work remains uncommitted and unpushed; existing implementation preserved.
- Next required work: physical connect/sustained speech-playback/disconnect/Stop on THIS retention-fixed build, checking post-stop property activity and a subsequent recording as well. The previous physical failure belongs to the pre-retention-fix build. Do not represent the new binary as a physical pass.
- Separate known follow-up remains the misleading `tapCreationFailed(0)` permission alert and unconditional permission probe after an invalid tap result. This was diagnosed above but not changed in this retention fix. Avoid conflating that UI correction with proven elimination of the route stall.

## Capture lifecycle implementation after architecture review — 2026-09-05, 20:35 IST

User explicitly requested implementing a coherent fix from profiling, preserving the branch work, rather than continuing isolated symptom fixes. Main checkout/branch unchanged; no commit, push, reset, CoreAudio restart, DevA removal, app-data reset, or physical route transition performed in this implementation round. Pre-round tracked diff saved at `/private/tmp/muesli-before-capture-lifecycle.patch`.

### Implemented boundaries

- Added `MeetingCaptureLifecycle`: one owner for initial microphone preparation, system start, microphone start, pause/resume, and retirement. Driver work runs outside MainActor/lifecycle decision locks. Cancellation rejects later startup stages immediately; each driver's stop awaits only its own outstanding operation. All callers join one shutdown. Startup has a 20-second readiness deadline; the existing 12-second shutdown containment deadline does not release the capture lease or pretend to interrupt a native call. Actual completion callback remains owned by the lifecycle even if a discarded `MeetingSession` is released.
- `MeetingSession` normal Stop, failed start, preparation cancellation and discard now share that owner. Discard no longer calls native teardown synchronously on the UI. Controller retirement admission/callback wiring is shared across these exit paths, retaining the gate until drivers and retired microphone candidates have returned. Native pause/resume are queued through the same lifetime.
- Initial `RouteAwareMeetingMicRecorder.prepare/start` execute native operations outside its decision queue. Terminal invalidation is a separate short state mutation and blocks late graph startup. Prior child-retention fix and pending/retiring graph capacity limits remain. Recovery logs now record admission (initiated/busy/unavailable), not just requests.
- `StreamingMicRecorder` creates AVAudioEngine lazily on the driver path, and releases it on cancellation; allocating a route candidate no longer constructs the native engine on the decision queue. Meeting children still disable independent configuration-change recovery; ordinary output routes still do not rebuild the one global system tap.
- Removed the complete process enumeration from system-tap startup's own-PID resolution. Uses SDK-documented `kAudioHardwarePropertyTranslatePIDToProcessObject` with PID qualifier instead. `CoreAudioSystemRecorder.start` runs its synchronous native startup on a driver queue.
- Removed automatic permission-probe/retry after failed meeting tap startup. Split `invalidTapIdentity` from nonzero OSStatus failures; status 0 without an object is no longer described as permission denial. Error UI retains an optional Audio Recording Settings action without asserting permissions caused the error.
- Microphone activity and mute/volume state come from OS property listeners and cached snapshots. Moved existing channel/mute inspection out of `MeetingSession`'s audio chunk-processing path into the observer worker; removed the coordinator's 1 Hz HAL mute-read behavior. Unknown mute state defers sample-based classification instead of inventing a mute value. Explicit input selection and default-device events refresh observation.
- `AudioAttributionService` returns cached observations immediately and allows only one native scan in flight. Completion triggers `.audioAttributionChanged`; that trigger cannot schedule another scan. Reset invalidates a late result without queueing replacement work behind it. Retry state advances only for admitted full scans. Both full and tracked attribution are forbidden in capture modes. Detector evaluations no longer query microphone HAL properties.
- Finite route verification publishes microphone loss into the existing UI warning path even when playback is also silent. Rechecks freshness under the health tracker lock; the waveform stops displaying a stale power value once callbacks cease.
- Removed unreachable `MeetingMicrophoneRecorder`, unused `MeetingMicRepairPlanner` and its four tests. Preserved its one used WAV operation by directly calling `WavWriter`. Removed repeated stateless lifecycle test inputs; added blocked-start, cancellation, deadline, blocked-attribution and route-warning regressions. Assigned relevant suites to the required meetings CI shard, including previously unassigned recovery/observation suites.

### Verification and current build

- Complete native suite on final production source: **2,022 tests in 181 suites passed**, 39.182 seconds, no exclusions. `/private/tmp/muesli-capture-lifecycle-final.log`. The deliberately invalid input-routing HAL test took **33.664 seconds**; this is not evidence of healthy route latency. Both real HAL tests completed, but native calls can still take a long time to return.
- Moved the new route-warning test under its named suite so CI selects it; subsequent focused run passed **7 health-tracker tests**: `/private/tmp/muesli-capture-lifecycle-ci-health.log`. Only test grouping/CI registration changed after the full run.
- CI shard assignment check passes (99 assigned, 76 legacy-unsharded), classifier tests pass, update-flow verification with `--skip-dmg` passes, `git diff --check` clean. Logs: `/private/tmp/muesli-lifecycle-classify.log`, `/private/tmp/muesli-lifecycle-update-flow.log`.
- DevC Xcode build/install/launch succeeded, exit 0: `/private/tmp/muesli-capture-lifecycle-devc-build.log`. Verified deep strict signature and `Metadata.appintents`. Complete pinned LocalVQE source and installed runtime both pass functional context creation with the packaged model: `/private/tmp/muesli-lifecycle-runtime-source.log`, `/private/tmp/muesli-capture-lifecycle-runtime-installed.log`. Ref `134aa7fd73d6a61dcab24c4f0c70bc49a38c0494`, arm64 runtime cache unchanged.
- DevC PID **54684** at verification (re-resolve). CoreAudio PID **403**, 0.0% CPU at the check; never reset. Startup sample `/private/tmp/muesli-capture-lifecycle-startup.sample.txt` shows main thread in the normal AppKit run loop. This is idle startup containment evidence only.

### Next acceptance step

No physical AirPods test has been performed on this lifecycle build. Arm a fresh profile/app stderr capture before another test; establish Meet + own-speech waveform/preview + speaker playback with AirPods cased, then connect, sustain speech/playback, disconnect during recording, Stop, and start a subsequent recording. Measure readiness, audio interruption and post-stop graph activity separately. Do not present automated success or the unchanged idle daemon as a physical route pass, and do not reset CoreAudio as an acceptance workaround. The previous physical failures belong to earlier binaries; the latest changes address verified blocking/ownership mechanisms but do not establish a single root cause for every shared-daemon stall.


## Capture state consolidation — 2026-09-05

User asked to remove redundant/similar states after the lifecycle implementation. Existing uncommitted AirPods work was preserved; no reset, commit or push.

- `MeetingCaptureLifecycle` now owns one `MeetingCapturePhase`: preparing, capturing, paused, stopping, stopped. Removed stored started/ended/quiesced booleans. Stopping means native retirement remains outstanding; stopped means both drivers have actually returned. No polling added.
- `MeetingSession.isRecording` and `.isPaused` derive from that phase; removed their stored copies and the separate paused-display lock. Preparing accepts initial samples, paused/stopping/stopped reject them. Discard retains its actual once-only cleanup task instead of a separate discarded flag.
- Controller retains one `(id, session)` capture through native retirement. Removed separate preparing/active session storage, mutable active ID, starting/stopping flags, stopping ID, shutdown token and canceled-start ID set. Remaining UI/detector booleans are computed projections. Offline imports derive their busy state from the existing import job ID.
- A start attempt retains its task and session identity, not another capture phase. Owner checks reject old continuations, including when the same database meeting is resumed. Explicit Stop/Discard retires that attempt; late startup cancellation cannot discard audio already being saved. Startup failure disposition now belongs to the controller, avoiding a second discard path inside `MeetingSession.start`.
- Removed obsolete controller recovery branches for an active meeting without a session. Input selection updates the sole capture reference. Detector policy receives the capture phase directly; contradictory boolean snapshots are no longer constructible.
- Replaced four detector-state tests with a parameterized phase table, expanded existing cancellation/deadline assertions, and added one pause/stop transition regression. Corrected shutdown test fixtures to block a driver queue rather than Swift's cooperative pool.

Verification:

- Final complete native run: **2,020 tests in 181 suites passed**, 37.040 seconds, no exclusions. `/private/tmp/muesli-state-consolidation-native-acceptance.log`. The reduced test-function count reflects consolidated parameterized coverage, not exclusions.
- An earlier full run also passed. Later runs concurrent with Xcode builds exposed timing-sensitive failures in shutdown/VAD and an unrelated catalog-reload test; preserve `/private/tmp/muesli-state-consolidation-final-native.log` and `/private/tmp/muesli-state-consolidation-verified-native.log` for that evidence. Final acceptance ran without concurrent compilation after correcting the shutdown fixture's executor blocking. Do not hide those intermediate failures or claim all timing flakiness is eliminated.
- Final production DevC build/install/launch exit 0: `/private/tmp/muesli-state-consolidation-verified-devc.log`. Only test fixtures changed after that build. Installed deep strict signature and App Intents metadata passed. Pinned LocalVQE source and installed model/context verification passed: `/private/tmp/muesli-state-consolidation-runtime-source.log`, `/private/tmp/muesli-state-consolidation-runtime-installed.log`. Same pinned ref and arm64 cache as above.
- Installed DevC PID 65197 at verification; re-resolve before profiling. CoreAudio PID 403 was ~102% during real-device testing and 0.0% at the post-suite check, unchanged PID and no service reset. DevC ~0.1%. Read-only startup sample: `/private/tmp/muesli-state-consolidation-startup.sample.txt`.
- `git diff --check` passes. No physical AirPods round has been performed on this consolidated build. The next acceptance step remains the profiled physical scenario above; neither automated test success nor idle CPU demonstrates healthy route switching.


### Consolidated build physical connection failed — 2026-09-05, 21:40 IST

- User started Google Meet, accepted detection and started transcription on installed DevC PID 65197, then connected AirPods before the cased-AirPods baseline question was answered. User reports playback struggles for more than 10 seconds after wearing AirPods, and live preview/waveform are stuck. This is a physical failure on the consolidated build; baseline own-speech/playback was not independently confirmed.
- Temporary profiler is ACTIVE: shell tool session `30550`, script `/private/tmp/muesli-devc-detection-profiler.sh`, directory `/private/tmp/muesli-devc-airpods-consolidated.vD7Y3O`. Live unified logs and 1-second process CPU capture are active; stop only this profiler when the physical round is complete. No app/service restart or code modification during this test.
- Capture attached after the user's connection report; `markers.log` times are when tool markers were written, not exact hardware/click timestamps. `recent-transition-unified.log` recovers available preceding four minutes. DevC stdout/stderr are `/dev/null`; cannot recover fputs-only startup/handoff admission logs without a future idle relaunch. Do not interrupt this recording just to redirect logs.
- Saved `DevC-airpods-connected.sample.txt` (5 seconds) and `DevC-sustained-stall.sample.txt` (3 seconds). Main thread is mostly in the AppKit event loop and services waveform timer work, rather than stuck in native audio. CoreAudio PID403 ~111–151% during failure; DevC varies ~14–46% in the cited interval. CPU does not identify the initiating client.
- Both samples show route-cache/default-device HAL reads waiting; AVAudioIOUnit rebinding waits in macOS smart-routing/HAL locks; microphone candidate cleanup is blocked in `FallbackStreamingDictationRecorder.cancel()` acquiring its NSRecursiveLock. The same sample shows that wrapper's `start()` holding the lock through `AudioQueueInputRecorder.start()` -> AudioQueueStart -> native smart-routing wait. This localizes a remaining native/fallback ownership bottleneck; it does not prove a complete deadlock cycle or sole cause of shared playback stalls.
- Detector evaluations during failure show `refresh_audio=false`, `refresh_tracked_audio=false`, audio_ms=0, generally 0–39ms total. No evidence of repeated full attribution in this captured interval.
- User has now been asked to press ONLY DevC Stop Transcribing, leave AirPods connected, Meet open and YouTube playing, and report whether DevC leaves recording and playback recovers. Await that response, then sample teardown before any further route change. Do not infer Stop happened from lack of response. No CoreAudio reset.


### Stop deadline and stale Finalizing presentation — 21:43 IST

- User pressed Stop and supplied screenshot showing “Audio Capture Is Still Stopping” alert, meeting row Completed, floating bar Finalizing. Saved `DevC-stop-timeout.sample.txt` (5s) in current capture directory. This confirms 12-second containment fired; do not call it successful timely teardown.
- Read-only database verification: latest meeting49 is completed, duration226.733s, raw-transcript length497, word_count92, saved_recording_path NULL. Confirms captured transcript persisted, not complete speech capture or saved audio file. No transcript content read/output.
- Stop sample initially shows RouteAwareMeetingMicRecorder.waitForQuiescence waiting for candidate retirement, fallback cancel blocked on wrapper lock, and AudioQueue input callback waiting on its recorder lock. Later in the SAME sample, `completeMeetingCaptureShutdown(owner:)` executes: native retirement eventually completed. CoreAudio remains ~125% in subsequent CPU records; no playback recovery inferred.
- Source confirms separate presentation defect: final processing cleanup clears the floating indicator only if `!isMeetingRecording()`, but that method includes stopping. `completeMeetingCaptureShutdown` clears ownership and syncs AppState but does not reset the floating indicator/status. Thus a completed transcript can leave Finalizing displayed after the driver later retires. No fix applied during the live scenario.
- User was asked to dismiss OK, keep AirPods connected, and report current YouTube playback and whether Finalizing remains. Await response; profiler session30550 remains active. Screenshot source `/var/folders/wl/gx3tw4h154l62yr_6_wt9zwh0000gn/T/codex-clipboard-d0639484-5e59-4cec-a088-036422323fac.png`.


### Post-stop failure confirmed; disconnect check pending — 21:44 IST

- User dismissed OK and confirmed playback still stalls and Finalizing remains. Saved `DevC-after-stop-alert-dismissed.sample.txt` (3s). Main thread is in its event loop; this sample no longer shows the prior AVAudioIOUnit/fallback startup or microphone-retirement wait stacks. Worker threads still wait on default-device HAL reads. Absence in a sample is not a complete live-object inventory.
- CoreAudio remains ~117–142% while DevC ~0.8–1.1% in the cited CPU records. User-facing playback failure persists after the observed native retirement callback.
- User has now been asked to case AirPods, leaving Meet open and YouTube playing, and report speaker-route latency/recovery. Await physical response. Profiling session30550 remains active in `/private/tmp/muesli-devc-airpods-consolidated.vD7Y3O`. No source changes or rebuilds during the round.


### Disconnect failed; browser audio and camera samples saved — 21:47 IST

- User cased AirPods and reported playback still stalling and Meet webcam unable to toggle back on. Saved `DevC-after-casing.sample.txt`, `Chrome-audio-after-casing.sample.txt` (PID23970), and `Chrome-camera-after-casing.sample.txt` (PID60034), 3s each. Chrome parent PID41603 verified from process command; no guess from aggregate IDs.
- Chrome audio-service sample contains substantial synchronous AudioObjectGetPropertyData/HAL IPC waits. Chrome camera-service main thread services its run loop and CMIO work appears elsewhere; no proven camera deadlock/root cause from this sample. User-reported inability to re-enable webcam remains a failure, not explained away by a live process.
- CoreAudio ~110% when this report was captured; last recorded CPU ~14.1% at21:46:36. That decrease does not prove playback/camera recovered; user has not reported recovery.
- The test has failed connection, Stop latency and post-stop disconnection, with a separate confirmed stale Finalizing UI defect. Requested user end Meet and stop YouTube playback, keeping AirPods cased; do not assume those actions occurred.
- Stopped ONLY verified temporary profiler PID69660 using SIGTERM (script trap closes its own two log streams). Capture directory remains `/private/tmp/muesli-devc-airpods-consolidated.vD7Y3O`. DevC, Chrome, CoreAudio and camera services were not stopped or reset. No production code changed during this round.
- Next implementation review: fallback recorder holds its recursive lock across native primary/fallback startup; retirement and AudioQueue callbacks also contend during route change. Audit that ownership and native callback locking before another physical round, together with controller presentation reconciliation after delayed quiescence. Do not treat the previously passing automated suite or phase consolidation as a physical fix.


### Stale Finalizing correction installed — after consolidated physical failure

- User confirmed DevC's floating pill continued showing Finalizing. Corrected only presentation reconciliation in `MuesliController`: one helper runs when transcript processing finishes and when native capture quiesces. It derives from existing capture/processing/interaction state, adds no stored state or polling, and preserves newer recording/import/dictation presentation. Once processing is finished, outstanding native teardown shows “Waiting for Audio Device”; once both finish the indicator returns idle.
- Existing 14 capture-lifetime, shutdown and processing tests passed (3 suites), `/private/tmp/muesli-finalizing-presentation-tests.log`. This is focused fake-driver verification, not a new full native or physical route pass. No new test scaffolding added for this small presentation change.
- DevC build/install/launch exit0: `/private/tmp/muesli-finalizing-devc-build.log`; complete pinned LocalVQE source and installed context verification passed (`/private/tmp/muesli-finalizing-runtime-source.log`, `/private/tmp/muesli-finalizing-runtime-installed.log`) and deep strict signature verified. Replaced only stopped DevC; no CoreAudio/browser reset or app-data deletion. CUA inspection of rebuilt DevC exposes an image-only floating window with no Finalizing label.
- This installation clears the old process's stale UI but does NOT resolve or physically revalidate the native route/fallback locking defect. That audio ownership investigation remains outstanding as described above. Do not reuse this restart as evidence that audio naturally recovered after the failed physical round.


### Deeper explanation from existing samples — follow-up analysis

- Stop sample lines1617–1626 narrow the wait further: AudioQueueInputRecorder.start -> cleanupAfterStartFailure -> disposeQueueLocked -> AudioQueueDispose -> AudioQueueStop -> AwaitAllPendingCallbacks. Simultaneously lines1573–1580 show the AudioQueue input callback waiting on AudioQueueInputRecorder.queueLock. Source start holds queueLock across native startup and its invalidation cleanup; disposeQueueLocked also stops/disposes under that lock. This is a concrete callback/teardown lock-inversion design, with both corresponding wait paths captured. The sample does not expose lock/object addresses to independently prove instance identity, and native retirement eventually returned: do not describe a permanent proven deadlock. This explains prolonged teardown more directly than the initial shared Bluetooth stall.
- FallbackStreamingDictationRecorder.start additionally holds its own NSRecursiveLock across child startup; its cancel path is captured waiting on that lock. Current app-scoped factory has AudioQueueInputRecorder as PRIMARY and StreamingMicRecorder as fallback. Do not infer the fallback backend was selected just because the wrapper's name contains Fallback.
- Retrospective log analysis found DevA PID61147 active before DevC recording: audio attribution took8.341s at21:34:29,52.288s at21:35:22,8.421s at21:35:30 and8.383s at21:35:38. DevC entered source_liveness at21:35:48.545 and later captured evaluations disable full/tracked attribution. Initial live process inventory no longer included DevA. This is a pre-start confounder, not proof DevA caused the AirPods transition or an excuse for DevC's own locking defect.
- Missing regression is callback delivery while native startup/disposal is pending; earlier outer-lifecycle fake-driver tests did not exercise the real nested AudioQueue/fallback callback-lock contract. Next correction should establish that contract at driver level, not add controller states or extend watchdog deadlines.

### Native callback lock correction — 2026-09-06

- User authorized fixing the demonstrated Muesli lock conflict without first profiling Granola/Zoom. Preserved all existing branch work; no reset, commit, push, DevA action, or CoreAudio restart.
- AudioQueueInputRecorder now serializes native commands with a command-only mutex; callbacks and PCM processing use short independent state locks. Native start/stop/dispose and PCM draining hold no callback-state lock. Startup cleanup publishes callback rejection before disposal. Disposal failure retains the original queue, buffers and retained callback owner, and prevents replacement until cleanup succeeds. Explicit retained callback ownership is preserved so final release cannot initiate teardown inside a native callback. Existing bounded graceful-stop drain remains; no new polling or capture phases.
- FallbackStreamingDictationRecorder similarly separates command ordering from short backend selection locking. It calls no child under the selection lock. Invalidation/cancel generation rejects late startup and prevents fallback activation for a cancelled attempt; generation-tagged forwarding rejects old callbacks after reuse. No additional meeting lifecycle state machine.
- Added a 141-line AudioQueue native-boundary test harness covering callback delivery while disposal waits, startup failure/invalidation, failed disposal ownership, explicit callback owner lifetime, and final-buffer preservation. Added focused fallback regressions for startup callback forwarding, invalidation and stale callback rejection. Both suites are now in the required meetings CI shard. Production delta versus pre-turn backups is +240/-300 lines across the two recorder files.
- Red evidence: `/private/tmp/muesli-native-lock-red.log` reproduced callback waits and invalidation incorrectly activating fallback before the locking correction. Initial focused green: `/private/tmp/muesli-native-lock-green.log` (43 tests, 4 suites).
- First full run `/private/tmp/muesli-native-lock-full.log` exposed test-harness global-worker starvation: simulated callbacks timed out while competing with the full concurrent suite. Dedicated callback threads now model the native callback boundary. Final full native run `/private/tmp/muesli-native-lock-full-final.log`: **2027 tests in 182 suites passed**, exit 0, 37.273 seconds. Includes CoreAudioSystemRecorder suite. `scripts/test_ci_test_shards.sh` and `git diff --check` passed.
- Pinned LocalVQE source runtime functionally verified at `/Users/pranavhari/Library/Caches/muesli-localvqe/runtime/134aa7fd73d6a61dcab24c4f0c70bc49a38c0494/arm64/lib`; log `/private/tmp/muesli-native-lock-runtime.log`. DevC build log: `/private/tmp/muesli-native-lock-devc-build.log`.
- Physical acceptance is still outstanding: these deterministic tests establish the corrected local callback/command contract, not healthy AirPods negotiation or the root cause of the original shared playback/camera stall. Next round must profile a confirmed cased-AirPods Meet + transcription baseline, connect, Stop, and disconnect; record waveform, own-speech preview, playback and teardown responsiveness separately. Re-resolve processes and arm profiling before asking for connection. Do not require a CoreAudio reset as a passing user scenario.
- DevC build/install/launch completed successfully. Installed LocalVQE functional verification, strict deep code-signature validation, and App Intents metadata presence all passed; installed runtime log `/private/tmp/muesli-native-lock-installed-runtime.log`. At verification DevC PID1098 ~0.7% CPU, CoreAudio PID403 ~0.0%; no DevA process listed. These are idle observations, not physical validation. No profiler is armed yet.

### Native-lock build physical test started — 2026-09-06

- User reports transcription has started and explicitly requested profiling. Read-only profiler ACTIVE in shell session12991, directory `/private/tmp/muesli-devc-airpods-native-lock.XCW3cr`, existing script `/private/tmp/muesli-devc-detection-profiler.sh`. Captures Muesli unified logs, filtered CoreAudio logs and 1-second process CPU samples. This is external diagnostic sampling, not app polling.
- DevC PID1098, CoreAudio PID403; no DevA process listed on attachment. Saved 3-second `DevC-baseline.sample.txt` and available preceding startup logs `pre-arm-unified.log`. Marker timestamps denote capture timing, not exact user actions.
- Asked user to confirm cased-AirPods baseline: own speech reaches preview, waveform moves, and YouTube plays normally. Await answer before cuing connection. No physical switch result established yet. Do not rebuild or restart during this live scenario. Stop only this profiler when the round concludes.
- User subsequently reported wearing AirPods before baseline confirmation. Added marker and saved `DevC-airpods-connected.sample.txt` (5s). CoreAudio ~110–112% in immediately inspected CPU records. Sample includes live AudioQueue PCM processing/callback forwarding and HAL property/command-gate waits; this does not establish intelligible speech delivery or playback recovery, nor prove the old teardown cycle absent under Stop. Asked user to report waveform/own-speech preview and AirPods YouTube playback while leaving capture and connection active. Profiler session12991 remains active.
- User confirms microphone transcription works but YouTube playback stalls. Marked report; saved simultaneous 5-second `DevC-mic-working-playback-stalled.sample.txt` and `Chrome-audio-playback-stalled.sample.txt` (Chrome audio service PID23970). CoreAudio ~105% on process inventory. Chrome sample shows AudioUnitSetProperty -> AudioDeviceDestroyIOProcID -> StopIOProc -> macSmartRouting setPlayState and HAL property calls. DevC sample contains microphone and CoreAudioSystemRecorder PCM processing; this cannot establish non-silent/usable system audio or sole fault attribution.
- Asked user to press ONLY Stop Transcribing while keeping AirPods connected, Meet open and YouTube attempting playback; report floating-bar completion and playback recovery independently. Await confirmation of Stop before treating subsequent samples as teardown. Profiler12991 remains active; no app/service restart or code edits.
- User reports transcription stopped, playback remains stalled; screenshot shows YouTube buffering and a small waveform pill without Finalizing. Subsequent explicit answer confirms floating bar disappeared. Saved `DevC-after-stop-playback-stalled.sample.txt` (5s): main thread in AppKit event loop, no sampled AudioQueueStop/Dispose/AwaitAllPendingCallbacks or microphone-quiescence waits. DevC ~0.1–0.2% CPU while CoreAudio ~110–111%. This supports completed UI teardown on this round but does not prove all native resources released or causal independence from Muesli.
- Direct daemon sample denied by macOS process privileges; `sudo -n` also reports password required. Need user to run read-only `sudo /usr/bin/sample 403 5 -file /private/tmp/muesli-devc-airpods-native-lock.XCW3cr/coreaudiod-after-stop.sample.txt` in Terminal while stall persists, entering password only there. No reset requested. Profiler12991 still active, AirPods kept connected, meeting/browser left open.
- User supplied privileged daemon sample `coreaudiod-after-stop.sample.txt`, captured13:36:36 for5s. Daemon main loop waits normally; other stacks include HALS_OverloadMessage reporting, object-map retain/release work, HAL command-gate mutex contention, and Bluetooth input/output IO threads. This is not evidence of one proven permanent deadlock or an initiating client.
- Matching `coreaudio-unified.log` around13:37:02–04 contains Chrome-helper Bluetooth output overload/SafetyViolationOccurred reports with repeated continuous silent cycles and zero continuous nonzero cycles where fields are visible. Chrome earlier sample shows smart-routing/device teardown. These localize ongoing shared-output failure after the user confirmed DevC floating bar disappeared; do not blame Chrome or exonerate Muesli based on this alone.
- Next controlled isolation requested: end ONLY Google Meet, keep AirPods connected and YouTube attempting playback, DevC transcription stays stopped; report recovery and approximate delay. Await user action/report. No CoreAudio reset, no DevC restart. Profiler12991 remains active.
- Round ended: user ended Google Meet AND cased AirPods, then reported YouTube normal. Both changed together, so recovery cannot be attributed to one action. Saved `DevC-recovered.sample.txt` (3s), recovery marker. CoreAudio PID403 fell to~6% CPU; DevC PID1098 ~0.0%. No daemon reset or app restart.
- Stopped only profiler PID11723 via TERM; session12991 completed. Evidence remains in `/private/tmp/muesli-devc-airpods-native-lock.XCW3cr`. No live profiler remains from this round.
- Acceptance: microphone transcription remained functional after connection and user confirmed the floating bar disappeared after Stop; sampled previous teardown-lock wait did not recur. Shared YouTube/Bluetooth playback still stalled and persisted after Stop, therefore the overall route-change test FAILED. Do not claim shipping readiness or that Muesli is cleared as the initiating cause. Next useful isolation is a matching Meet+YouTube AirPods transition with DevC fully exited, then compare capture involvement under the same initial conditions; change one factor at a time and confirm baseline before connection. If reproducing only with Muesli, isolate system capture from microphone capture before adding more recovery code.

### No-Muesli control also stalls — 2026-09-06

- User reports all Muesli instances quit; Meet+YouTube+AirPods initially delayed~10s then played, subsequently stalled again. Attached screenshot shows YouTube buffering; supplied Chrome accessibility snapshot shows Meet camera/microphone recording. UI audio-playing flag does not demonstrate audible playback.
- Verified full process arguments: zero `/Applications/Muesli*` processes; CoreAudio PID403 ~144.2% CPU. Saved control evidence at `/private/tmp/muesli-airpods-no-app-control`: `verified-processes.txt`, 5s `Chrome-audio-stalled.sample.txt` (PID23970), `coreaudio-recent.log` (preceding2m; overload reports and SafetyViolation entries). Initial process-inventory.txt used truncated comm fields; use verified-processes.txt for Muesli absence/daemon CPU.
- Chrome sample again includes AVAudioSession(macSmartRouting) setPlayState and HAL property queries. This establishes recurring playback failure while Muesli is absent, not merely initial route-switch delay. It does NOT rule out carryover: CoreAudio403 and Chrome audio23970 persist from earlier Muesli tests; no fresh-session control yet. No code changed, no daemon reset or browser restart, no continuous profiler newly armed (bounded samples/log retrieval only).
- Asked user to end ONLY Meet, leaving AirPods worn/connected and YouTube attempting playback. Await outcome; keep one factor changed this time. Future clean-session reproduction may be needed to distinguish persistent earlier state from independently reproducible OS/browser/Bluetooth behavior.
- User reports Meet ended in no-Muesli control. Marked receipt, saved `after-meet-processes.txt` (CoreAudio403 ~108.5%) and 3s `Chrome-after-meet-ended.sample.txt`. Asked whether YouTube is now audible normally through still-worn AirPods; playback outcome and continued connection await confirmation. CPU alone cannot establish playback failure/recovery.
- User explicitly confirms playback STILL stalled after Meet ended, with AirPods worn. Chrome-after-meet sample shows AudioDeviceStart -> macSmartRouting setPlayState and mutex waits. Ending Meet alone did not restore playback in this observed window. Next requested single change: case AirPods while leaving YouTube attempting playback; report speaker recovery and approximate delay. All Muesli apps remain quit per prior verification/user report; no fresh-session reset performed, so carryover remains unresolved.
- User then cased AirPods and explicitly reports YouTube video AND audio playing smoothly. Recovery follows isolated AirPods disconnection after ending Meet alone failed; approximate recovery delay was not supplied. Saved recovery marker and `recovered-processes.txt`. This control demonstrates recurrent stall with no Muesli process and recovery on Bluetooth disconnection, but persistent CoreAudio/Chrome process state from earlier runs still prevents claiming Muesli never contributed. Next diagnostic boundary: a fresh macOS session with Muesli prevented from launching, repeat the same baseline/connect/end-Meet/disconnect sequence. A fresh-session control is diagnosis, not an acceptable user workaround or release criterion. No reboot/reset performed or requested for immediate execution in this round.

### Post-update fresh-session control armed

- User rebooted to install a pending macOS update and requested profiling. Host now macOS26.6.2 build25G83 (previous sample26.5.2 build25F84); Chrome audio path now152.0.7977.82 (previous152.0.7977.65). Both versions changed, so this is a fresh-session AND updated-software baseline, not a reboot-only comparison.
- Process inventory shows no /Applications/Muesli* app process. CoreAudio612, Chrome audio2703; do not reuse old PIDs. Prior /private/tmp profiler script is absent after restart; previous raw evidence may also have been cleared (not yet inventoried).
- New read-only profiler ACTIVE: shell session29804, script/evidence `/private/tmp/muesli-fresh-session-control/profile.py`. Records OS/boot metadata, CoreAudio and Muesli unified logs, 1-second CoreAudio/Chrome audio/Muesli process CPU. Temporary diagnostic sampling only; no app code change, audio reset or Muesli launch.
- Asked user whether AirPods remain cased and Meet microphone/YouTube work on MacBook before cuing connection, or whether already connected/not started/stalled. Await baseline confirmation. Keep Muesli closed for control.
- User confirms healthy cased-AirPods baseline: Meet microphone and YouTube work on MacBook, with Muesli closed. Marker saved. Cue AirPods connection while leaving Meet/YouTube running; await playback/Meet-mic outcome and approximate delay. Fresh-session profiler29804 remains active.
- User connected AirPods from confirmed healthy baseline; reports audio delayed through AirPods while video continues playing. Distinguish this from prior video-buffering stall. Added marker and saved5s `Chrome-connected-audio-delayed.sample.txt` (Chrome audio2703). Asked whether sound is absent versus audible but behind video versus recovered, approximate delay and Meet mic responsiveness. Await outcome; control profiler29804 remains active; Muesli stays closed.
- User clarifies no sound yet while video advances. Connected Chrome5s sample lacks the previous AudioDeviceStart/macSmartRouting/mutex-wait signature; largely event/semaphore waits with some Chrome work. CoreAudio observed~22.1% versus prior>100%. A few transition overload events occur around16:34:59 (including ClientHALIODurationExceededBudget and SafetyViolationOccurred), insufficient to establish sustained overload. Do not call this the same deadlock. Asked user to inspect (without changing) macOS Sound selected output/volume and confirm Meet microphone responsiveness. Profiler29804 remains active; await answers.
- User explicitly confirms Meet mic does not respond, AirPods output selected with volume above zero, video advances without audible sound. New5s `Chrome-mic-and-output-failed.sample.txt` saved; no earlier routing-mutex signature in collapsed stacks, CoreAudio~22%, zero Muesli process observations throughout current capture. Current failure affects both directions but is not yet proven same mechanism as prior macOS/Chrome build.
- Attempted noninteractive privileged daemon sample; sudo requires password. Need user Terminal read-only sample of new daemon PID612: `sudo /usr/bin/sample 612 5 -file /private/tmp/muesli-fresh-session-control/coreaudiod-mic-and-output-failed.sample.txt`. No reset/restart or route change. Profiler29804 active.
- User supplied daemon sample `coreaudiod-mic-and-output-failed.sample.txt`, captured16:40:13, macOS26.6.2. Unlike prior sample, no HALB_Mutex::Lock or HALS_OverloadMessage::perform entries; stacks largely scheduled waits with DSP/Bluetooth processing, built-in mic and Bluetooth input/output IO threads present. Footprint50.7MB. Cannot infer audible samples/functional capture from live IO threads, nor identify this as prior deadlock.
- Requested next single-factor change: in Meet Audio settings explicitly select built-in MacBook microphone instead of Default, leaving AirPods connected and output selected. Ask whether Meet mic indicator and YouTube sound each recover. Intended to isolate microphone-route involvement; not a proposed shipped restriction or proven Bluetooth duplex cause. Await result; profiler29804 remains active.
- Single-factor route result: user switched Meet microphone from AirPods to explicit MacBook microphone; YouTube audio immediately reported audible through still-connected AirPods, then user explicitly confirmed Meet microphone responds. Both directions now functional with built-in input + Bluetooth output, Muesli absent. Strong evidence microphone-route choice is involved in this post-update run; does not prove Bluetooth hardware/OS root cause, long-term stability, or explain prior-version mutex contention.
- Added recovery marker and captured3s `Chrome-builtin-mic-airpods-output-working.sample.txt`. Profiler29804 remains active for continued comparison. Useful next step is a reciprocal switch to AirPods mic under the same conditions if testing continues, to establish repeatability before any Muesli routing policy changes. Do not silently impose built-in mic on users based on one observation.
- Reciprocal check did NOT reproduce failure: user switched Meet microphone back to AirPods and reports YouTube playback and Meet mic both remain normal. Therefore AirPods duplex use alone is not a repeatable trigger; previous claim must stay limited to a mic-selection change coinciding with recovery. A route reconfiguration clearing transient bad state is a hypothesis, not demonstrated mechanism. Saved marker and3s `Chrome-airpods-mic-output-recovered.sample.txt`; profiler29804 still active. Next useful check is an actual case/reconnect cycle from this now-working setup, with Meet and YouTube left running and no Muesli intervention, rather than adding a forced built-in-mic policy or automatic mic toggling to Muesli.
- User cased AirPods following the healthy reciprocal mic switch. Receipt marker saved. Await explicit confirmation that YouTube plays through MacBook speakers and Meet mic responds before cuing physical reconnection. Profiler29804 remains active; no Muesli launch or configuration changes.
- User confirms speaker audio normal after casing, then confirms all normal after cued physical AirPods reconnect (YouTube and Meet mic). No mic setting change was requested for reconnect, but final selected mic identity was not independently inspected. One successful reconnect is not repeated-cycle acceptance.
- Fresh-session no-Muesli control outcome: initial no-sound + unresponsive Meet mic after connection; changing Meet mic to built-in restored both, switching it back to AirPods stayed healthy, case/reconnect then also stayed healthy. This does not support a permanent AirPods duplex incompatibility or prove same mechanism as earlier high-CPU deadlock. Initial routing state remains unresolved. No Muesli process observed during profiler capture.
- Stopped only profiler11602 via TERM; session29804 completed. Evidence directory `/private/tmp/muesli-fresh-session-control`. Next comparison should use the now-working updated environment and same scenario with DevC, distinguishing detection-only from active capture. Branch remains unvalidated on updated OS; no code or mic policy change justified solely by this control.

### Post-update DevC notification start delay

- User proceeded directly to accepting DevC's detected-meeting transcription notification and reports >15s before mic transcription activated; detection-only comparison was not performed. DevC PID15725, CoreAudio612. New external profiler ACTIVE session6760, `/private/tmp/muesli-post-update-devc/profile.py`, same log/CPU capture as control. Attached after reported delay, not before acceptance.
- Saved preceding8m `startup-history.log`, `stdout-destination.txt`,5s `DevC-after-delayed-start.sample.txt`. DevC stdout/stderr both /dev/null; detailed fputs timing unavailable retrospectively. History includes Espresso/CoreML graph work around16:54:05–11 but no verified attribution of full delay to model load versus native mic activation. Must not diagnose solely from post-event sample. A future idle launch with captured console output or durable startup phase timestamps is needed to quantify acceptance→first PCM→first transcript.
- Asked whether own-speech preview/waveform, Meet mic and YouTube now work and whether AirPods were connected before acceptance. Await user response; do not interrupt this recording to relaunch. Profiler6760 remains active. Fresh-session control profiler29804 was stopped, its evidence archived outside tmp at `/Users/pranavhari/.codex/visualizations/2026/09/05/01a070fe-0717-7b31-b86c-23f694072abd/audio-evidence/fresh-session-control.tgz`.
- User clarifies AirPods were cased during >15s startup delay, then confirms live-preview transcription is now happening. Active AirPods connection was not required for this startup delay. Do not infer full baseline (Meet mic/YouTube) or exact first-PCM latency from this answer. Marked live transcription working; profiler6760 remains active. Confirm playback/Meet baseline before next physical connection.
- User confirms YouTube and Meet normal in addition to DevC live transcription. Healthy cased-AirPods baseline now established after delayed startup. Marker saved; cue physical AirPods connection with DevC transcription, Meet and YouTube left running, no manual mic-setting changes. Profiler6760 remains active. Await separate DevC/Meet/playback outcome and delay.
- User reports connecting AirPods during active DevC capture was smooth, with everything including transcription normal. Subsequently cased AirPods with DevC/Meet/YouTube left running and confirms everything continued normally. This is one successful physical connect/disconnect cycle on updated macOS26.6.2/Chrome152.0.7977.82 with current DevC; user did not quantify transition time. Receipt marker records both reports, not exact physical event timestamps. Does not resolve earlier >15s cased-AirPods startup delay or establish repeated-cycle/release acceptance. Profiler6760 remains active. Next step: user Stop Transcribing with AirPods cased, Meet/YouTube running; verify completion and playback separately before ending capture.
- User reports transcription stopped via another control and says still unable to stop from floating pill. Separate UI defect reported; exact interaction unspecified. Asked whether Stop absent, click ignored, or another action, and independently whether pill cleared/playback normal after stopping elsewhere. Saved3s `DevC-after-successful-route-stop.sample.txt`; profiler6760 remains active pending confirmation. Do not count pill Stop as passed or diagnose hit-testing without interaction evidence.
- User clarified pill defect: clicked Stop and nothing happened; stopping via another control cleared floating bar and playback remained normal. Post-route Stop therefore passed via alternate control, floating-pill Stop FAILED. No sampled old AudioQueue teardown waits. Needs input-event/callback-path reproduction, not another capture lifecycle change.
- Profiling round6760 ended; stopped only profiler15989, all apps/services untouched. Saved durable archive `/Users/pranavhari/.codex/visualizations/2026/09/05/01a070fe-0717-7b31-b86c-23f694072abd/audio-evidence/post-update-devc.tgz`. Outstanding: >15s activation while AirPods cased (missing detailed startup timing) and nonresponsive pill Stop; successful one physical connect/disconnect+alternate Stop cycle on updated OS does not make full branch release-ready.
- Initial read-only click trace: HoverIndicatorView.mouseUp -> handleClick(atX:) -> onStopMeeting when state recording and x>=30; MuesliController assigns onStopMeeting to stopMeetingRecording. InteractiveFloatingPanel intercepts leftMouseDown through meetingTranscriptPanel.handleClick first. Root cause not yet established; do not claim missing callback wiring based on user symptom. No new code changes in this profiling round.

### Local checkpoint and DevC rebuild requested

- User authorized committing the current implementation locally and rebuilding DevC for another AirPods case/uncase test. This checkpoints the accumulated capture/observation/locking changes plus the attribution/liveness simplification; no push requested.
- Latest cleanup: production63 lines smaller, two policy test files1100→372 lines, conflicting-room liveness fixed; complete native suite2003 tests/182 suites passed (`/private/tmp/muesli-trim-full.log`, durable copy under branch-trim artifact directory). CI shard checks and diff whitespace checks passed. Known outstanding UI Stop and >15s startup reports remain unresolved; one physical route cycle passed before this cleanup on updated macOS/Chrome, not a release guarantee.


### PR #500 review follow-up — 2026-09-06

- PR https://github.com/Muesli-HQ/muesli/pull/500 is ready for review. Only issue #498 was approved as a related reference, without closing keywords. Five original commits received author-matching DCO signoffs at user request; pre-review-fix head is `53bc5b21`, tree-identical to physically tested `f942cb2a`.
- CodeRabbit follow-up fixes EOF handler cleanup, cross-queue route callback storage, preferred input propagation before child start, deferred-handoff retention, late shutdown file cleanup (preserving delivered files), explicit self-process resolution failure during tap creation, cached live route diagnostics, and checked listener registration. No new recurring polling or capture states.
- Rejected nil-ID finding: MeetingCandidate.suppressionID is nonoptional and defaults to id. Did not add a HAL startup wait: initial microphone publication already schedules micChanged after updating the cache.
- Attribution service retains its observation task instead of a separate in-flight boolean so the stale-result test can await actual retired completion. Existing shutdown deadline test now verifies late-file deletion and preservation of the delivered track; parameterized recorder test covers selection changes after primary/fallback preparation.
- Full native suite: 2,004 tests / 182 suites passed in 37.015 seconds; CI shard assignment and diff checks passed. Test log `/private/tmp/muesli-pr500-review-tests.log`. These fixes have not been rebuilt into installed DevC or physically route-tested yet.
- Prior console-enabled physical round: near-instant startup, smooth AirPods connect/case with waveform responsive, automatic stop on ending Google Meet. Both floating-pill Pause and Stop failed; user explicitly deferred that work. CPU profiler stopped; console stderr logging remained enabled. Durable archive under Codex audio-evidence/devc-console-route-round.tgz.
