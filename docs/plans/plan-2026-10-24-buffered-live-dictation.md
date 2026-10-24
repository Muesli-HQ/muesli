# Buffered live dictation and meeting previews

Implementation branch: `codex/buffered-live-dictation`, worktree `c519/muesli`.
Baseline: `ecdb38648aea4a4d9c44fdb33c3d12de0b11208e`.
Tracking request: https://github.com/Muesli-HQ/muesli/issues/564.

## Product contract

Opt-in hands-free local dictation for Parakeet v3 and the catalog's WhisperKit
models displays revisable text in a supported focused field while recording.
Push-to-talk, hosted transcription, voice-note recording, and native Nemotron
streaming retain their existing routes. The new mode is off for existing and new
configurations until enabled through the canonical settings definition.

Meetings expose “Selected final model (experimental preview)” in the existing
live-transcript selector. It uses the selected Parakeet v3/Whisper model and
language, with independent mic/system sessions. Existing VAD chunks remain the
durable transcript authority, including when batch transcription is empty.
Provisional text never enters checkpoints, saved segments, summaries or speaker
attribution. Existing live-caption presentation and source isolation are reused.

## Recognition architecture

`BufferedTranscriptionSession` accepts 16 kHz mono PCM from existing capture. It
owns one inference loop, coalesces arrivals, and retains at most 30 seconds of
pending audio. The initial target is a first decode after two seconds and further
decodes after one second of new audio. These are scheduling parameters, not
measured latency guarantees. A slow model suspends previews on overrun; capture
and final transcription continue from the recorded WAV.

Both adapters return text and word times. Re-decode at most 15 seconds per
window, retain approximately three seconds of revisable right context and one
second of left context at rollover, and assign ownership by audio time at a
whole-word boundary. Never deduplicate by matching strings: deliberate repeated
words must survive. Preserve decoder punctuation, Unicode and whitespace.
Unusable timings suspend preview rather than silently losing audio or words.

Each backend serializes model loading, preview decoding, batch decoding and
unloading. Per-session callbacks are invalidated at cancel/reset. Model and
language selection are captured, and a mismatched loaded model fails rather
than producing output attributed to another model. No preview factory downloads
models or opens a second microphone.

This deliberately avoids FluidAudio 0.17.3's default sliding-window scheduling:
that loop waits for 11 seconds plus two seconds of right context. Historical
PR #298 was closed unmerged after the same issue in 0.15.1; #297 shipped a
separate native EOU preview model instead. Their useful lifecycle infrastructure
is reused, but the failed scheduling policy is not.

## Cursor ownership and final cleanup

Capture the frontmost application, focused AX text field/area, complete string
value, and UTF-16 selection. Require readable state, writable selected text and
selection, and working focus/value/selection observation. Secure fields and
unsupported editors use existing paste-on-stop without starting a cursor lease.

For a captured target, replace only the session-owned selection using
AXSelectedTextRange and AXSelectedText. Before and after each mutation verify the
same focused element and exact expected text/caret. Do not set the complete
AXValue, synthesize backspaces, or use the clipboard for live revisions. If the
user edits, moves the caret or changes focus, permanently suspend that lease.
An uncertain AX error must never trigger a normal paste retry. AX provides no
atomic cross-process compare-and-replace, so remaining validation/write races
must be exercised during manual editor testing.

At stop, cancel provisional decoding and use the retained complete WAV through
the existing dictation ASR, artifact filtering, optional cleanup and custom-word
pipeline. Apply final text (and existing sentence-spacing policy) once to the
still-valid owned range. If ownership was lost, save the result in history and
tell the user; do not overwrite their edits or paste into the newly focused app.
An empty final result does not erase already visible text. Cancel leaves inserted
text intact and rejects all late callbacks. Finalization remains identified by
the existing dictation task ID until completion.

## Overlapping work

These PRs are integration boundaries, not dependencies to merge blindly:

Live status verified October 24: #603, #645 and #476 open/ready; #630 and #646
open/draft. No overlapping PR is merged into this implementation branch.

- #603, clipboard providers: keep live AX replacement outside PasteController;
  preserve final task ownership. Its asynchronous clipboard completion fixes
  remain applicable to the ordinary fallback path.
- #645, Traditional Chinese: run output transformations in the authoritative
  final pipeline; replace only a valid owned span. Do not broaden the existing
  native-Nemotron eligibility gate or insert untransformed final text twice.
- #476, Enter-to-submit: buffered final completion must finish before submission;
  suspended/undelivered output must not auto-submit an unrelated field.
- #630, caption follow-scroll: leave transcript rendering and scroll ownership
  unchanged; emit through existing partial callbacks.
- #646, experimental live speaker labels: keep mic/system and segment ownership;
  provisional hypotheses remain separate from saved speaker-labelled segments.
- #526/#413, split words: acceptance fixtures include overlap boundaries,
  repeated words, Portuguese/accented text, punctuation and non-space scripts.

## Verification and rollout

Automated checks cover revised hypotheses, multiple window rollovers, timestamp
failure, silence, bounded overrun, serialized inference, cancel while decoding,
UTF-16 edits, focus/caret changes, uncertain writes, final cleanup, and meeting
reset/commit behavior. New suites belong to the existing required CI shards.
Verify old configuration decoding defaults off and new settings round-trip.

Before calling this ready for broad use, measure both models on real speech:
first visible text, median/p95 lag, final lag, revision frequency, WER, long
continuous speech, language switches, sustained memory and CPU/GPU load. Exercise
TextEdit/plain text, browser fields and editors, unsupported editors, selection
replacement, manual edits, focus changes, cancellation and cleanup returning
different/empty/error results. Test simultaneous mic/system meeting audio with
slow inference and confirm no provisional text reaches persistence.

The user will select the dev lane after branch implementation. Do not package,
install or launch a lane during this first pass. Native test compilation may use
the isolated `~/Library/Caches/muesli-spm/worktrees/c519/test` scratch path. The
current host has Xcode 27.1/Swift 6.4; required CI uses Xcode 26.6/Swift 6.3, so
local tests do not substitute for that toolchain check.

First-pass verification: the native package compiled and 238 focused tests in 11
suites passed, covering the four new suites plus existing settings, model,
Whisper language, FluidAudio and meeting-streaming regressions. File classifier,
CI shard assignment and update-flow checks (`--skip-dmg`) also passed. No app
was installed or launched. Real-model latency and actual-editor validation remain
explicit dev-lane acceptance work, not results inferred from synthetic tests.
