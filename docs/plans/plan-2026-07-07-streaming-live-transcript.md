# Streaming Live Transcript for Meetings (issue #99)

## Problem

The live transcript tab (PR #182) simulates streaming: audio buffers until a VAD
pause boundary (3–5s), the chunk is batch-transcribed (1–3s more), and a
finished line is appended. Words appear 5–8s after they are spoken and never
mid-sentence. Maintainer steer on #99: build a Granola-type streaming UI backed
by a streaming-native model, not more VAD-chunk simulation.

## Approach: hybrid display layer

VAD chunks stay the durable commit mechanism — checkpoints, diarization, crash
recovery, resume, and the final transcript are untouched. Streaming partials are
a display-only layer for the in-flight segment: a dimmed, italic "tail" bubble
per source that updates as speech happens and settles into the committed
caption when the chunk transcribes.

The partials engine can be FluidAudio's Parakeet Realtime EOU 120M model,
Nemotron 3.5, or Apple Speech on macOS 26. Two independent sessions process mic
"You" and system "Others" audio. The selected meeting model still produces
every durable caption; live text is provisional and replaced only when that
existing VAD chunk finishes transcription.

### Gating

- Parakeet Realtime EOU or Nemotron explicitly downloaded from the Models
  screen, or Apple Speech assets managed by macOS 26
- `enable_live_streaming_partials` config (default true) as a kill switch

Without the model, the live view behaves exactly as before.

### Non-goals

- Replacing the VAD chunk pipeline, checkpoints, or selected meeting model.
- Persisting provisional EOU output; live notes-on-demand; in-meeting chat.
- In-meeting translation. Apple Speech can provide multilingual provisional
  captions, but it does not translate them.

## Architecture

- **`MeetingStreamingPartialSession`** (new): per-source buffer + serial drain.
  `enqueue([Float])` is called on `chunkRotationQueue` (cheap append under a
  lock); a bounded single-flight drain feeds 320 ms intervals into one
  `StreamingEouAsrManager` per source. `markSegmentBoundary()` (from VAD chunk
  rotation) snapshots the cumulative EOU text length; `commitSegment()` (when
  the existing chunk retires) hides that prefix so the tail keeps only text
  newer than the committed caption.
- **Apple Speech live adapter**: feeds a bounded `AsyncStream` into Apple's
  progressive `SpeechAnalyzer`. Results can arrive after `process(samples:)`
  returns, so callbacks carry the session lifecycle revision. Each VAD boundary
  freezes that segment's provisional text and rebuilds the analyzer while a
  bounded queue retains incoming audio. Pause/resume and source recovery use the
  same generation reset before new results are accepted.
- **`MeetingSession`**: taps AEC'd mic floats and raw system floats (the same
  streams the VADs consume), feeds the two sessions, marks boundaries in the
  rotation handlers, commits next to `onChunkTranscribed`, tears down with the
  VAD controllers.
- **`MeetingLiveCaptionModelStore`**: checks, downloads, loads, and removes only
  the 320 ms EOU model variant using FluidAudio's existing repository APIs.
- **`ModelsView`**: gives the dedicated English live-caption model an explicit
  download/delete lifecycle; meeting start never initiates a hidden download.
- **AppState**: `liveMeetingPartialYou` / `liveMeetingPartialOthers`,
  owner-gated by the existing `liveMeetingTranscriptOwnerID`, cleared wherever
  the live transcript is cleared.
- **`LiveTranscriptView`**: renders the partial tails as dimmed italic bubbles
  after the committed caption groups, outside the incremental-parse
  (`parsedLength`) invariant — partials never enter the transcript string.

## Edge cases

- Both sessions run independently so overlapping mic and system speech does not
  serialize one source behind the other. The bounded queues drop stale
  provisional intervals before they can delay recording or durable chunks.
- Rotation→commit gap: the frozen prefix stays visible until commit (no
  flicker-to-empty).
- Pause: the existing VAD rotations run first, tails clear, and buffered live
  audio drops. Cache-aware synchronous models stay warm; Apple Speech rebuilds
  its analyzer on resume so delayed pre-pause results cannot enter the new
  lifecycle.
- Asynchronous boundary finalization: Apple Speech freezes each segment at its
  VAD boundary. A durable commit removes only the matching frozen segment, so a
  later segment remains visible even when chunk transcriptions finish out of
  order. Delayed callbacks from the prior analyzer generation are ignored.
- Capture source recovery resets the affected live session before accepting
  audio from the rebuilt source.
- Transcriber failure mid-meeting: the session logs once and goes dormant;
  committed path unaffected.

## Risks

- ANE contention and memory use from two EOU managers plus the durable chunk
  backend must be measured during a long meeting. Failure remains isolated to
  the provisional session and falls back to committed captions.
- Apple Speech input uses a newest-wins bounded queue. Under sustained analyzer
  backpressure, stale provisional audio may be dropped rather than increasing
  memory or delaying recording and durable chunks.
- Apple Speech's finalized live-text prefix is bounded by the existing VAD
  maximum-duration rotation (currently five seconds); the analyzer and its live
  accumulator restart at every boundary. At most 12 frozen provisional
  segments are retained while durable chunks retire; older provisional text is
  dropped without affecting the durable transcript.
- Partial/committed text mismatch when the committed backend differs from
  Parakeet EOU — provisional text settles; inherent to the hybrid design.
