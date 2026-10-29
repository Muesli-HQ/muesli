# Buffered live dictation and meeting previews

Implementation branch: `codex/buffered-live-dictation`, worktree `c519/muesli`.
Baseline: `ecdb38648aea4a4d9c44fdb33c3d12de0b11208e`.
Tracking request: https://github.com/Muesli-HQ/muesli/issues/564.

## Current implementation (2026-10-29)

This section describes the shipped dev-lane B implementation and supersedes the
initial plan and chronological implementation notes below.

- The off-by-default “Watch text appear during hands-free mode” toggle supports
  local Parakeet v2, v3, Redux, Unified, catalog WhisperKit models, and all four
  Bodhan Core/Flex Pro/Lite variants.
- Only committed word groups are inserted at the cursor. Revisable hypotheses
  remain internal; there is no editable draft repeatedly replaced in the field.
  Hands-free pauses do not finalize a sentence. The hotkey ends the session.
- The shared engine uses bounded rolling audio, timed word ownership and agreement,
  serial inference, and coalesced delivery. Its 45-second pending-audio cap is not
  a limit on recording duration. Whisper preview alignment excludes padded audio.
- Backends without usable word timestamps use the shared continuity path: serial,
  disjoint two-second PCM chunks, append-only committed text, exact sample coverage,
  and tail-only finalization. Bodhan starts in this mode because its runtime does
  not expose word timings; Parakeet and Whisper retain their existing timed path
  and continuity fallback. Bodhan respects the captured language/output mode and
  reuses its prepared runtime, with validated cache-only reloads if displaced.
  Bodhan preview decoding has a 64-token budget per short chunk and preserves its
  best effort when EOS is absent, recording that condition instead of terminating
  streaming. Batch token budgets and EOS requirements remain unchanged.
  No VAD, pause endpointing, or confidence-based speech suppression is added.
- Whisper normally decodes at most eight seconds per rolling window. Consecutive
  hypotheses can confirm a word group before the three-second age cutoff when a
  following timed word establishes context. Case and edge punctuation may differ;
  ordered lexical identity and both timestamps must still agree. A mature prefix
  can also commit before physical rollover when its endpoint and following word
  agree at the same positions across two hypotheses; revising an earlier word
  does not hold that whole group until another full-window decode. Initial groups
  require positive-duration lexical anchors, or a mature independently agreed
  single word. Zero-duration words remain pending until a usable boundary follows,
  and finalization preserves them. A valid hypothesis that cannot yet advance its
  crop retains agreement evidence only; ownership, text and PCM remain unchanged.
  Invalid or ambiguous alignments still clear that evidence and use bounded
  recovery. The recovery window can exceed eight seconds, up to the existing cap.
  After a decoded pause retires lexical anchors, already-owned left context is
  removed only when no pending word needs it and every owned word has ended
  before the crop. Words spanning the boundary retain context.
- Cursor updates require ownership of the original focused element, text span,
  and selection. Temporary Accessibility read failures pause delivery; genuine
  focus changes, edits, and cursor movement revoke it. Codex uses acknowledged,
  bounded plain-text pastes, including verified empty-placeholder handling.
  Native Accessibility IPC runs on a serial background worker with deadline and
  cancellation checks. Recording starts while capture is pending; a bounded PCM
  prefix transfers in order after capture succeeds. Staged clipboard text is
  marked transient/concealed and limited to the current host; restoring the
  original clipboard preserves its original representations.
- Permanent cursor ownership loss displays “Cursor updates stopped · Still
  recording” in the indicator. Recognition failure has a separate persistent
  notice promising only audio and available text for recovery. Temporary AX
  pauses do not trigger either notice. Stop/cancel controls remain available.
- Stopping drains the unfinished tail and reuses the streamed transcript. Live
  dictation does not automatically retranscribe the whole recording. Confidence,
  agreement, and spelling-revision evidence are retained for diagnostics rather
  than triggering a full-recording retry. A bounded finalization deadline and
  retained audio/partial-text recovery handle incomplete coverage or decoder failure.
  Recovery copies live in `Dictation Recovery/<session UUID>/` inside the active
  app's Application Support directory. The recovery alert's “Show Recording”
  action opens that folder. Audio and partial text remain until the user removes
  the folder in Finder; there is no automatic retention sweep. A failed recovery
  copy leaves the original recording at the location shown in the alert.
- Optional cleanup and dictionary processing still run after recognition. Final
  insertion uses one guarded replacement of the changed text; losing ownership
  preserves the result in history instead of risking an unrelated field.
- Recognized decorated non-speech cues such as `*crickets*`, `[cheers]`, and
  `(laughter)` are filtered from live and final output across supported buffered backends.
  Ordinary spoken uses of these words remain. Incomplete cue markers are withheld
  until resolved so they cannot leak into committed cursor text.
- Meeting previews reuse the engine with independent microphone/system sessions.
  Existing VAD-segment final transcripts remain authoritative for saved meetings;
  provisional captions do not become durable segments or speaker attribution.

Validation: 352 targeted tests pass, including cursor safety, final cleanup,
Parakeet/Whisper regressions, cache-only Bodhan reloads, and six-minute synthetic
sample-ownership coverage. Bodhan Core Lite and Flex Lite each completed a 345.8-second
real-time engine replay with 173 updates and complete sample coverage. Their
recognition tails drained in 0.219 and 0.239 seconds respectively. Core had temporary
decode spikes up to 5.176 seconds, recovered, and finished without a session-ending
failure. An exact two-second Core token-limit failure was reproduced and verified
with the bounded preview policy before the full replay. These are engine results,
not a new automated Codex composer test or a latency guarantee. Pro variants are
enabled but have not received real-model throughput testing here.

The signed dev B app is installed; its signature, LocalVQE runtime, and App Intents
metadata are verified. Earlier user-driven Parakeet Unified and Whisper Turbo
composer runs established the cursor baseline. Tiny/Tamil has not been revalidated
with the current continuity path.

## Initial plan and implementation history

The following records earlier decisions and experiments. Statements about a visible
editable draft, mandatory full-WAV final recognition, or transport restrictions
are historical where they differ from the current contract above.

## Product contract

Opt-in hands-free local dictation for Parakeet v2, v3, Redux, Unified and the catalog's WhisperKit
models displays revisable text in a supported focused field while recording.
Push-to-talk, hosted transcription, voice-note recording, and native Nemotron
streaming retain their existing routes. The new mode is off for existing and new
configurations until enabled through the canonical settings definition.

Hands-free pauses do not finalize sentences or force the draft to commit. A user
may hesitate between words and then continue the same thought. Grow the stable
prefix through agreement across decodes, retain a revisable tail, and reserve
authoritative final transcription and optional cleanup for the stop hotkey.
Silence, VAD, and model EOU signals must not substitute for that explicit stop.

Meetings expose “Selected final model (experimental preview)” in the existing
live-transcript selector. It uses the selected supported Parakeet/Whisper model and
language, with independent mic/system sessions. Existing VAD chunks remain the
durable transcript authority, including when batch transcription is empty.
Provisional text never enters checkpoints, saved segments, summaries or speaker
attribution. Existing live-caption presentation and source isolation are reused.

## Recognition architecture

`BufferedTranscriptionSession` accepts 16 kHz mono PCM from existing capture. It
owns one inference loop, coalesces arrivals, and retains at most 45 seconds of
pending audio, providing arrival headroom during a 30-second recovery decode.
The initial target is a first decode after two seconds and further
decodes after one second of new audio. These are scheduling parameters, not
measured latency guarantees. A slow model suspends previews on overrun; capture
and final transcription continue from the recorded WAV.

All adapters return text and word times. Normally re-decode at most 15 seconds per
window, retain approximately three seconds of revisable right context and one
second of left context at rollover, and assign ownership by audio time at a
whole-word boundary. Never deduplicate by matching strings: deliberate repeated
words must survive. Preserve decoder punctuation, Unicode and whitespace.
Unusable timings suspend preview rather than silently losing audio or words.
Parakeet v2, v3 and Redux share the FluidAudio TDT adapter with an exact loaded
version check. Unified uses `UnifiedAsrManager.transcribeWithTimings` and the
same token-to-word conversion. Its RNNT emission times can share frame boundaries;
the shared engine validates them without inventing forced word boundaries.
Unified model loading, previews, final decoding and unloading share one inference
permit. All models retain the same cursor delivery and final cleanup paths.
Whisper preview word alignment excludes padded encoder frames before DTW and
preserves all lexical and punctuation tokens. Its normal final transcription
keeps the original seeker. Missing, mismatched or out-of-audio word timings
defer a preview without changing visible text or discarding PCM; retry requires
new audio and remains bounded by the existing recovery window. Language selection
still uses the configured auto-detection or pinned language for every decode.
Preview decoding uses one temperature attempt, then waits for new audio instead
of retrying the same uncertain window up to six times. Full-file final decoding
retains the original fallback policy.
An uncertain ownership alignment preserves all pending audio and the last visible
preview, then retries after more audio arrives. Recovery may expand the actual
decode window up to 30 seconds. State changes are
transactional: a failed attempt cannot partially commit text or discard audio.
If an owned word's spelling changes, recovery requires a unique ordered mapping
of its onset times and agreement across two newer hypotheses; committed wording
remains frozen. Ambiguous ownership never chooses a nearest repeated word.

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

## OSS comparison and remaining confirmation work

The October 25 Codex trial stopped previews at 9.6 seconds with `cannotAdvance`
while cursor updates remained accepted; final insertion succeeded. A 61-second
sequence of three upstream speech fixtures reproduced that failure at 23 seconds.
With transactional alignment recovery, it deferred that observation, recovered
at 24 seconds, and continued through 61 seconds with a monotonically growing
committed prefix and all three recording-ending phrases retained. All 115
targeted native tests across 11 suites passed, including recovery ambiguity,
token splitting, bounded buffering, finalization, and cursor ownership. This is
model/engine verification, not an automated test in the actual Codex composer.

Primary-source review via Exa on October 25 covered 30 search results across two
research tracks, then inspected upstream source and model documentation. The
app should distinguish recognition stability, utterance boundaries, and editor
range ownership; none of these alone establishes the other two.

| Implementation | Confirmation policy and relevant boundary |
| --- | --- |
| [Whisper-Streaming](https://github.com/ufal/whisper_streaming/blob/main/whisper_online.py) | LocalAgreement-2 commits the common prefix of successive hypotheses; timestamps plus small lexical overlaps skip previously committed output. Trimming uses confirmed sentence/segment boundaries. |
| [WhisperKit eager example](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Examples/WhisperAX/WhisperAX/Views/ContentView.swift) | Word-level common-prefix agreement, a retained trailing word overlap, `clipTimestamps` and `prefixTokens`; separate confirmed text and hypothesis text. Its standard streaming path instead leaves a configurable number of trailing segments unconfirmed. |
| [WhisperLive](https://github.com/collabora/WhisperLive/blob/main/whisper_live/backend/base.py) | Emits completed segments separately from an incomplete last segment; repeated-output confirmation advances the retained audio offset. |
| [SimulStreaming](https://github.com/ufal/SimulStreaming) | AlignAtt uses decoder cross-attention near the audio edge to stop emission and resume with more input. Its voice-activity controller provides a separate end-of-voice signal. This requires decoder integration beyond our shared text/word-time adapter. |

[Montreal Forced Aligner](https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/)
aligns supplied transcripts to audio; that operation does not determine whether
an ASR hypothesis is ready to commit. [NVIDIA's EOU training tutorial](https://github.com/NVIDIA-NeMo/Speech/tree/main/examples/asr/asr_eou)
does recommend forced alignment to prepare start/end timestamps for training,
then adds special tokens and fine-tunes the model. Runtime EOU prediction is a
distinct capability: [Parakeet Realtime EOU 120M](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1)
has it; it cannot be assumed for our batch Parakeet TDT v3/WhisperKit adapters.
[FluidAudio distinguishes these models and VAD](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md).

The current implementation follows common-prefix confirmation during ordinary
updates and protects committed editor text. Its remaining confirmation gap is
the full-window fallback, which can commit mature words without two agreeing
hypotheses. Follow-up should preserve agreement-based prefix commitment and
trim only audio already accounted for by confirmed text, retaining context for
the unresolved tail. Window pressure or a pause must not force sentence
completion. Hands-free capture intentionally has no VAD-driven utterance-final
event; this is a product requirement, not a missing capability. Meeting durable
VAD segmentation remains separate and does not establish linguistic sentence
completion. WhisperKit can also use its supported prefix/seek controls rather
than rediscovering all owned words. These remain architectural follow-ups, not
properties of the recovery fix or proof of parity with native Nemotron streaming.

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
captured process. A single first key handles the empty-composer placeholder;
subsequent bursts contain at most eight whole graphemes. Precreate every event
pair before posting a burst, then verify its full value and caret before the
next burst. Exact intermediate prefixes of the posted burst may settle, but
cannot acknowledge completion or authorize another burst. Unrelated edits fail.
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
still-valid owned range. For Codex, final delivery is selected at capture time
as a leased clipboard paste, separate from the live keyboard transport. Preserve
the common leading and trailing text, select only the differing middle, and
dispatch one targeted Paste command after exact selection verification. Final
success requires exact resulting text/caret acknowledgment; dispatch alone is
insufficient. Clipboard providers are read off the main actor with a bounded
wait, and all item/type data must be saved with an unchanged generation before
staging. Restore saved contents only while still owning the staged clipboard,
after confirmed consumption or a failure before dispatch. After an unacknowledged
dispatch, retain the staged payload so a delayed receiver cannot paste the old
clipboard. Never overwrite a newer clipboard value or retry through another
transport. Multiline/control text remains unsupported by this composer lease.
If ownership was lost, save the result in history and
tell the user; do not overwrite their edits or paste into the newly focused app.
An empty final result does not erase already visible text. Cancel leaves inserted
text intact and rejects all late callbacks. Finalization remains identified by
the existing dictation task ID until completion.

## Overlapping work

These PRs are integration boundaries, not dependencies to merge blindly:

Live status verified October 24: #603, #645 and #476 open/ready; #630 and #646
open/draft. No overlapping PR is merged into this implementation branch.

- #603, clipboard providers: keep live revisions outside PasteController and
  preserve final task ownership. The dedicated Codex final-paste helper reads
  providers off-main with a deadline and verifies insertion independently of
  dispatch; reconcile this helper's ownership rules when integrating #603.
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

The smoother-delivery follow-up passed 100 native tests across four suites.
Live keyboard previews acknowledge bounded bursts rather than every grapheme;
final cleanup pastes the changed middle once, retaining exact common prefixes
and suffixes. Tests cover intermediate burst readbacks, clipboard provider
deadlines, clipboard ownership changes, focus/edit/cancellation races, and
unacknowledged dispatch without retries. Classifier and CI shard checks passed.
Injected event sinks validate transport behavior without posting input to apps;
the actual Codex composer experience still requires a manual dictation trial.

Parakeet-family expansion validation passed 189 focused native tests across 13
suites. An opt-in public 21.4-second speech fixture passed progressive timing,
stable-prefix and rollover checks on installed v2, v3, Redux and Unified models;
the three newly enabled models also passed full-file transcription. No models
were downloaded. A race in the preview-delivery test editor was fixed by making
its main-actor isolation explicit; production cursor delivery is unchanged.

Whisper Tiny follow-up reproduced premature preview termination on public English
speech: 16 seconds of real audio produced word ends near 30 seconds because the
pinned WhisperKit seeker included padded encoder attention in DTW. Cropping the
attention grid to real audio before alignment fixes that failure; it does not
clamp or fabricate word timestamps. A preview-only punctuation grouping also
avoids the pinned seeker's loss of lexical tokens beside consecutive punctuation.
Transient unusable alignments now preserve the visible preview and pending PCM,
with bounded retry on new audio. Cursor ownership and final cleanup are unchanged.

Tamil remains a known limitation of Tiny in this integration. A locally synthesized
23.9-second Tamil fixture produces Tamil previews with both auto-detection and
explicit Tamil, but revised words and onsets prevent reliable continuous ownership
across windows. The opt-in test records only that specific ownership exhaustion
as a known issue and independently requires nonempty full-file transcription;
other errors still fail. Full-file decoding usually returned text but one pinned
Tamil run returned empty, so this synthetic-fixture diagnostic remains failing
and Tiny Tamil is not accepted as reliable. Final decode options are unchanged.
This is not a passing continuous-Tamil acceptance test.
Retaining more anchor context did not resolve it and regressed an existing rollover
test, so that experiment is excluded. Do not relax ownership matching or interpret
silence as a sentence boundary to conceal this limitation.

The focused native regression run passed 207 tests across 14 suites with real-model
diagnostics disabled. The separate English Tiny regression passed every 2–21-second
prefix, progressive rollover and full-file transcription. CI classification and
shard checks passed. A delayed meeting-caption test now explicitly retains its
session through callback readback; production meeting delivery is unchanged.
These checks do not substitute for a manual Dev B composer trial, and the Tamil
diagnostic failures above remain outstanding.

The post-review cadence investigation reproduced delayed visible commits on the
real Whisper Turbo backend. The acceptance harness now measures committed cursor
text rather than draft-inclusive previews; changing hypotheses cannot conceal a
stalled visible prefix. Recorded hypotheses cover punctuation revisions,
zero-duration onset anchors, already-owned context after pauses, and mature groups
waiting unnecessarily for the physical eight-second rollover. Ordered boundary
agreement permits those mature groups to commit without relaxing cursor ownership.

A real-time 344.65-second Whisper Turbo replay with repeated 2-, 8-, and 18-second
pauses passed all four source-occurrence checks, monotonic committed output,
12-second resumed-speech progress checks, and tail-only finalization. It produced
126 cursor updates with median 20 UTF-16 characters and median 1.35-second spacing
within speech ranges (largest such interval 6.1 seconds). Four temporary alignment
deferrals recovered across three episodes without failing the progress checks.
One observed recognition
substitution, “cutting it release” for “cutting a release,” is accepted by the
occurrence check; no words are removed to make the test pass. The fixture ends in
18 seconds of silence, so its 55 ms finish does not measure immediate-stop latency.
The final separate real-model immediate-stop check finished Whisper's tail
in 2.46 seconds. These are fixture measurements, not a latency guarantee.

Independent review additionally found a synthetic overlapping-timestamp case:
a long owned word could outlive the last four saved anchors. Tracking the maximum
owned end keeps its lexical boundary until the existing silence margin passes,
with a regression preventing duplicate suffix insertion. Parakeet's default
commit and crop policies remain unchanged. Injected cursor tests exercise user
edits, focus changes, transient AX reads, acknowledgment, and final cleanup;
manual verification in the Codex composer is still required.

The final focused suite passed 361 tests across 17 suites. After the defensive
overlap fix, real Parakeet v3 multi-window recognition and both Parakeet/Whisper
immediate-stop reuse checks passed, including identical committed ownership with
presentation smoothing enabled or disabled.
