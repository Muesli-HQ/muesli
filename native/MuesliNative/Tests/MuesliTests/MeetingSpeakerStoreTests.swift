import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Guarded meeting speaker storage")
struct MeetingSpeakerStoreTests {
    @Test func renameRoundtripAndStaleWriter() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var renamed = snapshot.state
        _ = renamed.assign(.init(name: "長い名前: Example", provenance: .manual), to: state.speakers[0].key)
        #expect(try store.updateMeetingSpeakerState(id: id, state: renamed, expected: snapshot) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript == "[00:00:01] 長い名前: Example: Original words")
        #expect(try store.meetingSpeakerSnapshot(id: id)?.summaryIsStale == true)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .conflict)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.turns == state.turns)
    }

    @Test func changedTextEditInvalidatesAuthority() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingTranscript(id: id, rawTranscript: "Changed words")

        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .conflict)
        #expect(try store.meeting(id: id)?.rawTranscript == "Changed words")
    }

    @Test func sameValueTranscriptWriteRetainsAuthority() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingTranscript(id: id, rawTranscript: state.render())

        let retainedVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(retainedVersion == version)
        let retained = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(retained.state == snapshot.state)
        #expect(retained.version == snapshot.version)
        #expect(retained.summaryIsStale == snapshot.summaryIsStale)
        #expect(try store.updateMeetingSpeakerState(id: id, state: snapshot.state, expected: snapshot) == .updated)
    }

    @Test func sqlCloudLikeEditCannotBeUndoneByStaleEpoch() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE meetings SET raw_transcript = 'User words'", nil, nil, nil) == SQLITE_OK)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
        #expect(try store.meeting(id: id)?.rawTranscript == "User words")
    }

    @Test func failedSummaryRegenerationDoesNotClaimCurrentNotes() throws {
        let (store, id, _) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscriptAndSummary(id: id, rawTranscript: "New speech", formattedNotes: "Retained notes",
            selectedTemplateID: "test", selectedTemplateName: "Test", selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "", expectedTranscript: before, summaryIsCurrent: false)
        #expect(try store.meetingSummaryIsStale(id: id))
    }

    @Test func meetingRecordTracksSummaryFreshness() throws {
        let (store, id, _) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))

        #expect(try store.meeting(id: id)?.summaryIsStale == false)
        try store.markMeetingSummaryStale(id: id, expected: version)
        #expect(try store.meeting(id: id)?.summaryIsStale == true)
        try store.markMeetingSummaryCurrent(id: id, expected: version)
        #expect(try store.meeting(id: id)?.summaryIsStale == false)
    }

    @Test func failedInitialSummaryCreatesFreshnessRowForNewMeeting() throws {
        let (store, id, _) = try fixture()
        let initial = try #require(try store.meetingTranscriptVersion(id: id))

        try store.setMeetingSummaryFreshness(id: id, expected: initial, isCurrent: false)

        #expect(try store.meetingSummaryIsStale(id: id))
        let current = try #require(try store.meetingTranscriptVersion(id: id))
        try store.setMeetingSummaryFreshness(id: id, expected: current, isCurrent: true)
        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func processingInvalidatesPriorIdentityBeforeNewInference() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: before) == .updated)
        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meetingTranscriptVersion(id: id)?.generation != before.generation)
    }

    @Test func failedProcessingCanRestoreSpeakerHistoryWhenTranscriptIsUnchanged() throws {
        let (store, id, state) = try fixture()
        let initialVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: initialVersion) == .updated)
        let initialSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var namedState = initialSnapshot.state
        #expect(namedState.assign(.init(name: "Alice", provenance: .manual), to: state.speakers[0].key))
        #expect(try store.updateMeetingSpeakerState(id: id, state: namedState, expected: initialSnapshot) == .updated)
        let savedSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        try store.updateMeetingStatus(id: id, status: .completed)
        let restoredVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(restoredVersion.digest == savedSnapshot.version.digest)
        #expect(restoredVersion.generation != savedSnapshot.version.generation)

        #expect(try store.restoreMeetingSpeakerState(id: id, snapshot: savedSnapshot, expected: restoredVersion) == .updated)
        let restored = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(restored.state == savedSnapshot.state)
        #expect(restored.state.speakers[0].assignment?.name == "Alice")
        #expect(restored.summaryIsStale == savedSnapshot.summaryIsStale)
    }

    @Test func failedProcessingCannotRestoreSpeakerHistoryAfterTranscriptChanges() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let savedSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)
        try store.updateMeetingTranscript(id: id, rawTranscript: "Changed by another edit")
        try store.updateMeetingStatus(id: id, status: .completed)
        let currentVersion = try #require(try store.meetingTranscriptVersion(id: id))

        #expect(try store.restoreMeetingSpeakerState(id: id, snapshot: savedSnapshot, expected: currentVersion) == .invalidated)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meeting(id: id)?.rawTranscript == "Changed by another edit")
    }

    @Test func deletingMeetingScrubsLocalSpeakerState() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 1)

        try store.deleteMeeting(id: id)

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func clearingMeetingsScrubsLocalSpeakerState() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        try store.clearMeetings()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func syncedMeetingDeletionScrubsLocalSpeakerState() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let synced = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        let deletionTime = synced.updatedAt.addingTimeInterval(60)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: synced.id,
            kind: .meeting,
            text: "",
            createdAt: synced.createdAt,
            updatedAt: deletionTime,
            durationSeconds: 0,
            wordCount: 0,
            isDeleted: true
        )))

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func migrationScrubsSpeakerStateFromEarlierSoftDeletedMeetings() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 1)

        do {
            var db: OpaquePointer?
            guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
                throw NSError(domain: "MeetingSpeakerStoreTests", code: 4)
            }
            defer { sqlite3_close(db) }
            let sql = "DROP TRIGGER local_meeting_speaker_deleted; UPDATE meetings SET raw_transcript = '', deleted_at = 1 WHERE id = \(id)"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }

        try store.migrateIfNeeded()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func onlyMatchingSummaryGenerationCanClearStaleness() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscript(id: id, rawTranscript: "New speech")
        try store.markMeetingSummaryCurrent(id: id, expected: before)
        #expect(try store.meetingSummaryIsStale(id: id))
        let current = try #require(try store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: current)
        #expect(try !store.meetingSummaryIsStale(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: current) == .invalidated)
    }

    @Test func legacyAndResumeStayUnavailable() throws {
        let (store, id, state) = try fixture()
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        _ = try store.prepareMeetingForResume(id: id)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
    }

    @Test func deletingMeetingRemovesPersistedSpeakerJSON() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        try store.deleteMeeting(id: id)

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func clearingMeetingsRemovesPersistedSpeakerJSON() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        try store.clearMeetings()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func syncedMeetingTombstoneRemovesPersistedSpeakerJSON() throws {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("synced-speakers-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "remote")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Synced words")])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recordName = "meeting-speaker-state-delete"
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Synced fixture", text: state.render(),
            speakerTranscript: state.render(), summaryText: "Summary", source: "mac", localSource: "meeting",
            meetingStatus: .completed, createdAt: createdAt, updatedAt: createdAt,
            startedAt: createdAt, endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))
        let id = try #require(try store.recentMeetings(limit: 10).first(where: { $0.title == "Synced fixture" })?.id)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Deleted Meeting", text: "", speakerTranscript: "",
            source: "mac", localSource: "meeting", meetingStatus: .completed,
            createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(1),
            startedAt: createdAt, endedAt: createdAt.addingTimeInterval(2), durationSeconds: 0,
            wordCount: 0, isDeleted: true
        )))

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func titleOnlySyncUpdatePreservesSpeakerState() throws {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("synced-speakers-title-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "remote")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Synced words")])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recordName = "meeting-speaker-title-update"
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Original title", text: state.render(),
            speakerTranscript: state.render(), summaryText: "Current summary", summaryIsCurrent: true,
            source: "mac", localSource: "meeting", meetingStatus: .completed,
            createdAt: createdAt, updatedAt: createdAt, startedAt: createdAt,
            endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))
        let id = try #require(try store.recentMeetings(limit: 10).first(where: { $0.title == "Original title" })?.id)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Renamed title", text: state.render(),
            speakerTranscript: state.render(), summaryText: "Current summary", summaryIsCurrent: true,
            source: "mac", localSource: "meeting", meetingStatus: .completed,
            createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(1),
            startedAt: createdAt, endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))

        #expect(try store.meetingSpeakerSnapshot(id: id)?.state == state)
        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func freshSyncedSummaryClearsStalenessForIncomingTranscript() throws {
        let (store, id, _) = try fixture()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Incoming transcript")
        #expect(try store.meetingSummaryIsStale(id: id))

        let recordName = try #require(try store.textRecordsNeedingSync().first?.id)
        let createdAt = Date()
        let updatedAt = createdAt.addingTimeInterval(60)
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting,
            title: "Fixture", text: "Incoming transcript", summaryText: "Fresh summary",
            summaryIsCurrent: true, source: "mac", localSource: "meeting",
            meetingStatus: .completed, createdAt: createdAt,
            updatedAt: updatedAt, startedAt: createdAt,
            endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))

        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func syncSnapshotExportsSummaryFreshnessForItsTranscript() throws {
        let (store, id, _) = try fixture()
        let recordName = try #require(try store.textRecordsNeedingSync().first?.id)

        try store.updateMeetingTranscript(id: id, rawTranscript: "Edited transcript")
        let stale = try #require(try store.textRecordsNeedingSync().first { $0.id == recordName })
        #expect(stale.summaryIsCurrent == false)

        let version = try #require(try store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: version)
        let current = try #require(try store.textRecordsNeedingSync().first { $0.id == recordName })
        #expect(current.summaryIsCurrent == true)
    }

    @Test func legacySyncWithChangedSummaryKeepsStaleness() throws {
        let (store, id, _) = try fixture()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Edited transcript")
        #expect(try store.meetingSummaryIsStale(id: id))

        var incoming = try #require(try store.textRecordsNeedingSync().first)
        incoming.summaryText = "Regenerated summary"
        incoming.summaryIsCurrent = nil
        incoming.updatedAt = Date().addingTimeInterval(60)
        #expect(try store.upsertSyncedTextRecord(incoming))

        #expect(try store.meetingSummaryIsStale(id: id))
    }

    private func fixture() throws -> (DictationStore, Int64, MeetingSpeakerState) {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let actual = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "a")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: actual, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: actual, timestamp: "00:00:01", start: 1, end: 2, text: "Original words")])
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                        rawTranscript: state.render(), formattedNotes: "Summary", micAudioPath: nil, systemAudioPath: nil)
        return (store, id, state)
    }

    private func rawSpeakerStateCount(meetingID: Int64, store: DictationStore) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.resolvedDatabaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT COUNT(*) FROM local_meeting_speaker_state WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 3)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
