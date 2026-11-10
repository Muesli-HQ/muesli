# Test dictation failures in Dev C

These controls require a Debug build of `/Applications/MuesliDevC.app`
(`com.muesli.dev.c`, dev telemetry channel). They are compiled out of Release
builds and do not change persistent preferences, microphone permissions, or
CoreAudio. They start no dictation automatically. Each simulation fires once per
launch; the next matching take uses the ordinary path.

Quit Dev C normally before each launch command. The helper refuses to launch a
second instance or use an older build without these hooks. Run from the worktree
that built the app:

## Microphone startup watchdog

```bash
./scripts/dev-dictation-fault.sh mic-startup
```

Let any model preparation finish, then trigger ordinary dictation with your
configured hotkey. The deadline starts when microphone capture is requested;
it does not time model loading. The capture queue waits
for four seconds without preparing or starting a microphone. The independent
three-second **warning timer** should:

- Keep the pill in Connecting and show “Microphone is still connecting.”
- Offer Keep Waiting and Cancel Dictation; the warning alone never aborts startup.
- Emit `dictation.microphone.startup.warning`, not an SDK timeout error.
- Create no recovery recording because no audio was captured.

The simulation stays logically pending after its four-second wait. Choose Cancel
Dictation, release a held hotkey, or press Escape. The UI should leave Connecting
immediately, without waiting for native teardown. A new capture remains blocked
while native work is in flight, until cleanup finishes. An attempt that has not
entered native work can be replaced immediately. A subsequent take should work
normally. If you choose
Keep Waiting, the simulation remains pending until you cancel; no real mic opens.

Production also observes selected-device availability and abnormal I/O-stop
events, plus unexpected running-to-stopped notifications on Muesli’s AudioQueue.
Those confirmed failures terminate capture independently of the capture queue.
Unknown/unsupported properties, silence, the initial stopped queue state, and
ordinary stop/cancel do not count as failures. Default-input changes rebind the
observer rather than declaring a route transition a failure.

Automated tests inject these events at the HAL/AudioQueue boundaries, including
while native startup is blocked. Do not restart or corrupt CoreAudio to test them.
The pre-existing 1.5-second no-speech/no-buffer callback is advisory too.

## Failed buffered streaming transcription

```bash
./scripts/dev-dictation-fault.sh streaming
```

In Settings → Dictations, select a downloaded local Parakeet, Whisper, or Bodhan
model and enable **Watch text appear during hands-free mode**. Use a plain text
editor with no app-specific formatting rule that buffers output. Start hands-free
(toggle/double-tap) dictation, speak a disposable test sentence, and wait until
live words appear. Stop normally.

The simulation throws an incomplete-stream failure at finalization. Check that:

- Words already inserted stay in the editor.
- One recording appears under **Recordings to recover** in Dictations, with its
  available partial transcript. Expand it to select/copy partial text or play audio.
- Quit/reopen Dev C: the recovery remains discoverable.
- **Retry locally** saves the resulting text to Dictations/history before deleting
  that recovery's files, and does not open a mic or paste over your editor.
- Alternatively, **Discard** removes that recovery after confirmation.

Use hands-free buffered streaming, not hold-to-talk or the separate Nemotron
hands-free controller. If no buffered session starts, the streaming simulation
stays armed and ordinary dictation is unaffected. A successful local retry does
not encounter this simulation again.

The existing WAV and optional partial text stay in the private local recovery
folder until recovered or discarded. They are not included in test telemetry.
Use a disposable sentence for manual QA.

## Return to normal operation

Quit Dev C, then run:

```bash
./scripts/dev-dictation-fault.sh clear
```

Normal launching also leaves these simulations disabled. No `defaults` or
`launchctl` settings are written; the variable applies only to that launched
process. The selected mode is `MUESLI_DEV_DICTATION_FAULT=mic-startup` or
`streaming`; empty/unrecognized values disable simulation. The fixed-label
`dictation.dev_fault.triggered` event identifies simulated failures in dev
analytics. Startup telemetry schema 2 contains nine allowlisted fields: owner, outcome,
phase, bounded elapsed time, warning delay, coarse route/input selection, fixed
failure reason, and schema version. No audio, text, levels, paths, device IDs/names,
or session IDs are transmitted. Startup timing freezes at readiness, so a later device failure does not report
the length of the recording. Only confirmed capture failures emit the SDK error
`microphone_capture_failed`; warning, cancellation, and ordinary stop do not.

Automated regressions include `DictationCaptureHealthTests`,
`AudioQueueInputRecorderTests`, `DictationStartupWatchdogTests`, `DictationDevFaultTests`,
`DictationAudioSessionManagerTests.manualStartupSimulation`, and
`DictationStreamingRecoveryIntegrationTests`. Use the repository CI shard runner
for the complete dictation/transcription suite and its MLX shader setup.

## Measure successful-path overhead

On macOS, compare the optimized current pipeline with the pre-recovery main base:

```bash
./scripts/benchmark_dictation_pipeline.sh 94ff83be84bc68630d1481ef2cf64a7a47c835a6 3000
```

This runs three alternating baseline/candidate rounds and reports startup,
per-buffer, and stop-to-event distributions. The current candidate includes the
actual health-observer worker with synthetic HAL operations and consumes all
telemetry fields. Debug fault hooks are absent. It does not open a microphone or
measure physical HAL, model, network, editor, or UI latency.
