import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Meeting participants", .serialized)
struct MeetingParticipantStoreTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-participants-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeMeeting(in store: DictationStore, title: String = "Participants") throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        return try store.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    private func makePreParticipantStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-pre-participants-\(UUID().uuidString).db")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError("failed to open pre-participant database")
        }
        defer { sqlite3_close(database) }

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
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError("failed to create pre-participant meeting schema")
        }
        return DictationStore(databaseURL: url)
    }

    private func makeStepFaultStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-participant-step-fault-\(UUID().uuidString).db")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError("failed to open step-fault database")
        }
        defer { sqlite3_close(database) }

        // Adding the generated column after insertion lets one row succeed before
        // the next row faults, without relying on a timing-sensitive lock race.
        let sql = """
        CREATE TABLE meeting_participants (
            meeting_id INTEGER NOT NULL,
            contact_identifier TEXT NOT NULL,
            source_value INTEGER NOT NULL,
            insertion_order INTEGER NOT NULL
        );
        INSERT INTO meeting_participants
            (meeting_id, contact_identifier, source_value, insertion_order)
        VALUES
            (42, 'first', 1, 0),
            (42, 'fault', -9223372036854775808, 1);
        ALTER TABLE meeting_participants
            ADD COLUMN display_name TEXT GENERATED ALWAYS AS (abs(source_value)) VIRTUAL;
        CREATE INDEX idx_meeting_participants_order
            ON meeting_participants(meeting_id, insertion_order, contact_identifier);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError("failed to create step-fault participant schema")
        }
        return DictationStore(databaseURL: url)
    }

    /// Inserts a meeting row using only the pre-participant column set, so the row
    /// looks exactly like one already sitting in a shipped user database.
    private func insertLegacyMeeting(into store: DictationStore, title: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &database) == SQLITE_OK else {
            throw sqliteError("failed to reopen pre-participant database")
        }
        defer { sqlite3_close(database) }

        let sql = """
        INSERT INTO meetings (title, start_time, raw_transcript, formatted_notes)
        VALUES (?, '2026-01-01T00:00:00Z', 'legacy transcript', 'legacy notes')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError("failed to prepare legacy meeting insert")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError("failed to insert legacy meeting")
        }
        return sqlite3_last_insert_rowid(database)
    }

    private func sqliteError(_ message: String) -> NSError {
        NSError(
            domain: "MeetingParticipantStoreTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    @Test("participant migration upgrades an existing database idempotently")
    func migrationIsIdempotent() throws {
        let store = try makePreParticipantStore()

        try store.migrateIfNeeded()
        try store.migrateIfNeeded()

        var database: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'meeting_participants'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(meeting_participants)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        // Sort by the pk ordinal rather than relying on declaration order, otherwise
        // PRIMARY KEY (contact_identifier, meeting_id) would produce the same array.
        var primaryKeyColumns: [(ordinal: Int32, name: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let ordinal = sqlite3_column_int(statement, 5)
            if ordinal > 0, let name = sqlite3_column_text(statement, 1) {
                primaryKeyColumns.append((ordinal, String(cString: name)))
            }
        }
        #expect(primaryKeyColumns.sorted { $0.ordinal < $1.ordinal }.map(\.name) == [
            "meeting_id",
            "contact_identifier",
        ])
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "PRAGMA foreign_key_list(meeting_participants)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        var cascadesToMeetings = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let table = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
            let onDelete = sqlite3_column_text(statement, 6).map(String.init(cString:)) ?? ""
            if table == "meetings", onDelete == "CASCADE" {
                cascadesToMeetings = true
            }
        }
        #expect(cascadesToMeetings)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_meeting_participants_order'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)
    }

    @Test("a migrated database keeps its meetings and accepts participants")
    func migrationPreservesDataAndEnablesParticipants() throws {
        let store = try makePreParticipantStore()
        let legacyID = try insertLegacyMeeting(into: store, title: "Legacy Standup")

        try store.migrateIfNeeded()

        // The pre-existing row survives the migration intact.
        let migrated = try store.meeting(id: legacyID)
        #expect(migrated?.title == "Legacy Standup")
        #expect(migrated?.rawTranscript == "legacy transcript")

        // And the upgraded database actually works, rather than merely having the
        // right shape. This exercises columns added by ALTER TABLE during migration
        // (notably meetings.deleted_at, which attachMeetingParticipant depends on).
        #expect(try store.attachMeetingParticipant(
            meetingID: legacyID,
            contactIdentifier: "legacy-contact",
            displayName: "Legacy Person"
        ))
        #expect(try store.listMeetingParticipants(meetingID: legacyID).map(\.displayName) == ["Legacy Person"])
    }

    @Test("participant listing throws instead of returning rows before a step fault")
    func participantListingThrowsOnStepFault() throws {
        let store = try makeStepFaultStore()

        do {
            let participants = try store.listMeetingParticipants(meetingID: 42)
            Issue.record("Expected a SQLite step fault, got \(participants.count) participants")
        } catch {
            let error = error as NSError
            #expect(error.domain == DictationStore.errorDomain)
            #expect(error.code == Int(SQLITE_ERROR))
        }
    }

    @Test("participants attach, list, and remove in insertion order")
    func attachListAndRemove() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        #expect(try store.attachMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "contact-b",
            displayName: "Bob Example"
        ))
        #expect(try store.attachMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "contact-a",
            displayName: "Alice Example"
        ))

        #expect(try store.listMeetingParticipants(meetingID: meetingID) == [
            MeetingParticipant(
                meetingID: meetingID,
                contactIdentifier: "contact-b",
                displayName: "Bob Example",
                insertionOrder: 0
            ),
            MeetingParticipant(
                meetingID: meetingID,
                contactIdentifier: "contact-a",
                displayName: "Alice Example",
                insertionOrder: 1
            ),
        ])

        try store.removeMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "contact-b"
        )

        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.contactIdentifier) == [
            "contact-a",
        ])
    }

    @Test("attaching the same contact twice deduplicates but refreshes the name")
    func duplicateSelectionRefreshesDisplayName() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        #expect(try store.attachMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "same-contact",
            displayName: "Original Snapshot"
        ))
        // Returns false because no new participant was added, but the stored snapshot
        // is refreshed so a contact renamed in Contacts.app has a recovery path.
        #expect(try !store.attachMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "same-contact",
            displayName: "Changed Snapshot"
        ))

        let participants = try store.listMeetingParticipants(meetingID: meetingID)
        #expect(participants.count == 1)
        #expect(participants.first?.displayName == "Changed Snapshot")
        #expect(participants.first?.insertionOrder == 0)
    }

    @Test("re-adding does not reshuffle existing participants")
    func refreshPreservesOrdering() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "first", displayName: "First"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "second", displayName: "Second"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "first", displayName: "First Renamed"
        )

        let participants = try store.listMeetingParticipants(meetingID: meetingID)
        #expect(participants.map(\.contactIdentifier) == ["first", "second"])
        #expect(participants.map(\.displayName) == ["First Renamed", "Second"])
        #expect(participants.map(\.insertionOrder) == [0, 1])
    }

    @Test("participants are scoped to their own meeting")
    func participantsAreScopedPerMeeting() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store, title: "First")
        let second = try makeMeeting(in: store, title: "Second")

        _ = try store.attachMeetingParticipant(
            meetingID: first, contactIdentifier: "shared", displayName: "Shared Person"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: second, contactIdentifier: "shared", displayName: "Shared Person"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: second, contactIdentifier: "second-only", displayName: "Second Only"
        )

        // Insertion order restarts per meeting rather than running globally.
        #expect(try store.listMeetingParticipants(meetingID: first).map(\.insertionOrder) == [0])
        #expect(try store.listMeetingParticipants(meetingID: second).map(\.insertionOrder) == [0, 1])

        // Removing from one meeting must not touch the other.
        try store.removeMeetingParticipant(meetingID: first, contactIdentifier: "shared")
        #expect(try store.listMeetingParticipants(meetingID: first).isEmpty)
        #expect(try store.listMeetingParticipants(meetingID: second).map(\.contactIdentifier) == [
            "shared",
            "second-only",
        ])

        // Nor may deleting one meeting wipe another meeting's participants.
        try store.deleteMeeting(id: first)
        #expect(try store.listMeetingParticipants(meetingID: second).count == 2)
    }

    @Test("re-adding a removed participant appends to the end")
    func reAddedParticipantGoesLast() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "a", displayName: "A"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "b", displayName: "B"
        )
        try store.removeMeetingParticipant(meetingID: meetingID, contactIdentifier: "a")
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "a", displayName: "A"
        )

        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.contactIdentifier) == ["b", "a"])

        // Emptying the meeting resets numbering rather than leaving a permanent gap.
        try store.removeMeetingParticipant(meetingID: meetingID, contactIdentifier: "a")
        try store.removeMeetingParticipant(meetingID: meetingID, contactIdentifier: "b")
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "c", displayName: "C"
        )
        #expect(try store.listMeetingParticipants(meetingID: meetingID).first?.insertionOrder == 0)
    }

    @Test("blank contact identifiers are rejected")
    func blankIdentifierIsRejected() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        #expect(throws: DictationStoreError.self) {
            try store.attachMeetingParticipant(
                meetingID: meetingID, contactIdentifier: "   ", displayName: "Blank"
            )
        }
        #expect(try store.listMeetingParticipants(meetingID: meetingID).isEmpty)
    }

    @Test("display names round-trip unusual text")
    func displayNamesRoundTrip() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        let longName = String(repeating: "é", count: 2_000)

        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "emoji", displayName: "Alice 🧮 Example-Sample"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "long", displayName: longName
        )
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "empty", displayName: ""
        )

        let names = try store.listMeetingParticipants(meetingID: meetingID).map(\.displayName)
        #expect(names == ["Alice 🧮 Example-Sample", longName, ""])
    }

    @Test("removing a contact that was never attached is a no-op")
    func removingUnattachedContactIsNoOp() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID, contactIdentifier: "kept", displayName: "Kept"
        )

        try store.removeMeetingParticipant(meetingID: meetingID, contactIdentifier: "never-attached")

        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.contactIdentifier) == ["kept"])
    }

    @Test("deleting a meeting removes its participant associations")
    func deletionRemovesParticipants() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "delete-contact",
            displayName: "Delete Me"
        )

        try store.deleteMeeting(id: meetingID)

        #expect(try store.listMeetingParticipants(meetingID: meetingID).isEmpty)
        #expect(throws: DictationStoreError.self) {
            try store.attachMeetingParticipant(
                meetingID: meetingID,
                contactIdentifier: "late-contact",
                displayName: "Too Late"
            )
        }
    }

    @Test("physically deleting a meeting cascades to participants")
    func physicalDeletionCascades() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        _ = try store.attachMeetingParticipant(
            meetingID: meetingID,
            contactIdentifier: "cascade-contact",
            displayName: "Cascade"
        )

        var database: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK)

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            database,
            "DELETE FROM meetings WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        sqlite3_bind_int64(statement, 1, meetingID)
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)

        #expect(try store.listMeetingParticipants(meetingID: meetingID).isEmpty)
    }

    @Test("clearing meetings removes all participant associations")
    func clearingRemovesParticipants() throws {
        let store = try makeStore()
        let firstID = try makeMeeting(in: store, title: "First")
        let secondID = try makeMeeting(in: store, title: "Second")
        _ = try store.attachMeetingParticipant(
            meetingID: firstID,
            contactIdentifier: "first-contact",
            displayName: "First"
        )
        _ = try store.attachMeetingParticipant(
            meetingID: secondID,
            contactIdentifier: "second-contact",
            displayName: "Second"
        )

        try store.clearMeetings()

        #expect(try store.listMeetingParticipants(meetingID: firstID).isEmpty)
        #expect(try store.listMeetingParticipants(meetingID: secondID).isEmpty)
    }
}
