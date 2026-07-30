# Plan: Per-meeting speaker rename (named speakers)

## Context

Diarization already ships (FluidAudio 0.15.1 `DiarizerManager`, runs once at meeting finalize on system audio, labels `Speaker 1/2/...` via `TranscriptFormatter.merge`). What's missing is letting the user assign real names to those speakers. The transcript is stored as a flat string `"[HH:mm:ss] Speaker: text"` in SQLite `meetings.raw_transcript`, and the UI re-parses it with a regex that whitelists only `You|Others|Speaker N` (`TranscriptChatMessage.isLikelySpeakerLabel`, MeetingDetailView.swift).

Scope: per-meeting rename only. No cross-meeting voice memory, no live diarization changes, mic stays `"You"`.

## Design

Mapping-at-render. The stored `rawTranscript` keeps canonical labels (`You`/`Others`/`Speaker N`) forever; the rename map is stored as a nullable JSON column `speaker_names` (`{"Speaker 1":"Priya"}`) on `meetings`. The parser whitelist regex stays **untouched** — display name is resolved after parsing (`names[speaker] ?? speaker`). Flat-string consumers (export, summary) get a line-anchored substitution helper: `(?m)^(\[\d{2}:\d{2}:\d{2}\]\s+)Speaker 1:` → `$1Priya:` — it can never touch body text. `InsightsWordAnalyzer` / `AudioFileImportController` regexes need zero changes.

Known cosmetic gap (document in PR): the raw-text edit `TextEditor` shows canonical `Speaker 1` while chat bubbles show the real name — correct, since that editor edits the stored string.

## Steps

1. **Storage** — `native/MuesliNative/Sources/MuesliCore/DictationStore.swift`: add `speaker_names TEXT` to both CREATE TABLE variants (~102, 144) + column list (36) + idempotent `ALTER TABLE meetings ADD COLUMN speaker_names TEXT` (pattern at 242-248). Read into `MeetingRecord`, bind in inserts. New `updateMeetingSpeakerNames(id:speakerNamesJSON:)` mirroring `updateMeetingTranscript` (1759): `UPDATE meetings SET speaker_names=?, updated_at=?, sync_dirty=1`.
2. **Model** — `StorageModels.swift`: `MeetingRecord.speakerNamesJSON: String?` + computed `speakerNames: [String:String]` (empty on nil/parse failure). `SyncTextRecord.speakerNames: String?` default nil.
3. **Sync** — `MuesliICloudSyncEngine.swift`: write field ~1148 (with nil-clearing branch like `speakerTranscript` at 1140), read ~1177, add `"speakerNames"` to `desiredTextRecordKeys` ~1313. Bridge in DictationStore sync construction (~3308/3335) + inbound apply (~3577). Old clients ignore the unknown CK field — safe.
4. **Helper** — `TranscriptFormatter` extension (avoids new CI suite registration): `apply(names:to:) -> String` line-anchored regex replace, only labels matching `^Speaker \d+$`; convenience for producing the display transcript.
5. **Rename UI** — `MeetingDetailView.swift`: `TranscriptChatBubble` (1869) renders display name; context-menu "Rename speaker…" on the speaker label (only when speaker matches `^Speaker \d+$`); popover TextField, empty string removes the mapping. Validate: reject `You`/`Others`/`Speaker \d+` as new names. Save via new `MuesliController.updateMeetingSpeakerNames(id:names:)` modeled on `updateMeetingTranscript` (MuesliController.swift:4100): store → `scheduleICloudSyncAfterLocalChange()` → `syncAppState()`. Thread names into `MeetingTranscriptView` + copy-transcript action.
6. **Flat-string consumers** (apply helper at the boundary): `MeetingExporter` call sites (MeetingDetailView.swift:844, 849 — prefer an optional `speakerNames` param on export); `MeetingSummaryClient.summarize` resummarize paths (MuesliController.swift:3896, 6142); `MeetingMarkdownAutoExporter`. **Skip** the retranscribe path (3962): fresh diarization renumbers speakers. Explicitly unchanged: Insights, import, live transcript views.

## Tests

- `DictationStoreTests` (core shard, already registered): column round-trip, legacy-DB migration, `sync_dirty` set.
- `TranscriptFormatterTests.swift` (meetings shard, already registered): label-only replacement, body colons untouched, unmapped speakers untouched, idempotence.

## Risks

- Re-transcription renumbers diarization speakers → names may misattach; decide in PR whether to clear `speaker_names` on retranscribe success (recommended) or leave stale.
- Size: ~300-400 LOC incl. tests, ~8 files.

## Verification

1. `swift test --package-path native/MuesliNative` (or `./scripts/run_ci_test_shard.sh core|meetings`)
2. `scripts/test_ci_test_shards.sh` if test suites added
3. Build: `MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh`; manual smoke: record short meeting with system audio, rename Speaker 1, check bubbles/export/summary.
