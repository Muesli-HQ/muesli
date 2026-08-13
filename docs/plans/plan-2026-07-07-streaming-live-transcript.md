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

The partials engine is FluidAudio's Parakeet Realtime EOU 120M model at its
320 ms output cadence. Two independent cache-aware sessions process mic "You"
and system "Others" audio. The selected meeting model still produces every
durable caption; EOU text is provisional and replaced only when that existing
VAD chunk finishes transcription.

### Gating

- Parakeet Realtime EOU explicitly downloaded from the Models screen
- `enable_live_streaming_partials` config (default true) as a kill switch

Without the model, the live view behaves exactly as before.

### Non-goals

- Replacing the VAD chunk pipeline, checkpoints, or selected meeting model.
- Persisting provisional EOU output; live notes-on-demand; in-meeting chat.
- Multilingual provisional captions. The dedicated EOU model is English-only;
  the durable meeting pipeline retains its existing language support.

## Architecture

- **`MeetingStreamingPartialSession`** (new): per-source buffer + serial drain.
  `enqueue([Float])` is called on `chunkRotationQueue` (cheap append under a
  lock); a bounded single-flight drain feeds 320 ms intervals into one
  `StreamingEouAsrManager` per source. `markSegmentBoundary()` (from VAD chunk
  rotation) snapshots the cumulative EOU text length; `commitSegment()` (when
  the existing chunk retires) hides that prefix so the tail keeps only text
  newer than the committed caption.
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
- Pause: the existing VAD rotations run first, tails clear, buffered EOU audio
  drops, and resume keeps the model warm while hiding the pre-pause prefix.
- Transcriber failure mid-meeting: the session logs once and goes dormant;
  committed path unaffected.

## Risks

- ANE contention and memory use from two EOU managers plus the durable chunk
  backend must be measured during a long meeting. Failure remains isolated to
  the provisional session and falls back to committed captions.
- Partial/committed text mismatch when the committed backend differs from
  Parakeet EOU — provisional text settles; inherent to the hybrid design.
