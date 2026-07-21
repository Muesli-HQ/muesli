import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

/// Guards the per-target export-queue logic in `DictationStore` (no network): a record is
/// "needs export" while the target's synced clock (`s`) is null or older than `updated_at`,
/// and `markExported` clears it up to the read `updated_at` so edits re-export.
@Suite("Notion export store", .serialized)
struct NotionPushStoreTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-notion-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @Test("a fresh meeting needs a push; after markExported it doesn't; after an edit it does again")
    func meetingPushLifecycle() throws {
        let store = try makeStore()
        let id = try store.insertMeeting(
            title: "Sync me", calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_600),
            rawTranscript: "hello world", formattedNotes: "## Summary\n- point",
            micAudioPath: nil, systemAudioPath: nil
        )

        var pending = try store.meetingsNeedingExport(target: "notion")
        #expect(pending.count == 1)
        #expect(pending.first?.localID == id)
        #expect(pending.first?.existingRemoteID == nil)
        #expect(pending.first?.notesMarkdown == "## Summary\n- point")
        #expect(pending.first?.transcript == "hello world")
        let hasPending = try !store.meetingsNeedingExport(target: "notion").isEmpty
            || !store.dictationsNeedingExport(target: "notion").isEmpty
        #expect(hasPending)

        // Mark it exported at the updated_at it was read at → no longer pending.
        let updatedAt = try #require(pending.first?.updatedAt)
        #expect(try store.markExported(kind: .meeting, id: id, target: "notion", remoteID: "page-123", syncedAt: updatedAt))
        #expect(try store.meetingsNeedingExport(target: "notion").isEmpty)

        // An edit bumps updated_at → pending again, carrying the existing remote id.
        try store.updateMeetingNotes(id: id, formattedNotes: "## Summary\n- edited")
        pending = try store.meetingsNeedingExport(target: "notion")
        #expect(pending.count == 1)
        #expect(pending.first?.existingRemoteID == "page-123")
        #expect(pending.first?.notesMarkdown == "## Summary\n- edited")
    }

    @Test("dictations round-trip through the export queue")
    func dictationPushLifecycle() throws {
        let store = try makeStore()
        let id = try store.insertDictation(
            text: "quick note about the thing", durationSeconds: 4,
            appContext: "Xcode", startedAt: Date(), endedAt: Date()
        )
        let pending = try store.dictationsNeedingExport(target: "notion")
        let record = try #require(pending.first { $0.localID == id })
        #expect(record.kind == .dictation)
        #expect(record.transcript == "quick note about the thing")
        #expect(record.title == "quick note about the thing")   // derived from the first line
        #expect(record.appContext == "Xcode")

        #expect(try store.markExported(kind: .dictation, id: id, target: "notion", remoteID: "d-1", syncedAt: record.updatedAt))
        #expect(!(try store.dictationsNeedingExport(target: "notion").contains { $0.localID == id }))
    }

    @Test("markExported writes publish_state_json and the sync read path surfaces it")
    func markExportedPersistsPublishState() throws {
        let store = try makeStore()
        let id = try store.insertMeeting(
            title: "Publish me", calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_600),
            rawTranscript: "hello", formattedNotes: "## Notes",
            micAudioPath: nil, systemAudioPath: nil
        )
        let pending = try store.meetingsNeedingExport(target: "notion")
        let updatedAt = try #require(pending.first { $0.localID == id }?.updatedAt)

        #expect(try store.markExported(
            kind: .meeting, id: id, target: "notion", remoteID: "page-xyz", syncedAt: updatedAt
        ))

        // markExported sets sync_dirty = 1, so the record is now in the CloudKit read path.
        let syncRecords = try store.textRecordsNeedingSync()
        let record = try #require(syncRecords.first { $0.title == "Publish me" })
        let publishJSON = try #require(record.publishStateJSON)
        #expect(publishJSON.contains("page-xyz"))
        // The JSON maps into the correct column and decodes to the "notion" target's id.
        #expect(record.publishState()["notion"]?.id == "page-xyz")
    }

    @Test("the sync-migration query preserves publish_state_json (page id survives CloudKit seed)")
    func syncMigrationPreservesPublishState() throws {
        let store = try makeStore()

        // Meeting: mark exported so publish_state_json carries the Notion page id.
        let meetingID = try store.insertMeeting(
            title: "Migrate me", calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_600),
            rawTranscript: "hello", formattedNotes: "## Notes",
            micAudioPath: nil, systemAudioPath: nil
        )
        let pendingMeetings = try store.meetingsNeedingExport(target: "notion")
        let meetingUpdatedAt = try #require(pendingMeetings.first { $0.localID == meetingID }?.updatedAt)
        #expect(try store.markExported(
            kind: .meeting, id: meetingID, target: "notion", remoteID: "page-migrate", syncedAt: meetingUpdatedAt
        ))

        // Dictation: same, on the dictation column layout (index 12).
        let dictationID = try store.insertDictation(
            text: "note to migrate", durationSeconds: 3, appContext: "Xcode", startedAt: Date(), endedAt: Date()
        )
        let pendingDictations = try store.dictationsNeedingExport(target: "notion")
        let dictationUpdatedAt = try #require(pendingDictations.first { $0.localID == dictationID }?.updatedAt)
        #expect(try store.markExported(
            kind: .dictation, id: dictationID, target: "notion", remoteID: "d-migrate", syncedAt: dictationUpdatedAt
        ))

        // The one-time CloudKit seed reads through textRecordsForSyncMigration — the page id
        // must survive (regression guard for the dropped publish_state_json column).
        let migratedMeetings = try store.textRecordsForSyncMigration(kind: .meeting)
        let migratedMeeting = try #require(migratedMeetings.first { $0.title == "Migrate me" })
        #expect(migratedMeeting.publishState()["notion"]?.id == "page-migrate")

        let migratedDictations = try store.textRecordsForSyncMigration(kind: .dictation)
        let migratedDictation = try #require(migratedDictations.first { $0.publishStateJSON?.contains("d-migrate") == true })
        #expect(migratedDictation.publishState()["notion"]?.id == "d-migrate")
    }

    @Test("nothing needs a push once the queue is empty")
    func emptyQueue() throws {
        let store = try makeStore()
        #expect(try store.meetingsNeedingExport(target: "notion").isEmpty)
        #expect(try store.dictationsNeedingExport(target: "notion").isEmpty)
    }

    @Test("deleting a pushed meeting queues it for unpublish; clearExportState empties the queue")
    func deletedMeetingNeedsUnpublish() throws {
        let store = try makeStore()
        let id = try store.insertMeeting(
            title: "Archive me", calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_600),
            rawTranscript: "hello", formattedNotes: "## Notes",
            micAudioPath: nil, systemAudioPath: nil
        )
        let updatedAt = try #require(try store.meetingsNeedingExport(target: "notion").first?.updatedAt)
        try store.markExported(kind: .meeting, id: id, target: "notion", remoteID: "page-1", syncedAt: updatedAt)

        // Not deleted yet → nothing to unpublish.
        #expect(try store.recordsNeedingUnpublish(target: "notion").isEmpty)

        try store.deleteMeeting(id: id)
        let toUnpublish = try store.recordsNeedingUnpublish(target: "notion")
        #expect(toUnpublish.count == 1)
        #expect(toUnpublish.first?.kind == .meeting)
        #expect(toUnpublish.first?.localID == id)
        #expect(toUnpublish.first?.remoteID == "page-1")

        // Clearing the export state removes it from the unpublish queue (won't re-archive).
        #expect(try store.clearExportState(kind: .meeting, id: id, target: "notion"))
        #expect(try store.recordsNeedingUnpublish(target: "notion").isEmpty)
    }

    @Test("a live pushed record is never returned by recordsNeedingUnpublish")
    func nonDeletedPushedRecordNotUnpublished() throws {
        let store = try makeStore()
        let id = try store.insertMeeting(
            title: "Keep me", calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_600),
            rawTranscript: "hello", formattedNotes: "## Notes",
            micAudioPath: nil, systemAudioPath: nil
        )
        let updatedAt = try #require(try store.meetingsNeedingExport(target: "notion").first?.updatedAt)
        try store.markExported(kind: .meeting, id: id, target: "notion", remoteID: "page-keep", syncedAt: updatedAt)
        #expect(try store.recordsNeedingUnpublish(target: "notion").isEmpty)
    }

    @Test("PublishRef tolerates a string-shaped `s` (syncedAt) so the page id survives decode")
    func publishRefTolerantDecode() throws {
        // A peer/older version may serialize `s` as a String instead of a number. The page id
        // must survive — a throwing decode would null the ref and create a duplicate page.
        func decode(_ json: String) throws -> PublishRef {
            try JSONDecoder().decode(PublishRef.self, from: Data(json.utf8))
        }
        let stringS = try decode(#"{"id":"p","s":"123.5"}"#)
        #expect(stringS.id == "p")
        #expect(stringS.syncedAt == 123.5)

        let numberS = try decode(#"{"id":"p","s":123.5}"#)
        #expect(numberS.id == "p")
        #expect(numberS.syncedAt == 123.5)

        // A non-numeric `s` doesn't throw — the id is preserved, syncedAt falls back to nil.
        let garbageS = try decode(#"{"id":"p","s":"not-a-number"}"#)
        #expect(garbageS.id == "p")
        #expect(garbageS.syncedAt == nil)

        // Round-trips: encode keeps keys `id` + `s`.
        let data = try JSONEncoder().encode(PublishRef(id: "p", syncedAt: 7))
        let round = try JSONDecoder().decode(PublishRef.self, from: data)
        #expect(round == PublishRef(id: "p", syncedAt: 7))
    }

    @Test("a peer's publish-state is adopted even when the content-conflict gate blocks the row")
    func backfillPublishStateWhenContentGateBlocks() throws {
        let store = try makeStore()

        // Device-shared record arrives first (creates the local row, no publish-state yet).
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let v1 = SyncTextRecord(
            id: "rec-backfill", kind: .meeting, title: "T",
            text: "transcript", summaryText: "## LOCAL",
            publishStateJSON: nil,
            createdAt: created, updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            durationSeconds: 0, wordCount: 0
        )
        _ = try store.upsertSyncedTextRecord(v1)

        // Local pending edit → sync_dirty = 1, bumps updated_at.
        let localID = try #require(try store.recentMeetings().first { $0.title == "T" }?.id)
        try store.updateMeetingNotes(id: localID, formattedNotes: "## LOCAL EDIT")

        // Read the local updated_at so the peer record can arrive with the SAME clock — this
        // makes the content-conflict gate (updated_at equal AND sync_dirty = 0) fail.
        let localUpdatedAt = try #require(
            try store.textRecordsNeedingSync().first { $0.id == "rec-backfill" }?.updatedAt
        )

        // Peer record: same clock, carries the shared page id + a different body.
        let v2 = SyncTextRecord(
            id: "rec-backfill", kind: .meeting, title: "T",
            text: "transcript", summaryText: "## REMOTE OVERWRITE",
            publishStateJSON: #"{"notion":{"id":"page-shared","s":123}}"#,
            createdAt: created, updatedAt: localUpdatedAt,
            durationSeconds: 0, wordCount: 0
        )
        _ = try store.upsertSyncedTextRecord(v2)

        let after = try #require(
            try store.textRecordsNeedingSync().first { $0.id == "rec-backfill" }
        )
        // Page id adopted (dedup) even though the content gate blocked the row...
        #expect(after.publishState()["notion"]?.id == "page-shared")
        // ...and the local edit was NOT overwritten by the peer's body.
        #expect(after.summaryText == "## LOCAL EDIT")
    }
}
