# Meeting speaker roadmap S2

## Goals and boundaries

- A speaker key maps to the same light and dark colour after rename, display-rank
  changes, serialization, and relaunch. Labels remain visible, and colour alone
  does not carry identity.
- The owner uses a fixed token. Unknown and aggregate sources use the neutral
  token. Remote speakers use a deterministic FNV-1a hash into the six-colour
  palette and must meet the tested contrast threshold on transcript surfaces.
- Distinct remote keys can hash to the same palette entry. This collision is
  accepted; the palette does not promise globally unique colours.
- A successful re-transcription creates a new diarization epoch, so colours may
  change. A failed or cancelled retry restores the prior speaker state only if
  both the retry transcript version and rendered-text digest still match.
- S2 supplies live and floating render APIs but does not add live diarization.
  S6 owns the producer integration.

## Live producer contract for S6

`MeetingSession` currently exposes `onChunkTranscribed: ([SpeechSegment],
String) -> Void` for finalized, source-tagged chunks and
`onPartialTranscript: (String, String) -> Void` for a source label and partial
tail. It has no `onTranscript` callback. S6 should add a structured-turn
callback or extend `onChunkTranscribed` to deliver stable `MeetingSpeakerKey`s
and the corresponding `MeetingSpeakerState`; it must also define how the
source-tagged partial tail maps to structured speaker state. Thread that state
through the `MuesliController` handlers into `LiveTranscriptView` and
`FloatingIndicatorController.updateMeetingTranscript`. Keep keys meeting-scoped
and stable across renames, display-rank changes, and partial-to-final updates.
Missing keys retain the neutral/source-label fallback.

## Summary freshness

`summary_stale` is local derived state. Every remote meeting upsert compares its
value before and after applying the record in one store transaction. Notify only
IDs whose value changed, and separately report applied tombstones so
`AppState` can drop their revision entries. Local deletion and clearing history
also remove those entries. Revision notifications cover current browser rows
and the selected meeting (which may be outside the browser's filtered 200-row
window), while excluding tombstoned IDs. Missing freshness from an older client
remains unknown and does not overwrite stored state. Failed summaries remain
stale; only a successful summary for the matching transcript can clear the flag.

`markMeetingSummaryStale` checks the transcript version in a `BEGIN IMMEDIATE`
transaction. That lookup filters out deleted meetings, and the write uses the
shared setter, which also requires `deleted_at IS NULL` and preserves the stored
generation.

## Import and retry behavior

Audio-file imports enable `preserveSegmentBoundaries` while consolidating
nearby same-speaker ASR windows. Adjacent windows are joined with a separating
space, so short words such as `Go` and `now` remain separate. Other formatter
paths keep their existing token-fragment joining heuristic.

Before re-transcription, the app captures the prior speaker snapshot and the
retry transcript version. On failure or cancellation it restores the snapshot
only if the current transcript version and rendered-text digest still match;
otherwise the stale speaker state remains unavailable.

## Review and revert scope

The branch contract requires this roadmap item to remain one commit above #639.
The commit therefore cannot be split into per-concern commits. Several shared
files contain multiple concerns, so use hunk-level selection for a targeted
revert or iteration; a file-level revert can remove unrelated behavior.

| Concern | Main files and hunks |
| --- | --- |
| Palette and styling | `MeetingSpeakerPalette.swift`, `MeetingSpeakerStyle.swift`, `LiveTranscriptView.swift`, `FloatingIndicatorController.swift`, `FloatingMeetingTranscriptPanel.swift`, `MuesliTheme.swift`, saved/live bubble styling in `MeetingDetailView.swift`, `MeetingSpeakerPaletteTests.swift` |
| Summary freshness | `DictationStore.swift`, `StorageModels.swift`, `AppState.swift`, `MuesliCKSyncEngine.swift`, `MuesliICloudSyncEngine.swift`, summary callback/persistence hunks in `MuesliController.swift`, load-key hunks in `MeetingDetailView.swift`, freshness cases in `DictationStoreTests.swift`, `MuesliCKSyncEngineTests.swift`, `MeetingsNavigationTests.swift`, `MeetingResumePolicyTests.swift`, and `MeetingHookIntegrationTests.swift` |
| Re-transcription restore | `restoreMeetingSpeakerState` in `DictationStore.swift`; retry snapshot/version handling in `MuesliController.swift`; retry cases in `MeetingSpeakerStoreTests.swift` |
| Audio import formatting | import call in `AudioFileImportController.swift`; segment joining in `TranscriptFormatter.swift`; import regression cases in `AudioFileImportControllerTests.swift` |
| Citation locator | turn-range lookup in `MeetingChatCitationView.swift`; loaded range cache in `MeetingDetailView.swift`; locator tests in `MeetingChatNavigationTests.swift` |

`DictationStore.swift`, `MuesliController.swift`, and `MeetingDetailView.swift`
are shared across the scopes listed above; revert only the relevant hunks.
