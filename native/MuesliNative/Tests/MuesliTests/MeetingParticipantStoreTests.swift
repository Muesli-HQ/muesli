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

    private func participant(
        _ identifier: String,
        name: String,
        email: String? = nil
    ) -> MeetingParticipantDraft {
        MeetingParticipantDraft(
            participantIdentifier: identifier,
            displayName: name,
            emailAddress: email
        )
    }

    @Test("participant migration is idempotent and creates the expected columns")
    func migrationIsIdempotent() throws {
        let store = try makeStore()

        try store.migrateIfNeeded()

        var database: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(meeting_participants)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.append(String(cString: name))
            }
        }
        #expect(columns == [
            "meeting_id",
            "participant_identifier",
            "display_name",
            "email_address",
            "insertion_order",
            "source",
            "is_suppressed",
        ])
    }

    @Test("calendar attendee snapshots retain their names and emails")
    func calendarAttendeeReadback() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [participant(
                "email:alice@example.test",
                name: "Alice Example",
                email: "alice@example.test"
            )]
        )

        let saved = try #require(store.listMeetingParticipants(meetingID: meetingID).first)
        #expect(saved.participantIdentifier == "email:alice@example.test")
        #expect(saved.displayName == "Alice Example")
        #expect(saved.emailAddress == "alice@example.test")
    }

    @Test("manual contacts do not require an email address")
    func manualContactWithoutEmail() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant("contact:local-id", name: "Local Person")
        )

        let saved = try #require(store.listMeetingParticipants(meetingID: meetingID).first)
        #expect(saved.displayName == "Local Person")
        #expect(saved.emailAddress == nil)
    }

    @Test("re-adding a participant refreshes its snapshot without changing order")
    func duplicateRefreshesSnapshot() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant("contact:alice", name: "Alice")
        )
        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant(
                "contact:alice",
                name: "Alice Example",
                email: "alice@example.test"
            )
        )

        let saved = try #require(store.listMeetingParticipants(meetingID: meetingID).first)
        #expect(saved.displayName == "Alice Example")
        #expect(saved.emailAddress == "alice@example.test")
        #expect(saved.insertionOrder == 0)
    }

    @Test("participants preserve insertion order and can be removed")
    func insertionOrderAndRemoval() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant("contact:b", name: "B")
        )
        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant("contact:a", name: "A")
        )

        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.displayName) == ["B", "A"])

        try store.removeMeetingParticipant(
            meetingID: meetingID,
            participantIdentifier: "contact:b"
        )
        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.displayName) == ["A"])
    }

    @Test("participant batches preserve order and refresh existing snapshots")
    func batchInsertAndRefresh() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [
                participant("calendar:alice", name: "Alice"),
                participant("calendar:bob", name: "Bob", email: "bob@example.test"),
                participant("calendar:carol", name: "Carol"),
            ]
        )
        try store.attachCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [
                participant("calendar:bob", name: "Bob Example"),
                participant("calendar:dana", name: "Dana"),
            ]
        )

        let saved = try store.listMeetingParticipants(meetingID: meetingID)
        #expect(saved.map(\.displayName) == ["Alice", "Bob Example", "Carol", "Dana"])
        #expect(saved.map(\.insertionOrder) == [0, 1, 2, 3])
        #expect(saved[1].emailAddress == "bob@example.test")
    }

    @Test("calendar reconciliation preserves local curation while refreshing the event snapshot")
    func calendarReconciliationPreservesLocalCuration() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [
                participant("email:alice@example.test", name: "Alice"),
                participant("email:carol@example.test", name: "Carol"),
            ]
        )
        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant("contact:local-id", name: "Local Person")
        )
        try store.removeMeetingParticipant(
            meetingID: meetingID,
            participantIdentifier: "email:alice@example.test"
        )

        try store.reconcileCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [
                participant("email:alice@example.test", name: "Alice Renamed"),
                participant("email:carol@example.test", name: "Carol Renamed"),
                participant("email:bob@example.test", name: "Bob"),
            ]
        )

        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.displayName) == [
            "Carol Renamed",
            "Local Person",
            "Bob",
        ])

        try store.reconcileCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [
                participant("email:alice@example.test", name: "Alice Renamed Again"),
            ]
        )
        #expect(try store.listMeetingParticipants(meetingID: meetingID).map(\.displayName) == [
            "Local Person",
        ])
    }

    @Test("manual contact replaces the matching calendar attendee and survives later event changes")
    func manualContactWinsEmailDeduplication() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)

        try store.attachCalendarMeetingParticipants(
            meetingID: meetingID,
            participants: [participant(
                "email:alice@example.test",
                name: "Alice from Calendar",
                email: "alice@example.test"
            )]
        )
        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant(
                "email:alice@example.test",
                name: "Alice from Contacts",
                email: "alice@example.test"
            )
        )

        try store.reconcileCalendarMeetingParticipants(meetingID: meetingID, participants: [])

        let saved = try store.listMeetingParticipants(meetingID: meetingID)
        #expect(saved.count == 1)
        #expect(saved.first?.displayName == "Alice from Contacts")
    }

    @Test("participants cannot be attached to a missing meeting")
    func missingMeetingIsRejected() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.attachMeetingParticipant(
                meetingID: 999,
                participant: participant("calendar:missing", name: "Missing")
            )
        }
    }

    @Test("deleting a meeting removes its local participant snapshots")
    func meetingDeletionRemovesParticipants() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        try store.attachMeetingParticipant(
            meetingID: meetingID,
            participant: participant("contact:alice", name: "Alice")
        )
        try store.removeMeetingParticipant(
            meetingID: meetingID,
            participantIdentifier: "contact:alice"
        )

        try store.deleteMeeting(id: meetingID)

        #expect(try store.listMeetingParticipants(meetingID: meetingID).isEmpty)
    }
}
