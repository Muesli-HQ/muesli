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
value, and UTF-16 selection. Require readable state, writable selection,
writable selected text for the AX transport, and working focus/value/selection
observation. Secure fields and
unsupported editors use existing paste-on-stop without starting a cursor lease.

For a captured target, replace only the session-owned selection. Native editors
use AXSelectedTextRange and AXSelectedText. Before and after each mutation verify the
same focused element and exact expected text/caret. Do not set the complete
AXValue, synthesize backspaces, or use the clipboard for live revisions. If the
user edits, moves the caret or changes focus, permanently suspend that lease.
An uncertain AX error must never trigger a normal paste retry. AX provides no
atomic cross-process compare-and-replace, so remaining validation/write races
must be exercised during manual editor testing.

Browser editors can acknowledge an AX write before their cached value/selection
reflects it. Serialize preview and final mutations, then allow up to 500 ms for
the exact pre-write snapshot to become the exact expected snapshot. Value and
caret are separate AX reads, so a pending write may also wait when each component
exactly matches either its old or new state. Only the complete expected pair
acknowledges the write. Never repeat the write. Unexpected content or caret,
timeout, cancellation or a real
focus departure permanently revokes ownership. Redundant notifications for the
same focused element do not revoke it; a known foreign-app activation does, even
when its notification is delivered after focus returns.

The second Codex composer trial produced a 29-character Parakeet preview, then
`text_readback_timeout`: the AX text setter reported success while the exact old
field value persisted. This is distinct from recognition failure. Nemotron's
existing path types append-only deltas through keyboard events; it never used
this AX text setter.

For the observed Codex bundle, choose targeted keyboard delivery at capture time.
Keep AX ownership/selection verification, retain the exact common grapheme prefix,
and type the changed suffix through marked keyboard events addressed to the
captured process. Verify each step's full value and caret before continuing.
Never switch transports after an uncertain write. Pure shortening selects and
retypes one retained grapheme instead of synthesizing deletion keys. Empty
provisional hypotheses preserve visible text. Preflight controls and line breaks
before any selection: unsupported multiline cleanup remains in history rather
than risking an Enter/Tab action in a chat composer. Other applications retain
the AX path until their compatibility is verified separately.

The next instrumented Codex trial established a different first-key mismatch:
observed/stale/desired UTF-16 lengths were 1/1/2, the caret exactly matched the
desired position, and text differed only by trailing newline. The empty composer
exposed a single line-break placeholder that disappeared when the first key was
inserted. For Codex only, a capture of exactly LF with a collapsed caret at zero
may acknowledge the first keyboard step with that original placeholder removed.
Adopt the exact observed snapshot for subsequent edits; never trim newlines from
general snapshots. A retained newline still uses ordinary acknowledgment. The
exception does not cover other editors, existing content, CRLF, multiple lines,
nonzero selections, or later revisions. An alternate text snapshot with an old
caret may wait but cannot authorize another key before the expected caret arrives.
All 57 native cursor/keyboard tests passed, including the instrumented initial
state followed by a full preview, revision, and final cleanup. Actual editor
acceptance remains a separate manual check.

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

October 25 follow-up: the first Codex composer trial reached buffered finalization
but did not insert live text. Existing logs lacked preview/cursor outcome detail.
Add content-free diagnostics for received audio, decode/update counts, cursor
failure stage and final delivery. Fix the fallback notice's literal `doc.text`
icon string: that notice refers to history persistence, not a generated file.
An opt-in integration test uses FluidAudio's public speech fixture and an already
installed Parakeet v3 model to validate short-window decoding and rolling output;
it does not download models. Codex composer validation remains a manual step.
Follow-up validation passed 115 native tests across 13 suites, including 25 cursor
ownership/readback tests and the real-model smoke. The public fixture's two-second
prefix was empty, while three-, five-, ten- and fifteen-second prefixes produced
timed previews; its full 21.4 seconds passed rolling decoding. These observations
validate the model adapter, not the unobserved Codex composer interaction.

The second-trial keyboard-transport fix passed 136 native tests across 14 suites,
including 36 cursor ownership tests and 10 keyboard construction/dispatch tests.
Dispatch tests use injected sinks and do not post input to applications. Coverage
includes exact suffix revisions, shortening, Unicode, control preflight,
ineffective setters, cancellation, and stopping after failed acknowledgment.
CI shard assignment also passed. The user authorized deployment to lane B;
actual Codex composer acceptance still requires a manual dictation trial.

The next successful typing trial exposed excessive draft churn: the engine only
committed words on the 15-second rollover, and cursor writes queued every
intermediate hypothesis. Eleven previews reached the composer before an
undifferentiated keyboard dispatch guard failed at about 17 seconds, leaving
queued stale previews and preventing final cursor delivery. Commit older words
after consecutive hypotheses agree, retain a revisable recent tail, and enforce
the committed boundary at the text target. The cursor mailbox holds one active
write and only the newest pending update. Stop discards queued drafts before
authoritative final cleanup. Live updates preserve committed text; final cleanup
may intentionally revise the whole owned range once. Record individual dispatch
failure reasons; the existing coarse log does not identify which guard failed.

Stability validation passed 108 native tests across 11 suites. The progressive
Parakeet v3 fixture committed its first prefix at five seconds and completed all
21.4 seconds, including rollover, with monotonically growing committed text.
Tests exposed and now cover word end times extending through silence while their
onsets remain fixed, and rollover with no newly mature word but an existing owned
prefix. New commitments require two agreeing hypotheses and three seconds of
right context; the existing full-window fallback keeps audio bounded. Already
committed occurrences are matched by ordered lexical/onset anchors, with ambiguous
repetitions rejected. Cursor tests enforce the frozen prefix and a live-only
80-grapheme rewrite limit; deferred previews do not advance acknowledged ownership.
Classifier and CI shard checks also passed. These checks do not replace the
manual Codex composer trial; its prior dispatch failure still needs the new
per-guard diagnostic if it recurs.

The subsequent trial inserted only `I`: its first 13-character preview stopped
at `keyboard_text_readback_changed`, before acknowledgment of the first grapheme.
The log confirms successful keyboard delivery followed by failed verification,
but did not distinguish text mismatch from caret mismatch. Reconcile exact
old/new components within the existing deadline, and emit content-free state
classifications and lengths/ranges on mixed or rejected readbacks. Do not infer
that unrelated content or arbitrary caret movement belongs to our write.
All 50 native cursor/keyboard tests passed after this change, including both
split-update orders, stuck partial acknowledgment, and unrelated edits. The
original log does not establish which component differed; manual acceptance
and, if needed, the expanded diagnostic remain necessary.
