import Testing
import CloudKit
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

@Suite("DictationStore", .serialized)
struct DictationStoreTests {

    /// Creates a DictationStore backed by a temporary database file.
    /// Each test gets its own isolated DB — no production data is touched.
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeLegacyStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-legacy-test-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return DictationStore(databaseURL: url)
    }

    private func sqliteTestError(_ message: String) -> NSError {
        NSError(domain: "DictationStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func setDictationDirtyText(
        recordName: String,
        text: String,
        updatedAt: Date,
        store: DictationStore
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &db) == SQLITE_OK else {
            throw sqliteTestError("failed to open test database")
        }
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE dictations
        SET raw_text = ?, word_count = ?, updated_at = ?, sync_dirty = 1
        WHERE cloud_record_name = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteTestError("failed to prepare dictation update")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(DictationStore.countWords(in: text)))
        sqlite3_bind_double(statement, 3, updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, (recordName as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw sqliteTestError("failed to dirty dictation row")
        }
    }

    private func setMeetingDirtyTitle(
        recordName: String,
        title: String,
        updatedAt: Date,
        store: DictationStore
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &db) == SQLITE_OK else {
            throw sqliteTestError("failed to open test database")
        }
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE meetings
        SET title = ?, updated_at = ?, sync_dirty = 1
        WHERE cloud_record_name = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteTestError("failed to prepare meeting update")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, (recordName as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw sqliteTestError("failed to dirty meeting row")
        }
    }

    @Test("migration creates tables without error")
    func migration() throws {
        let store = try makeStore()
        try store.migrateIfNeeded() // idempotent
    }

    @Test("migration adds template columns to legacy meeting schema")
    func migrationAddsTemplateColumns() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let meeting = try store.meeting(id: 1)
        #expect(meeting == nil)
        try store.insertMeeting(
            title: "Legacy Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(60),
            rawTranscript: "Legacy transcript",
            formattedNotes: "Legacy notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: "one-to-one",
            selectedTemplateName: "1 to 1",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Check-In"
        )
        let inserted = try store.recentMeetings(limit: 1).first
        #expect(inserted?.selectedTemplateID == "one-to-one")
        #expect(inserted?.selectedTemplateKind == .builtin)
        #expect(inserted?.savedRecordingPath == nil)
        #expect(inserted?.status == .completed)
        #expect(inserted?.manualNotes == "")
        #expect(inserted?.source == .meeting)
    }

    @Test("migration adds saved recording path column to legacy meeting schema")
    func migrationAddsSavedRecordingColumn() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let start = Date()
        try store.insertMeeting(
            title: "Saved Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/meeting.wav"
        )

        let inserted = try store.recentMeetings(limit: 1).first
        #expect(inserted?.savedRecordingPath == "/tmp/meeting.wav")
    }

    @Test("meeting source is persisted")
    func meetingSourcePersists() throws {
        let store = try makeStore()
        let start = Date()

        try store.insertMeeting(
            title: "Imported Audio",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/import.wav",
            source: .audioImport
        )

        let inserted = try #require(try store.recentMeetings(limit: 1).first)
        #expect(inserted.source == .audioImport)
    }

    @Test("synced iOS dictation preserves source and is clean")
    func syncedIOSDictationPreservesSource() throws {
        let store = try makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_770_000_000)

        let applied = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-1",
            kind: .dictation,
            text: "Captured on iPhone",
            source: "ios",
            createdAt: createdAt,
            updatedAt: createdAt,
            startedAt: createdAt.addingTimeInterval(-2),
            endedAt: createdAt,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-1"
        ))

        #expect(applied == true)
        let row = try #require(try store.recentDictations(limit: 1).first)
        #expect(row.rawText == "Captured on iPhone")
        #expect(row.source == "ios")
        #expect(try store.textRecordsNeedingSync().isEmpty)
    }

    @Test("older synced dictation is skipped and reported as not applied")
    func olderSyncedDictationIsSkipped() throws {
        let store = try makeStore()
        let older = Date(timeIntervalSince1970: 1_770_000_000)
        let newer = older.addingTimeInterval(60)

        let firstApply = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-newer",
            kind: .dictation,
            text: "Newer local text",
            source: "ios",
            createdAt: older,
            updatedAt: newer,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-new"
        ))
        #expect(firstApply == true)

        let secondApply = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-newer",
            kind: .dictation,
            text: "Older cloud text",
            source: "ios",
            createdAt: older,
            updatedAt: older,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-old"
        ))
        #expect(secondApply == false)

        let row = try #require(try store.recentDictations(limit: 1).first)
        #expect(row.rawText == "Newer local text")
        #expect(try store.textRecordsNeedingSync().isEmpty)
    }

    @Test("same timestamp synced dictation preserves dirty local edit")
    func sameTimestampSyncedDictationPreservesDirtyLocalEdit() throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-tie",
            kind: .dictation,
            text: "Original cloud text",
            source: "ios",
            createdAt: timestamp,
            updatedAt: timestamp,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-original"
        )))

        try setDictationDirtyText(
            recordName: "dictation-ios-tie",
            text: "Local edit with tied timestamp",
            updatedAt: timestamp,
            store: store
        )

        let applied = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-tie",
            kind: .dictation,
            text: "Remote tied text",
            source: "ios",
            createdAt: timestamp,
            updatedAt: timestamp,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-tied"
        ))

        #expect(applied == false)
        let row = try #require(try store.recentDictations(limit: 1).first)
        #expect(row.rawText == "Local edit with tied timestamp")
        let dirty = try #require(try store.textRecordsNeedingSync().first { $0.id == "dictation-ios-tie" })
        #expect(dirty.text == "Local edit with tied timestamp")
    }

    @Test("same timestamp synced dictation updates clean local row")
    func sameTimestampSyncedDictationUpdatesCleanLocalRow() throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-clean-tie",
            kind: .dictation,
            text: "Original cloud text",
            source: "ios",
            createdAt: timestamp,
            updatedAt: timestamp,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-original"
        )))

        let applied = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-clean-tie",
            kind: .dictation,
            text: "Remote tied update",
            source: "ios",
            createdAt: timestamp,
            updatedAt: timestamp,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-tied"
        ))

        #expect(applied)
        let row = try #require(try store.recentDictations(limit: 1).first)
        #expect(row.rawText == "Remote tied update")
        #expect(try store.textRecordsNeedingSync().isEmpty)
    }

    @Test("local Mac dictation sync record uses macOS source")
    func localMacDictationSyncRecordUsesMacOSSource() throws {
        let store = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_770_000_000)

        _ = try store.insertDictation(
            text: "Captured on Mac",
            durationSeconds: 2,
            source: "dictation",
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt
        )

        let record = try #require(try store.textRecordsNeedingSync().first { $0.kind == .dictation })
        #expect(record.text == "Captured on Mac")
        #expect(record.source == "macos")
        #expect(record.localSource == "dictation")
    }

    @Test("local Mac CUA dictation keeps subtype through sync record")
    func localMacCUADictationKeepsSubtypeThroughSyncRecord() throws {
        let sourceStore = try makeStore()
        let targetStore = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_770_000_000)

        _ = try sourceStore.insertDictation(
            text: "Captured through CUA",
            durationSeconds: 2,
            source: "cua",
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt
        )

        let outbound = try #require(try sourceStore.textRecordsNeedingSync().first { $0.kind == .dictation })
        #expect(outbound.source == "macos")
        #expect(outbound.localSource == "cua")

        let applied = try targetStore.upsertSyncedTextRecord(outbound)
        #expect(applied)
        let imported = try #require(try targetStore.recentDictations(limit: 1).first)
        #expect(imported.source == "cua")
    }

    @Test("local Mac meeting sync record uses macOS source")
    func localMacMeetingSyncRecordUsesMacOSSource() throws {
        let store = try makeStore()
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)

        try store.insertMeeting(
            title: "Mac Meeting",
            calendarEventID: nil,
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(90),
            rawTranscript: "Mac transcript",
            formattedNotes: "Mac notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let record = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        #expect(record.title == "Mac Meeting")
        #expect(record.source == "macos")
        #expect(record.localSource == MeetingSource.meeting.rawValue)
        #expect(record.speakerTranscript == nil)
        #expect(record.meetingStatus == .completed)
    }

    @Test("local Mac audio import meeting keeps subtype through sync record")
    func localMacAudioImportMeetingKeepsSubtypeThroughSyncRecord() throws {
        let sourceStore = try makeStore()
        let targetStore = try makeStore()
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)

        try sourceStore.insertMeeting(
            title: "Imported Meeting",
            calendarEventID: nil,
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(90),
            rawTranscript: "Imported transcript",
            formattedNotes: "Imported notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            source: .audioImport
        )

        let outbound = try #require(try sourceStore.textRecordsNeedingSync().first { $0.kind == .meeting })
        #expect(outbound.source == "macos")
        #expect(outbound.localSource == MeetingSource.audioImport.rawValue)

        let applied = try targetStore.upsertSyncedTextRecord(outbound)
        #expect(applied)
        let imported = try #require(try targetStore.recentMeetings(limit: 1).first)
        #expect(imported.source == .audioImport)
    }

    @Test("migration repairs macOS-origin meeting source corrupted by stale iOS CloudKit metadata")
    func migrationRepairsMacOriginMeetingSource() throws {
        let store = try makeStore()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let updatedAt = Date(timeIntervalSince1970: 1_770_000_000).timeIntervalSince1970
        let recordName = "meeting-00000000-0000-4000-8000-000000000001"
        let sql = """
        INSERT INTO meetings (
            title, start_time, end_time, duration_seconds, raw_transcript,
            formatted_notes, word_count, source, updated_at, cloud_record_name,
            last_synced_at, sync_dirty
        )
        VALUES (
            'Mac-origin meeting', '2026-06-16T10:00:00Z', '2026-06-16T10:01:00Z',
            60, 'Mac text', 'Mac notes', 2, 'ios', \(updatedAt),
            '\(recordName)', \(updatedAt), 0
        )
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        try store.migrateIfNeeded()

        let meeting = try #require(try store.recentMeetings(limit: 1).first)
        #expect(meeting.source == .meeting)
        let record = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        #expect(record.id == recordName)
        #expect(record.source == "macos")
    }

    @Test("sync import treats macOS-prefixed meeting records as Mac origin")
    func syncImportTreatsMacPrefixedMeetingRecordsAsMacOrigin() throws {
        let store = try makeStore()
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)

        try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-00000000-0000-4000-8000-000000000001",
            kind: .meeting,
            title: "Mac Meeting",
            text: "Mac transcript",
            summaryText: "Mac notes",
            source: "ios",
            meetingStatus: .completed,
            createdAt: startedAt,
            updatedAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2,
            cloudChangeTag: "tag-1"
        ))

        let meeting = try #require(try store.recentMeetings(limit: 1).first)
        #expect(meeting.source == .meeting)
        #expect(try store.textRecordsNeedingSync().isEmpty)
    }

    @Test("same timestamp synced meeting preserves dirty local edit")
    func sameTimestampSyncedMeetingPreservesDirtyLocalEdit() throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-ios-tie",
            kind: .meeting,
            title: "Original meeting",
            text: "Original transcript",
            summaryText: "Original notes",
            source: "ios",
            meetingStatus: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2,
            cloudChangeTag: "tag-original"
        )))

        try setMeetingDirtyTitle(
            recordName: "meeting-ios-tie",
            title: "Local meeting title",
            updatedAt: timestamp,
            store: store
        )

        let applied = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-ios-tie",
            kind: .meeting,
            title: "Remote tied meeting",
            text: "Remote transcript",
            summaryText: "Remote notes",
            source: "ios",
            meetingStatus: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2,
            cloudChangeTag: "tag-tied"
        ))

        #expect(applied == false)
        let row = try #require(try store.recentMeetings(limit: 1).first)
        #expect(row.title == "Local meeting title")
        let dirty = try #require(try store.textRecordsNeedingSync().first { $0.id == "meeting-ios-tie" })
        #expect(dirty.title == "Local meeting title")
    }

    @Test("same timestamp synced meeting updates clean local row")
    func sameTimestampSyncedMeetingUpdatesCleanLocalRow() throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-ios-clean-tie",
            kind: .meeting,
            title: "Original meeting",
            text: "Original transcript",
            summaryText: "Original notes",
            source: "ios",
            meetingStatus: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2,
            cloudChangeTag: "tag-original"
        )))

        let applied = try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-ios-clean-tie",
            kind: .meeting,
            title: "Remote tied meeting",
            text: "Remote transcript",
            summaryText: "Remote notes",
            source: "ios",
            meetingStatus: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2,
            cloudChangeTag: "tag-tied"
        ))

        #expect(applied)
        let row = try #require(try store.recentMeetings(limit: 1).first)
        #expect(row.title == "Remote tied meeting")
        #expect(row.formattedNotes == "Remote notes")
        #expect(try store.textRecordsNeedingSync().isEmpty)
    }

    @Test("deleted unsynced local text records are not uploaded")
    func deletedUnsyncedLocalTextRecordsAreNotUploaded() throws {
        let store = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let dictationID = try store.insertDictation(
            text: "Delete before iCloud sees this",
            durationSeconds: 2,
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt
        )
        try store.insertMeeting(
            title: "Delete Meeting Before Sync",
            calendarEventID: nil,
            startTime: endedAt,
            endTime: endedAt.addingTimeInterval(60),
            rawTranscript: "Meeting content that should stay local",
            formattedNotes: "Meeting notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetingID = try #require(try store.recentMeetings(limit: 1).first?.id)
        try store.deleteDictation(id: dictationID)
        try store.deleteMeeting(id: meetingID)

        #expect(try store.textRecordsNeedingSync().isEmpty)
        #expect(try store.textRecordsForSyncMigration(kind: .dictation).isEmpty)
        #expect(try store.textRecordsForSyncMigration(kind: .meeting).isEmpty)
    }

    @Test("deleted synced local text records upload tombstones")
    func deletedSyncedLocalTextRecordsUploadTombstones() throws {
        let store = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let dictationID = try store.insertDictation(
            text: "Delete after iCloud sees this",
            durationSeconds: 2,
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt
        )
        let outbound = try #require(try store.textRecordsNeedingSync().first { $0.kind == .dictation })
        _ = try store.markTextRecordSynced(
            kind: .dictation,
            recordName: outbound.id,
            changeTag: "tag-before-delete",
            recordUpdatedAt: outbound.updatedAt
        )

        try store.deleteDictation(id: dictationID)

        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.kind == .dictation })
        #expect(tombstone.id == outbound.id)
        #expect(tombstone.isDeleted)
        #expect(tombstone.text.isEmpty)
        #expect(tombstone.wordCount == 0)
        #expect(tombstone.durationSeconds == 0)
    }

    @Test("dirty sync queue respects total limit while including both record kinds")
    func dirtySyncQueueRespectsTotalLimitWhileIncludingBothRecordKinds() throws {
        let store = try makeStore()
        let baseDate = Date(timeIntervalSince1970: 1_770_000_000)

        for index in 0..<205 {
            let endedAt = baseDate.addingTimeInterval(TimeInterval(index))
            _ = try store.insertDictation(
                text: "Dirty dictation \(index)",
                durationSeconds: 1,
                startedAt: endedAt.addingTimeInterval(-1),
                endedAt: endedAt
            )
        }
        try store.insertMeeting(
            title: "Dirty meeting",
            calendarEventID: nil,
            startTime: baseDate.addingTimeInterval(1_000),
            endTime: baseDate.addingTimeInterval(1_060),
            rawTranscript: "Meeting text",
            formattedNotes: "Meeting notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let firstPage = try store.textRecordsNeedingSync(limit: 200)
        #expect(firstPage.count == 200)
        #expect(firstPage.filter { $0.kind == .dictation }.count == 199)
        #expect(firstPage.contains { $0.kind == .meeting && $0.title == "Dirty meeting" })
        #expect(try store.hasTextRecordsNeedingSync())

        for record in firstPage {
            #expect(try store.markTextRecordSynced(
                kind: record.kind,
                recordName: record.id,
                changeTag: "tag-\(record.id)",
                recordUpdatedAt: record.updatedAt
            ))
        }

        #expect(try store.hasTextRecordsNeedingSync())
        let secondPage = try store.textRecordsNeedingSync(limit: 200)
        #expect(secondPage.count == 6)
        #expect(secondPage.allSatisfy { $0.kind == .dictation })

        for record in secondPage {
            #expect(try store.markTextRecordSynced(
                kind: record.kind,
                recordName: record.id,
                changeTag: "tag-\(record.id)",
                recordUpdatedAt: record.updatedAt
            ))
        }
        let hasPendingAfterSecondPage = try store.hasTextRecordsNeedingSync()
        #expect(hasPendingAfterSecondPage == false)
    }

    @Test("soft delete tombstones purge only after sync and retention")
    func softDeleteTombstonesPurgeOnlyAfterSyncAndRetention() throws {
        let store = try makeStore()
        let now = Date()
        let retention: TimeInterval = 30 * 24 * 60 * 60

        let syncedDictationID = try store.insertDictation(
            text: "Already synced",
            durationSeconds: 2,
            startedAt: now.addingTimeInterval(-2),
            endedAt: now
        )
        let outbound = try #require(try store.textRecordsNeedingSync().first { $0.kind == .dictation })
        #expect(try store.markTextRecordSynced(
            kind: .dictation,
            recordName: outbound.id,
            changeTag: "tag-before-delete",
            recordUpdatedAt: outbound.updatedAt,
            syncedAt: now
        ))
        try store.deleteDictation(id: syncedDictationID)
        let syncedTombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == outbound.id })
        #expect(try store.markTextRecordSynced(
            kind: .dictation,
            recordName: syncedTombstone.id,
            changeTag: "tag-after-delete",
            recordUpdatedAt: syncedTombstone.updatedAt,
            syncedAt: now
        ))

        let unsyncedDictationID = try store.insertDictation(
            text: "Never uploaded",
            durationSeconds: 2,
            startedAt: now.addingTimeInterval(-2),
            endedAt: now
        )
        let unsyncedRecord = try #require(try store.textRecordsNeedingSync().first { $0.kind == .dictation })
        try store.deleteDictation(id: unsyncedDictationID)

        let earlyPurge = try store.purgeSoftDeletedTextRecords(
            olderThan: retention,
            now: now.addingTimeInterval(retention - 60)
        )
        #expect(earlyPurge.dictations == 0)
        #expect(earlyPurge.meetings == 0)

        let latePurge = try store.purgeSoftDeletedTextRecords(
            olderThan: retention,
            now: now.addingTimeInterval(retention + 60)
        )
        #expect(latePurge.dictations == 1)
        #expect(latePurge.meetings == 0)

        let remainingDirty = try store.textRecordsNeedingSync()
        #expect(remainingDirty.contains { $0.id == unsyncedRecord.id && $0.isDeleted })
        #expect(!remainingDirty.contains { $0.id == outbound.id })
    }

    @Test("deleted sync cloud records omit text content fields")
    func deletedSyncCloudRecordsOmitTextContentFields() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let record = SyncTextRecord(
            id: "meeting-deleted-content",
            kind: .meeting,
            title: "Sensitive title",
            text: "Sensitive transcript",
            speakerTranscript: "Speaker 1: Sensitive transcript",
            summaryText: "Sensitive summary",
            manualNotes: "Sensitive notes",
            source: "ios",
            meetingStatus: .completed,
            engineIdentifier: "engine",
            createdAt: deletedAt.addingTimeInterval(-120),
            updatedAt: deletedAt,
            startedAt: deletedAt.addingTimeInterval(-120),
            endedAt: deletedAt,
            durationSeconds: 120,
            wordCount: 2,
            isDeleted: true
        )

        let cloud = MuesliICloudSyncEngine.syncZoneCloudRecord(from: record)

        #expect(cloud["isDeleted"] as? NSNumber == true)
        #expect(cloud["kind"] as? String == SyncTextRecordKind.meeting.rawValue)
        #expect(cloud["source"] as? String == "ios")
        #expect(cloud["meetingStatus"] as? String == MeetingStatus.completed.rawValue)
        #expect(cloud["text"] == nil)
        #expect(cloud["title"] == nil)
        #expect(cloud["speakerTranscript"] == nil)
        #expect(cloud["summaryText"] == nil)
        #expect(cloud["manualNotes"] == nil)
        let changedKeys = Set(cloud.changedKeys())
        #expect(changedKeys.isSuperset(of: ["title", "text", "speakerTranscript", "summaryText", "manualNotes"]))
    }

    @Test("sync cloud record can update an existing server record")
    func syncCloudRecordCanUpdateExistingServerRecord() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let recordID = CKRecord.ID(
            recordName: "dictation-existing-record",
            zoneID: CKRecordZone.ID(zoneName: "MuesliSyncZone", ownerName: CKCurrentUserDefaultName)
        )
        let baseRecord = CKRecord(recordType: "MuesliTextRecord", recordID: recordID)
        baseRecord["text"] = "Server text" as NSString
        baseRecord["updatedAt"] = updatedAt.addingTimeInterval(-60) as NSDate

        let cloud = MuesliICloudSyncEngine.syncZoneCloudRecord(
            from: SyncTextRecord(
                id: recordID.recordName,
                kind: .dictation,
                text: "Local dirty text",
                source: "macos",
                createdAt: updatedAt.addingTimeInterval(-60),
                updatedAt: updatedAt,
                durationSeconds: 2,
                wordCount: 3
            ),
            baseRecord: baseRecord
        )

        #expect(cloud === baseRecord)
        #expect(cloud.recordID == recordID)
        #expect(cloud["text"] as? String == "Local dirty text")
        #expect(cloud["updatedAt"] as? Date == updatedAt)
    }

    @Test("dirty upload resolution applies newer fetched remote")
    func dirtyUploadResolutionAppliesNewerFetchedRemote() throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let remoteUpdatedAt = localUpdatedAt.addingTimeInterval(30)
        let local = SyncTextRecord(
            id: "dictation-upload-conflict",
            kind: .dictation,
            text: "Local stale text",
            source: "macos",
            createdAt: localUpdatedAt,
            updatedAt: localUpdatedAt,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-old"
        )
        let remote = SyncTextRecord(
            id: "dictation-upload-conflict",
            kind: .dictation,
            text: "Remote newer text",
            source: "ios",
            createdAt: localUpdatedAt,
            updatedAt: remoteUpdatedAt,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-new"
        )

        #expect(MuesliICloudSyncEngine.shouldApplyFetchedRemoteBeforeDirtyUpload(
            local: local,
            remote: remote,
            fetchedChangeTag: "tag-new"
        ))
    }

    @Test("dirty upload resolution keeps newer local edit")
    func dirtyUploadResolutionKeepsNewerLocalEdit() throws {
        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let localUpdatedAt = remoteUpdatedAt.addingTimeInterval(30)
        let local = SyncTextRecord(
            id: "dictation-upload-local-wins",
            kind: .dictation,
            text: "Local newer text",
            source: "macos",
            createdAt: remoteUpdatedAt,
            updatedAt: localUpdatedAt,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-old"
        )
        let remote = SyncTextRecord(
            id: "dictation-upload-local-wins",
            kind: .dictation,
            text: "Remote older text",
            source: "ios",
            createdAt: remoteUpdatedAt,
            updatedAt: remoteUpdatedAt,
            durationSeconds: 2,
            wordCount: 3,
            cloudChangeTag: "tag-new"
        )

        #expect(!MuesliICloudSyncEngine.shouldApplyFetchedRemoteBeforeDirtyUpload(
            local: local,
            remote: remote,
            fetchedChangeTag: "tag-new"
        ))
    }

    @Test("synced iOS meeting preserves source and excludes audio")
    func syncedIOSMeetingPreservesSourceAndExcludesAudio() throws {
        let store = try makeStore()
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)

        try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-ios-1",
            kind: .meeting,
            title: "iPhone Meeting",
            text: "Plain transcript",
            speakerTranscript: "Speaker 1: shipped text only",
            summaryText: "## Summary\nText only",
            manualNotes: "- Follow up",
            source: "ios",
            meetingStatus: .noteOnly,
            createdAt: startedAt,
            updatedAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            durationSeconds: 90,
            wordCount: 5,
            cloudChangeTag: "tag-2"
        ))

        let meeting = try #require(try store.recentMeetings(limit: 1).first)
        #expect(meeting.title == "iPhone Meeting")
        #expect(meeting.rawTranscript == "Speaker 1: shipped text only")
        #expect(meeting.formattedNotes == "## Summary\nText only")
        #expect(meeting.manualNotes == "- Follow up")
        #expect(meeting.source == .iOS)
        #expect(meeting.status == .noteOnly)
        #expect(meeting.micAudioPath == nil)
        #expect(meeting.systemAudioPath == nil)
        #expect(meeting.savedRecordingPath == nil)
        #expect(try store.textRecordsNeedingSync().isEmpty)
    }

    @Test("CloudKit expired change token errors are detected")
    func cloudKitExpiredChangeTokenErrorsAreDetected() {
        #expect(MuesliICloudSyncEngine.isChangeTokenExpired(CKError(.changeTokenExpired)))
        #expect(!MuesliICloudSyncEngine.isChangeTokenExpired(CKError(.networkUnavailable)))
    }

    @Test("CloudKit server record changed errors are detected")
    func cloudKitServerRecordChangedErrorsAreDetected() {
        let recordID = CKRecord.ID(
            recordName: "dictation-conflict",
            zoneID: CKRecordZone.ID(zoneName: "MuesliSyncZone", ownerName: CKCurrentUserDefaultName)
        )
        let partialFailure = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                recordID: CKError(.serverRecordChanged),
            ],
        ])

        #expect(MuesliICloudSyncEngine.isServerRecordChangedError(CKError(.serverRecordChanged)))
        #expect(MuesliICloudSyncEngine.isServerRecordChangedError(partialFailure))
        #expect(!MuesliICloudSyncEngine.isServerRecordChangedError(CKError(.networkUnavailable)))
    }

    @Test("unknown meeting source falls back to meeting")
    func unknownMeetingSourceFallsBackToMeeting() throws {
        let store = try makeStore()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO meetings (
            title, start_time, end_time, duration_seconds, raw_transcript,
            formatted_notes, word_count, source
        )
        VALUES ('Legacy', '2026-06-16T10:00:00Z', '2026-06-16T10:01:00Z', 60, 'Legacy text', '', 2, 'future_source')
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let meeting = try #require(try store.recentMeetings(limit: 1).first)
        #expect(meeting.source == .meeting)
    }

    @Test("sync origin badge labels cover iOS sources")
    func syncOriginBadgeLabels() {
        #expect(SyncOriginDisplay.badgeLabel(forDictationSource: "ios") == "iOS")
        #expect(SyncOriginDisplay.badgeLabel(forDictationSource: " iOS ") == "iOS")
        #expect(SyncOriginDisplay.badgeLabel(forDictationSource: "cua") == nil)
        #expect(SyncOriginDisplay.badgeLabel(forMeetingSource: .iOS) == "iOS")
        #expect(SyncOriginDisplay.badgeLabel(forMeetingSource: .audioImport) == nil)
        #expect(SyncOriginDisplay.badgeLabel(forMeetingSource: .meeting) == nil)
    }

    @Test("live meeting starts as recording with empty manual notes")
    func createLiveMeeting() throws {
        let store = try makeStore()
        let start = Date()

        let id = try store.createLiveMeeting(
            title: "Quick Note",
            calendarEventID: nil,
            startTime: start,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.title == "Quick Note")
        #expect(meeting.status == .recording)
        #expect(meeting.manualNotes == "")
        #expect(meeting.rawTranscript == "")
        #expect(meeting.formattedNotes == "")
        #expect(meeting.selectedTemplateID == "auto")
        #expect(meeting.source == .meeting)
    }

    @Test("manual notes update independently from final notes")
    func updateManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Quick Note", calendarEventID: nil, startTime: Date())

        try store.updateMeetingManualNotes(id: id, manualNotes: "- Decision: ship today")

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.manualNotes == "- Decision: ship today")
        #expect(meeting.formattedNotes == "")
    }

    @Test("manual notes update fails when the meeting row is missing")
    func updateManualNotesFailsWhenMeetingMissing() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.updateMeetingManualNotes(id: 9_999, manualNotes: "Lost note")
        }
    }

    @Test("status update fails when the meeting row is missing")
    func updateMeetingStatusFailsWhenMeetingMissing() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.updateMeetingStatus(id: 9_999, status: .failed)
        }
    }

    @Test("live meeting completes the same row")
    func completeLiveMeetingUpdatesExistingRow() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)
        try store.updateMeetingManualNotes(id: id, manualNotes: "- Keep this")

        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "hello world",
            formattedNotes: "## Summary\nHello\n\n## Manual Notes\n\n- Keep this",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meetings = try store.recentMeetings(limit: 10)
        #expect(meetings.count == 1)
        let completed = try #require(meetings.first)
        #expect(completed.id == id)
        #expect(completed.status == .completed)
        #expect(completed.title == "Generated Title")
        #expect(completed.rawTranscript == "hello world")
        #expect(completed.wordCount == 5)
        #expect(completed.manualNotes == "- Keep this")
    }

    @Test("live transcript checkpoints recover stale meetings as raw transcript fallback")
    func liveTranscriptCheckpointsRecoverStaleMeeting() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(
            title: "Crashed Meeting",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.updateMeetingManualNotes(id: id, manualNotes: "Remember this decision")

        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "10:00:01", speaker: "You", startSeconds: 1, endSeconds: 2, text: "We should ship today."),
            LiveTranscriptCheckpointEntry(timestampLabel: "10:00:03", speaker: "Others", startSeconds: 3, endSeconds: 4, text: "Agreed with the plan.")
        ])

        let recovered = try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id)

        #expect(recovered == true)
        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.notesState == .rawTranscriptFallback)
        #expect(meeting.rawTranscript.contains("[10:00:01] You: We should ship today."))
        #expect(meeting.rawTranscript.contains("[10:00:03] Others: Agreed with the plan."))
        #expect(meeting.formattedNotes.contains("Recovered from live transcript checkpoints"))
        #expect(meeting.wordCount == DictationStore.countWords(in: meeting.rawTranscript) + 3)
        #expect(meeting.durationSeconds == 4)
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
    }

    @Test("normal live meeting completion clears transcript checkpoints")
    func completeLiveMeetingClearsTranscriptCheckpoints() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "10:00:01", speaker: "You", startSeconds: 1, endSeconds: 2, text: "Temporary live text")
        ])

        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "final diarized transcript",
            formattedNotes: "## Summary\nFinal notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.rawTranscript == "final diarized transcript")
        #expect(meeting.notesState == .structuredNotes)
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id) == false)
    }

    @Test("note-only status updates word count from manual notes")
    func noteOnlyStatusCountsManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Manual Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Decision ship today")

        try store.updateMeetingStatus(id: id, status: .noteOnly)

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .noteOnly)
        #expect(meeting.wordCount == 3)
    }

    @Test("live meeting completion fails when the row disappeared")
    func completeLiveMeetingFailsWhenRowMissing() throws {
        let store = try makeStore()
        let start = Date()

        #expect(throws: Error.self) {
            try store.completeLiveMeeting(
                id: 9_999,
                title: "Generated Title",
                calendarEventID: nil,
                startTime: start,
                endTime: start.addingTimeInterval(120),
                rawTranscript: "hello world",
                formattedNotes: "## Summary\nHello",
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: nil,
                selectedTemplateID: "auto",
                selectedTemplateName: "Auto",
                selectedTemplateKind: .auto,
                selectedTemplatePrompt: "## Summary"
            )
        }
    }

    @Test("staleLiveMeetings returns only recording and processing rows")
    func staleLiveMeetingsFiltersLiveStatuses() throws {
        let store = try makeStore()
        let start = Date()

        let recordingID = try store.createLiveMeeting(title: "Recording", calendarEventID: nil, startTime: start)
        let processingID = try store.createLiveMeeting(title: "Processing", calendarEventID: nil, startTime: start.addingTimeInterval(1))
        let noteOnlyID = try store.createLiveMeeting(title: "Note Only", calendarEventID: nil, startTime: start.addingTimeInterval(2))
        try store.updateMeetingStatus(id: processingID, status: .processing)
        try store.updateMeetingStatus(id: noteOnlyID, status: .noteOnly)
        try store.insertMeeting(
            title: "Completed",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(3),
            endTime: start.addingTimeInterval(60),
            rawTranscript: "done",
            formattedNotes: "## Summary\nDone",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let stale = try store.staleLiveMeetings()

        #expect(stale.map(\.id) == [processingID, recordingID])
        #expect(stale.allSatisfy { $0.status == .recording || $0.status == .processing })
    }

    @Test("insert and retrieve dictation")
    func insertAndRetrieve() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertDictation(
            text: "Test dictation text here",
            durationSeconds: 3.5,
            startedAt: now.addingTimeInterval(-3.5),
            endedAt: now
        )

        let rows = try store.recentDictations(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first!.rawText == "Test dictation text here")
        #expect(rows.first!.wordCount == 4)
    }

    @Test("insert and retrieve meeting")
    func insertAndRetrieveMeeting() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Test Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(600),
            rawTranscript: "Speaker one said hello. Speaker two replied.",
            formattedNotes: "## Summary\nGood meeting",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first!.title == "Test Meeting")
        #expect(rows.first!.wordCount == 7)
        #expect(rows.first!.appliedTemplateID == MeetingTemplates.autoID)
    }

    @Test("meeting template snapshot persists on insert")
    func insertAndRetrieveMeetingTemplateSnapshot() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Template Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(300),
            rawTranscript: "Transcript body",
            formattedNotes: "## Summary\nStructured",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: "stand-up",
            selectedTemplateName: "Stand-Up",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Yesterday"
        )

        let meeting = try store.recentMeetings(limit: 1).first
        #expect(meeting?.selectedTemplateID == "stand-up")
        #expect(meeting?.selectedTemplateName == "Stand-Up")
        #expect(meeting?.selectedTemplateKind == .builtin)
        #expect(meeting?.selectedTemplatePrompt == "## Yesterday")
    }

    @Test("update meeting notes and title")
    func updateMeeting() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Some transcript",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        let meetingId = rows.first!.id

        try store.updateMeeting(id: meetingId, title: "Sprint Planning", formattedNotes: "## Summary\nPlanned the sprint")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Sprint Planning")
        #expect(updated.first!.formattedNotes == "## Summary\nPlanned the sprint")
    }

    @Test("update meeting notes only")
    func updateMeetingNotesOnly() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Original Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Old notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        try store.updateMeetingNotes(id: rows.first!.id, formattedNotes: "New notes")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Original Title") // title unchanged
        #expect(updated.first!.formattedNotes == "New notes")
    }

    @Test("update meeting summary stores template snapshot")
    func updateMeetingSummaryWithTemplateSnapshot() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Original Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Old notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.updateMeetingSummary(
            id: meetingID,
            title: "Standup",
            formattedNotes: "## Yesterday\n- Fixed bugs",
            selectedTemplateID: "stand-up",
            selectedTemplateName: "Stand-Up",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Yesterday"
        )

        let updated = try store.recentMeetings(limit: 1).first
        #expect(updated?.title == "Standup")
        #expect(updated?.selectedTemplateID == "stand-up")
        #expect(updated?.selectedTemplateName == "Stand-Up")
        #expect(updated?.selectedTemplateKind == .builtin)
        #expect(updated?.selectedTemplatePrompt == "## Yesterday")
    }

    @Test("update meeting transcript and summary replaces empty transcription")
    func updateMeetingTranscriptAndSummary() throws {
        let store = try makeStore()

        let start = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/recovered.wav"
        )
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "Manual note")
        try store.updateMeetingStatus(id: meetingID, status: .failed)

        try store.updateMeetingTranscriptAndSummary(
            id: meetingID,
            rawTranscript: "Recovered transcript words",
            formattedNotes: "## Summary\nRecovered notes",
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "Auto prompt"
        )

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.rawTranscript == "Recovered transcript words")
        #expect(updated.formattedNotes == "## Summary\nRecovered notes")
        #expect(updated.status == .completed)
        #expect(updated.wordCount == 5)
        #expect(updated.savedRecordingPath == "/tmp/recovered.wav")
        #expect(updated.manualNotes == "Manual note")
    }

    @Test("update meeting transcript preserves notes and refreshes word count")
    func updateMeetingTranscript() throws {
        let store = try makeStore()

        let start = Date()
        let meetingID = try store.insertMeeting(
            title: "Editable Transcript",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Original words",
            formattedNotes: "## Summary\nExisting notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "Manual note")

        try store.updateMeetingTranscript(
            id: meetingID,
            rawTranscript: "[10:00:00] You: Edited transcript words"
        )

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.rawTranscript == "[10:00:00] You: Edited transcript words")
        #expect(updated.formattedNotes == "## Summary\nExisting notes")
        #expect(updated.manualNotes == "Manual note")
        #expect(updated.wordCount == 7)
    }

    @Test("fetch dictation by id returns the full record")
    func fetchDictationByID() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertDictation(
            text: "Capture this dictation",
            durationSeconds: 4.2,
            appContext: "Slack",
            startedAt: now.addingTimeInterval(-4.2),
            endedAt: now
        )

        let inserted = try store.recentDictations(limit: 1).first!
        let fetched = try store.dictation(id: inserted.id)

        #expect(fetched?.id == inserted.id)
        #expect(fetched?.rawText == "Capture this dictation")
        #expect(fetched?.appContext == "Slack")
    }

    @Test("fetch meeting by id returns audio paths and notes state")
    func fetchMeetingByID() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Recorded Meeting",
            calendarEventID: "evt_123",
            startTime: now,
            endTime: now.addingTimeInterval(90),
            rawTranscript: "Discussed roadmap items",
            formattedNotes: "## Summary\nRoadmap reviewed",
            micAudioPath: "/tmp/mic.wav",
            systemAudioPath: "/tmp/system.wav",
            savedRecordingPath: "/tmp/meeting.wav"
        )

        let inserted = try store.recentMeetings(limit: 1).first!
        let fetched = try store.meeting(id: inserted.id)

        #expect(fetched?.id == inserted.id)
        #expect(fetched?.calendarEventID == "evt_123")
        #expect(fetched?.micAudioPath == "/tmp/mic.wav")
        #expect(fetched?.systemAudioPath == "/tmp/system.wav")
        #expect(fetched?.savedRecordingPath == "/tmp/meeting.wav")
        #expect(fetched?.notesState == .structuredNotes)
        #expect(fetched?.appliedTemplateID == MeetingTemplates.autoID)
    }

    @Test("meeting notes state distinguishes raw transcript fallback from structured notes")
    func meetingNotesState() throws {
        let missing = MeetingRecord(
            id: 1,
            title: "Missing",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let fallback = MeetingRecord(
            id: 2,
            title: "Fallback",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Raw Transcript\n\nHello world",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let structured = MeetingRecord(
            id: 3,
            title: "Structured",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Summary\nNext steps captured",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let structuredWithTranscriptSection = MeetingRecord(
            id: 4,
            title: "Structured With Transcript Section",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Summary\nNext steps captured\n\n## Raw Transcript\n\nQuoted transcript for reference",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )

        #expect(missing.notesState == .missing)
        #expect(fallback.notesState == .rawTranscriptFallback)
        #expect(structured.notesState == .structuredNotes)
        #expect(structuredWithTranscriptSection.notesState == .structuredNotes)
    }

    @Test("dictation stats aggregate correctly")
    func dictationStats() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertDictation(text: "one two three", durationSeconds: 2.0, startedAt: now.addingTimeInterval(-2), endedAt: now)
        try store.insertDictation(text: "four five", durationSeconds: 1.5, startedAt: now.addingTimeInterval(-1.5), endedAt: now)

        let stats = try store.dictationStats()
        #expect(stats.totalWords == 5)
        #expect(stats.totalSessions == 2)
        #expect(stats.averageWPM > 0)
    }

    @Test("dictation streaks ignore deleted records")
    func dictationStreaksIgnoreDeletedRecords() throws {
        let store = try makeStore()

        let firstDay = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        let deletedMiddleDay = firstDay.addingTimeInterval(86_400)
        let thirdDay = firstDay.addingTimeInterval(86_400 * 2)
        try store.insertDictation(
            text: "live first day",
            durationSeconds: 1,
            startedAt: firstDay.addingTimeInterval(-1),
            endedAt: firstDay
        )
        let deletedID = try store.insertDictation(
            text: "deleted middle day",
            durationSeconds: 1,
            startedAt: deletedMiddleDay.addingTimeInterval(-1),
            endedAt: deletedMiddleDay
        )
        try store.insertDictation(
            text: "live third day",
            durationSeconds: 1,
            startedAt: thirdDay.addingTimeInterval(-1),
            endedAt: thirdDay
        )

        try store.deleteDictation(id: deletedID)

        let stats = try store.dictationStats()
        #expect(stats.totalSessions == 2)
        #expect(stats.longestStreakDays == 1)
    }

    @Test("meeting stats aggregate correctly")
    func meetingStats() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Stats Meeting", calendarEventID: nil,
            startTime: start, endTime: start.addingTimeInterval(300),
            rawTranscript: "This is a test transcript with several words",
            formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let liveID = try store.createLiveMeeting(
            title: "Live Draft",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(60)
        )
        let noteOnlyID = try store.createLiveMeeting(
            title: "Written Notes",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(120)
        )
        try store.updateMeetingManualNotes(id: noteOnlyID, manualNotes: "manual note words")
        try store.updateMeetingStatus(id: noteOnlyID, status: .noteOnly)
        try store.updateMeetingStatus(id: liveID, status: .failed)

        let stats = try store.meetingStats()
        #expect(stats.totalMeetings == 2)
        #expect(stats.totalWords == 11)
    }

    @Test("clear dictations removes all records")
    func clearDictations() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(text: "to delete", durationSeconds: 1.0, startedAt: now, endedAt: now)
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done",
            events: [ComputerUseTraceEvent(kind: "finish", title: "Final output", body: "Done")]
        )
        try store.clearDictations()
        #expect(try store.recentDictations(limit: 100).isEmpty)
        #expect(throws: Error.self) {
            try store.insertComputerUseTrace(
                dictationID: dictationID,
                finalStatus: "done",
                finalMessage: "Should fail",
                events: []
            )
        }
    }

    @Test("clear meetings removes all records")
    func clearMeetings() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertMeeting(title: "Del", calendarEventID: nil, startTime: now, endTime: now.addingTimeInterval(60), rawTranscript: "x", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        try store.clearMeetings()
        #expect(try store.recentMeetings(limit: 100).isEmpty)
    }

    @Test("delete meeting removes a single meeting row")
    func deleteMeeting() throws {
        let store = try makeStore()
        let now = Date()

        try store.insertMeeting(
            title: "Delete Me",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "first meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.insertMeeting(
            title: "Keep Me",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "second meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetings = try store.recentMeetings(limit: 10)
        let deleteID = meetings.first(where: { $0.title == "Delete Me" })!.id
        try store.deleteMeeting(id: deleteID)

        let remaining = try store.recentMeetings(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == "Keep Me")
    }

    @Test("delete meeting removes live transcript checkpoints")
    func deleteMeetingRemovesLiveTranscriptCheckpoints() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertMeeting(
            title: "Delete Checkpoints",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let meetingID = try #require(try store.recentMeetings(limit: 1).first?.id)
        try store.appendLiveTranscriptCheckpoints(meetingID: meetingID, entries: [
            LiveTranscriptCheckpointEntry(
                timestampLabel: "10:00:01",
                speaker: "You",
                startSeconds: 1,
                endSeconds: 2,
                text: "Temporary checkpoint"
            )
        ])
        #expect(try store.liveTranscriptCheckpointText(meetingID: meetingID) != nil)

        try store.deleteMeeting(id: meetingID)

        #expect(try store.liveTranscriptCheckpointText(meetingID: meetingID) == nil)
    }

    @Test("recent dictations respects limit")
    func limitRespected() throws {
        let store = try makeStore()
        let now = Date()
        for i in 0..<5 {
            try store.insertDictation(text: "Entry \(i)", durationSeconds: 1.0, startedAt: now.addingTimeInterval(Double(i)), endedAt: now.addingTimeInterval(Double(i) + 1))
        }
        #expect(try store.recentDictations(limit: 3).count == 3)
    }

    @Test("recent dictations sort by recorded timestamp instead of insert order")
    func recentDictationsSortByRecordedTimestamp() throws {
        let store = try makeStore()
        let newer = Date(timeIntervalSince1970: 1_770_100_000)
        let older = Date(timeIntervalSince1970: 1_770_000_000)

        _ = try store.insertDictation(
            text: "Newer Mac row",
            durationSeconds: 1,
            startedAt: newer.addingTimeInterval(-1),
            endedAt: newer
        )
        try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "dictation-ios-older",
            kind: .dictation,
            text: "Older iOS row",
            source: "ios",
            createdAt: older,
            updatedAt: Date(timeIntervalSince1970: 1_770_200_000),
            startedAt: older.addingTimeInterval(-1),
            endedAt: older,
            durationSeconds: 1,
            wordCount: 3,
            cloudChangeTag: "tag-older"
        ))

        let rows = try store.recentDictations(limit: 2)

        #expect(rows.map(\.rawText) == ["Newer Mac row", "Older iOS row"])
    }

    @Test("recent dictations treats fromDate as a bound value, not SQL")
    func recentDictationsBindsFromDate() throws {
        let store = try makeStore()
        let now = Date()

        try store.insertDictation(
            text: "Older entry",
            durationSeconds: 1.0,
            startedAt: now.addingTimeInterval(-120),
            endedAt: now.addingTimeInterval(-120)
        )
        try store.insertDictation(
            text: "Newer entry",
            durationSeconds: 1.0,
            startedAt: now,
            endedAt: now
        )

        let injectedDate = "9999-12-31T00:00:00Z' OR 1=1 --"
        let rows = try store.recentDictations(limit: 10, fromDate: injectedDate)

        #expect(rows.isEmpty)
    }

    // MARK: - Editable Meeting Title

    @Test("update meeting title only preserves notes")
    func updateMeetingTitleOnly() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Auto Title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes\nKeep these",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        try store.updateMeetingTitle(id: rows.first!.id, title: "Edited Title")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Edited Title")
        #expect(updated.first!.formattedNotes == "## Notes\nKeep these") // notes unchanged
    }

    @Test("update meeting saved recording path stores the retained file location")
    func updateMeetingSavedRecordingPath() throws {
        let store = try makeStore()

        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Auto Title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes\nKeep these",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        try store.updateMeetingSavedRecordingPath(id: meetingID, path: "/tmp/retained.wav")

        let updated = try store.meeting(id: meetingID)
        #expect(updated?.savedRecordingPath == "/tmp/retained.wav")
    }

    // MARK: - Folder CRUD

    @Test("create and list folders")
    func createAndListFolders() throws {
        let store = try makeStore()

        let id1 = try store.createFolder(name: "Engineering")
        let id2 = try store.createFolder(name: "Customer Calls")

        let folders = try store.listFolders()
        #expect(folders.count == 2)
        #expect(folders.contains(where: { $0.id == id1 && $0.name == "Engineering" }))
        #expect(folders.contains(where: { $0.id == id2 && $0.name == "Customer Calls" }))
    }

    @Test("rename folder")
    func renameFolder() throws {
        let store = try makeStore()

        let id = try store.createFolder(name: "Old Name")
        try store.renameFolder(id: id, name: "New Name")

        let folders = try store.listFolders()
        let folder = folders.first(where: { $0.id == id })
        #expect(folder?.name == "New Name")
    }

    @Test("delete folder removes it from list")
    func deleteFolderRemovesIt() throws {
        let store = try makeStore()

        let id = try store.createFolder(name: "To Delete")
        #expect(try store.listFolders().contains(where: { $0.id == id }))

        try store.deleteFolder(id: id)
        let remaining = try store.listFolders()
        #expect(!remaining.contains(where: { $0.id == id }))
    }

    // MARK: - Move Meeting to Folder

    @Test("move meeting to folder sets folderID")
    func moveMeetingToFolder() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Standup",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Daily standup",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let folderID = try store.createFolder(name: "Team")
        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil) // starts unfiled

        try store.moveMeeting(id: meeting.id, toFolder: folderID)

        let updated = try store.recentMeetings(limit: 1).first!
        #expect(updated.folderID == folderID)
    }

    @Test("move meeting to nil unfiles it")
    func moveMeetingToUnfiled() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Filed Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "words",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let folderID = try store.createFolder(name: "Temp")
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.moveMeeting(id: meetingID, toFolder: folderID)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == folderID)

        try store.moveMeeting(id: meetingID, toFolder: nil)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == nil)
    }

    @Test("delete folder moves its meetings to unfiled")
    func deleteFolderUnfilesMeetings() throws {
        let store = try makeStore()

        let now = Date()
        let folderID = try store.createFolder(name: "Doomed Folder")

        try store.insertMeeting(
            title: "Meeting A",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "a",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.moveMeeting(id: meetingID, toFolder: folderID)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == folderID)

        try store.deleteFolder(id: folderID)

        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil) // moved to unfiled
        #expect(meeting.title == "Meeting A") // meeting still exists
    }

    @Test("new meetings have nil folderID by default")
    func newMeetingsUnfiled() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Unfiled Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "test",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil)
    }

    // MARK: - Search Tests

    @Test("searchDictations returns matching records by raw_text")
    func searchDictationsMatches() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertDictation(text: "Hello world from muesli", durationSeconds: 2, startedAt: now, endedAt: now)
        try store.insertDictation(text: "Goodbye everyone", durationSeconds: 1, startedAt: now, endedAt: now)

        let results = try store.searchDictations(query: "muesli")
        #expect(results.count == 1)
        #expect(results.first!.rawText.contains("muesli"))
    }

    @Test("computer use dictation rows hydrate persisted trace")
    func computerUseTraceHydrates() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "open Google Chrome",
            durationSeconds: 1.2,
            source: "cua",
            startedAt: now.addingTimeInterval(-1.2),
            endedAt: now
        )
        let events = [
            ComputerUseTraceEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                kind: "model_output",
                title: "Model output",
                body: #"{"tool":"open_app","app_name":"Google Chrome"}"#,
                status: "planned",
                step: 1,
                timestamp: "2026-05-05T00:00:00Z"
            ),
            ComputerUseTraceEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                kind: "finish",
                title: "Final output",
                body: "Done: open Google Chrome",
                status: "done",
                step: 1,
                timestamp: "2026-05-05T00:00:01Z"
            ),
        ]

        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done: open Google Chrome",
            events: events
        )

        let row = try #require(store.recentDictations(limit: 1).first)
        #expect(row.id == dictationID)
        #expect(row.source == "cua")
        #expect(row.computerUseTrace?.finalStatus == "done")
        #expect(row.computerUseTrace?.events == events)
    }

    @Test("searchDictations matches computer use trace text")
    func searchDictationsMatchesComputerUseTrace() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "do the browser thing",
            durationSeconds: 1.0,
            source: "cua",
            startedAt: now,
            endedAt: now
        )
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done: opened Google Chrome",
            events: [
                ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Opened Google Chrome")
            ]
        )

        let results = try store.searchDictations(query: "Chrome")

        #expect(results.map(\.id).contains(dictationID))
        #expect(results.first(where: { $0.id == dictationID })?.computerUseTrace?.finalStatus == "done")
    }

    @Test("insertComputerUseTrace replaces existing trace atomically")
    func insertComputerUseTraceReplacesExistingTrace() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "open chrome",
            durationSeconds: 1.0,
            source: "cua",
            startedAt: now,
            endedAt: now
        )

        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "failed",
            finalMessage: "Old",
            events: [ComputerUseTraceEvent(kind: "failed", title: "Failed", body: "Old")]
        )
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "New",
            events: [ComputerUseTraceEvent(kind: "finish", title: "Final output", body: "New")]
        )

        let row = try #require(try store.dictation(id: dictationID))
        #expect(row.computerUseTrace?.finalStatus == "done")
        #expect(row.computerUseTrace?.finalMessage == "New")
        #expect(row.computerUseTrace?.events.map(\.body) == ["New"])
    }

    @Test("deleteDictation removes computer use trace")
    func deleteDictationRemovesComputerUseTrace() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "switch to Chrome",
            durationSeconds: 1.0,
            source: "cua",
            startedAt: now,
            endedAt: now
        )
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done",
            events: [ComputerUseTraceEvent(kind: "finish", title: "Final output", body: "Done")]
        )

        try store.deleteDictation(id: dictationID)

        #expect(try store.dictation(id: dictationID) == nil)
        #expect(try store.searchDictations(query: "Final output").isEmpty)
    }

    @Test("deleteDictation fails when row is missing")
    func deleteDictationFailsWhenRowMissing() throws {
        let store = try makeStore()
        #expect(throws: DictationStoreError.self) {
            try store.deleteDictation(id: 99_999)
        }
    }

    @Test("searchDictations returns empty for non-matching query")
    func searchDictationsNoMatch() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertDictation(text: "Hello world", durationSeconds: 2, startedAt: now, endedAt: now)

        let results = try store.searchDictations(query: "xyznonexistent")
        #expect(results.isEmpty)
    }

    @Test("searchMeetings matches across title, transcript, and notes")
    func searchMeetingsMultiField() throws {
        let store = try makeStore()
        let start = Date()
        try store.insertMeeting(
            title: "Sprint Planning",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(600),
            rawTranscript: "We discussed the backlog items",
            formattedNotes: "## Notes\nPrioritized features",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.insertMeeting(
            title: "Design Review",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(300),
            rawTranscript: "Reviewed the mockups",
            formattedNotes: "## Notes\nApproved designs",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let byTitle = try store.searchMeetings(query: "Sprint")
        #expect(byTitle.count == 1)
        #expect(byTitle.first!.title == "Sprint Planning")

        let byTranscript = try store.searchMeetings(query: "backlog")
        #expect(byTranscript.count == 1)

        let byNotes = try store.searchMeetings(query: "Prioritized")
        #expect(byNotes.count == 1)
    }

    @Test("searchMeetings matches manual notes")
    func searchMeetingsManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Quick Note", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Escalate renewal risk")

        let results = try store.searchMeetings(query: "renewal")

        #expect(results.map(\.id).contains(id))
    }

    @Test("search is case-insensitive for ASCII")
    func searchCaseInsensitive() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertDictation(text: "Meeting with Alice", durationSeconds: 2, startedAt: now, endedAt: now)

        let upper = try store.searchDictations(query: "ALICE")
        let lower = try store.searchDictations(query: "alice")
        let mixed = try store.searchDictations(query: "Alice")

        #expect(upper.count == 1)
        #expect(lower.count == 1)
        #expect(mixed.count == 1)
    }
}
