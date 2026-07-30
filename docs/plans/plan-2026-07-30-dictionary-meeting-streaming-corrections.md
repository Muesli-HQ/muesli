# Plan: Apply dictionary corrections to meetings + streaming dictation

## Context

A full corrections dictionary already exists (`CustomWord` word→replacement pairs with fuzzy Jaro-Winkler matching in `CustomWordMatcher`, `DictionaryView` CRUD UI, auto-suggestion flow) but is applied **only** to standard hold-to-talk dictation (`TranscriptionRuntime.transcribeDictation`). Meeting transcription bypasses it intentionally, and streaming (double-tap Nemotron) dictation also skips it. Goal: one dictionary applied to all future meeting transcripts and dictations.

## Design

Reuse `CustomWordMatcher` + existing `AppConfig.customWords`. Meeting transcripts are built FROM segments (`TranscriptFormatter.merge` consumes `SpeechSegment.text`), so corrections must hit segment text — correcting only `result.text` per chunk would have no effect on the final merged transcript.

`transcribeMeetingChunk` is the WRONG chokepoint: unified-Nemotron meetings source `systemSegments` from `MeetingStreamingPartialSession` and never call it, and repair/fallback passes risk double application (the matcher is not idempotent). Two touch points instead:

1. **Live meetings**: correct the final `micSegments`/`systemSegments` once at finalize, immediately before `TranscriptFormatter.merge` in `MeetingSession` — covers chunked, unified-Nemotron, repair, and fallback paths in one place. Live partials stay uncorrected (out of scope).
2. **Flat-text paths** (import + retranscribe): add `customWords: [CustomWord] = []` param to `transcribeMeeting` only, applied to `result.text` AND each `segment.text`; pass it only from `AudioFileImportController` and the retranscribe path. `MeetingSession` calls keep the default `[]` → no double application.

Use typed `[CustomWord]` for the new params; leave the untyped `serializedCustomWords()` bridge and the dictation path alone.

## Steps

1. **Helper** — `CustomWordMatcher.swift`: `apply(result: SpeechTranscriptionResult, customWords:) -> SpeechTranscriptionResult` correcting `result.text` + each segment text, preserving timings, early-return on empty words.
2. **`TranscriptionRuntime.swift`** — `transcribeMeeting` (407): add `customWords: [CustomWord] = []`, wrap return with the helper; update the stale "intentionally skip" comment (413). `transcribeMeetingChunk` untouched.
3. **`MeetingSession.swift`** — at finalize before `TranscriptFormatter.merge` (~636+): map mic/system segments through the helper using `config.customWords` (session already holds `config`). Grep all `TranscriptFormatter.merge` call sites; cover each.
4. **`AudioFileImportController.swift:185`** — pass `customWords: config.customWords`.
5. **`MuesliController.swift:3962`** (retranscribe) — pass `customWords: self.config.customWords`.
6. **`MuesliController.finishNemotronStreamingStop` (~7953)** — apply `CustomWordMatcher.apply(text:customWords:)` after `FillerWordFilter.apply(finalText)` before `insertDictation`. Note in PR: this corrects the stored history record only; live-typed text was already streamed, retro-backspacing is out of scope (matches existing FillerWordFilter precedent).
7. Optional: `DictionaryView` copy tweak noting global scope.

## Tests

- Extend `CustomWordMatcherTests.swift` (`dictation-transcription` shard — if a new test class name is used, register it in `run_ci_test_shard.sh`): segment timings preserved, text+segments corrected consistently, empty-words no-op.
- `TranscriptFormatterTests.swift`: integration test — segments corrected pre-merge appear corrected in the merged string.

## Risks

- Custom-word replacement inside meeting text touches all speakers' words — intended "global dictionary" semantics; note in PR.
- Phrase entries spanning segment boundaries won't match (matcher is space-tokenized per text) — accept, single words unaffected.
- Unified-Nemotron partials uncorrected until finalize — documented.
- Size: ~120-180 LOC incl. tests, ~6 files.

## Verification

1. `swift test --package-path native/MuesliNative` (or `./scripts/run_ci_test_shard.sh dictation-transcription|meetings`)
2. `scripts/test_ci_test_shards.sh` if test suites added
3. Build: `MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh`; manual smoke: add a dictionary entry, run a meeting + a double-tap dictation, confirm correction applied in both.
