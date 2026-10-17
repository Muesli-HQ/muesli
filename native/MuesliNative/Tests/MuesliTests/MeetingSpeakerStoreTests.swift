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

    @Test func processingInvalidatesPriorIdentityBeforeNewInference() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: before) == .updated)
        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meetingTranscriptVersion(id: id)?.generation != before.generation)
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
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 1)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM local_meeting_speaker_state WHERE meeting_id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 3)
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}
