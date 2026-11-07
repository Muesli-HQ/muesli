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

    @Test("People search finds a surname through the existing meeting index")
    func peopleSearchBySurname() throws {
        let store = try makeStore()
        let id = try makeMeeting(in: store)
        try store.attachMeetingParticipant(meetingID: id, participant: participant("contact:alice", name: "Alice Example", email: "alice@example.test"))
        _ = try GlobalSearchIndex(databaseURL: store.databasePath())
        #expect(try store.searchMeetingPeople(query: "Exam").map(\.displayName) == ["Alice Example"])
        #expect(try store.searchMeetingPeople(query: "missing").isEmpty)
        try store.removeMeetingParticipant(meetingID: id, participantIdentifier: "contact:alice")
        #expect(try store.searchMeetingPeople(query: "Exam").isEmpty)
    }

    @Test("Related meetings use stable identities and ignore suppressed participants")
    func relatedMeetings() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store, title: "First")
        let second = try makeMeeting(in: store, title: "Second")
        let unrelated = try makeMeeting(in: store, title: "Different Alex")
        try store.attachMeetingParticipant(meetingID: first, participant: participant("contact:alex", name: "Alex"))
        try store.attachMeetingParticipant(meetingID: second, participant: participant("contact:alex", name: "Alex"))
        try store.attachMeetingParticipant(meetingID: unrelated, participant: participant("contact:other", name: "Alex"))
        #expect(try store.relatedMeetings(meetingID: first).map(\.meetingID) == [second])
        try store.removeMeetingParticipant(meetingID: second, participantIdentifier: "contact:alex")
        #expect(try store.relatedMeetings(meetingID: first).isEmpty)
    }

    @Test("Exact email duplicates require confirmation and merges can be undone")
    func multipleContactEmails() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store, title: "Work")
        let second = try makeMeeting(in: store, title: "Personal")
        try store.attachCalendarMeetingParticipants(meetingID: first, participants: [participant("email:work@example.test", name: "Alex", email: "work@example.test")])
        try store.attachCalendarMeetingParticipants(meetingID: second, participants: [participant("email:home@example.test", name: "Alex", email: "home@example.test")])
        try store.attachMeetingParticipant(meetingID: first, participant: .init(participantIdentifier: "contact:alex", displayName: "Alex Smith", emailAddress: "work@example.test", emailAddresses: ["work@example.test", "home@example.test"]))
        #expect(try store.duplicateMeetingPeople().count == 2)
        #expect(try store.relatedMeetings(meetingID: first).isEmpty)
        let person = try #require(store.searchMeetingPeople(query: "Alex Smith").first)
        let target = try #require(person.personID)
        for candidate in try store.duplicateMeetingPeople() {
            let source = candidate.first.personID == target ? candidate.second.personID : candidate.first.personID
            try store.mergeMeetingPeople(targetID: target, sourceID: try #require(source))
        }
        #expect(try store.listMeetingParticipants(meetingID: first).count == 1)
        #expect(try store.relatedMeetings(meetingID: first).map(\.meetingID) == [second])
        let index = try GlobalSearchIndex(databaseURL: store.databasePath())
        let results = try index.search(.init(text: "", kinds: [.meeting], person: person))
        #expect(Set(results.map(\.sourceID)) == Set([String(first), String(second)]))
        let history = try store.meetingPeopleMergeHistory()
        #expect(history.count == 2)
        #expect(throws: DictationStoreError.self) { try store.undoMeetingPeopleMerge(id: history[1].id) }
        try store.undoMeetingPeopleMerge(id: history[0].id)
        try store.undoMeetingPeopleMerge(id: history[1].id)
        #expect(try store.duplicateMeetingPeople().count == 2)
        #expect(try store.listMeetingParticipants(meetingID: first).count == 2)
        #expect(try store.relatedMeetings(meetingID: first).isEmpty)
    }

    @Test("People with the same name remain separate")
    func distinctNamesakes() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store)
        let second = try makeMeeting(in: store)
        try store.attachMeetingParticipant(meetingID: first, participant: participant("contact:1", name: "Alex"))
        try store.attachMeetingParticipant(meetingID: second, participant: participant("contact:2", name: "Alex"))
        let namesakes = try store.searchMeetingPeople(query: "Alex")
        #expect(namesakes.count == 2)
        #expect(try store.duplicateMeetingPeople().isEmpty)
        #expect(throws: DictationStoreError.self) {
            try store.mergeMeetingPeople(targetID: try #require(namesakes[0].personID), sourceID: try #require(namesakes[1].personID))
        }
        #expect(try store.relatedMeetings(meetingID: first).isEmpty)
    }

    @Test("Shared email does not identify either contact")
    func ambiguousEmail() throws {
        let store = try makeStore()
        let calendar = try makeMeeting(in: store)
        let first = try makeMeeting(in: store)
        let second = try makeMeeting(in: store)
        try store.attachCalendarMeetingParticipants(meetingID: calendar, participants: [participant("email:team@example.test", name: "Team", email: "team@example.test")])
        try store.attachMeetingParticipant(meetingID: first, participant: participant("contact:1", name: "One", email: "team@example.test"))
        try store.attachMeetingParticipant(meetingID: second, participant: participant("contact:2", name: "Two", email: "team@example.test"))
        #expect(try store.relatedMeetings(meetingID: first).isEmpty)
        #expect(try store.relatedMeetings(meetingID: second).isEmpty)
        #expect(try store.searchMeetingPeople(query: "team@example.test").count == 3)
    }

    @Test("Undo restores new source-identifier associations without restoring removed ones")
    func undoHonorsSubsequentEdits() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store)
        let second = try makeMeeting(in: store)
        let later = try makeMeeting(in: store)
        try store.attachMeetingParticipant(meetingID: first, participant: participant("contact:one", name: "One", email: "shared@example.test"))
        try store.attachMeetingParticipant(meetingID: second, participant: participant("email:shared@example.test", name: "Two", email: "shared@example.test"))
        let candidate = try #require(store.duplicateMeetingPeople().first)
        let target = try #require(candidate.first.displayName == "One" ? candidate.first.personID : candidate.second.personID)
        let source = try #require(candidate.first.personID == target ? candidate.second.personID : candidate.first.personID)
        try store.mergeMeetingPeople(targetID: target, sourceID: source)
        try store.attachMeetingParticipant(meetingID: later, participant: .init(participantIdentifier: "email:shared@example.test", displayName: "Two", emailAddress: "shared@example.test", emailAddresses: ["new-address@example.test"]))
        try store.removeMeetingParticipant(meetingID: second, participantIdentifier: "email:shared@example.test")
        try store.undoMeetingPeopleMerge(id: try #require(store.meetingPeopleMergeHistory().first?.id))
        #expect(try store.listMeetingParticipants(meetingID: second).isEmpty)
        #expect(try store.relatedMeetings(meetingID: first).isEmpty)
        #expect(try store.listMeetingParticipants(meetingID: later).count == 1)
        #expect(try store.searchMeetingPeople(query: "new-address@example.test").first?.personID == source)
        #expect(try store.duplicateMeetingPeople().count == 1)
    }

    @Test("Refreshing a merged source contact preserves the chosen name")
    func mergeKeepsChosenName() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store)
        let second = try makeMeeting(in: store)
        try store.attachMeetingParticipant(meetingID: first, participant: participant("contact:first", name: "Preferred", email: "shared@example.test"))
        try store.attachMeetingParticipant(meetingID: second, participant: participant("contact:second", name: "Other", email: "shared@example.test"))
        let pair = try #require(store.duplicateMeetingPeople().first)
        let target = try #require(pair.first.displayName == "Preferred" ? pair.first.personID : pair.second.personID)
        let source = try #require(pair.first.personID == target ? pair.second.personID : pair.first.personID)
        try store.mergeMeetingPeople(targetID: target, sourceID: source)
        try store.attachMeetingParticipant(meetingID: second, participant: participant("contact:second", name: "Updated Other", email: "shared@example.test"))
        #expect(try store.searchMeetingPeople(query: "Preferred").first?.personID == target)
        try store.undoMeetingPeopleMerge(id: try #require(store.meetingPeopleMergeHistory().first?.id))
        #expect(try store.searchMeetingPeople(query: "Preferred").first?.personID == target)
        #expect(try store.searchMeetingPeople(query: "Updated Other").first?.personID == source)
    }

    @Test("Suggestions require current evidence and explicit confirmation")
    func suggestionEvidenceAndConfirmation() throws {
        let store = try makeStore()
        let id = try makeMeeting(in: store)
        let transcript = "Welcome Maya, thanks for joining us today."
        try store.updateMeetingTranscript(id: id, rawTranscript: transcript)
        let fingerprint = DictationStore.participantEvidenceFingerprint(transcript: transcript, notes: "")
        let supported = MeetingParticipantSuggestion(id: "Maya", name: "Maya", source: "transcript", excerpt: "Welcome Maya, thanks for joining")
        let unsupported = MeetingParticipantSuggestion(id: "Lee", name: "Lee", source: "transcript", excerpt: "Lee joined the discussion")
        let unrelated = MeetingParticipantSuggestion(id: "Lee", name: "Lee", source: "transcript", excerpt: "Welcome Maya, thanks for joining")
        try store.saveParticipantSuggestions(meetingID: id, fingerprint: fingerprint, suggestions: [supported, unsupported, unrelated])
        #expect(try store.listMeetingParticipants(meetingID: id).isEmpty)
        #expect(try store.participantSuggestions(meetingID: id).map(\.name) == ["Maya"])
        try store.updateMeetingTranscript(id: id, rawTranscript: "Changed transcript")
        #expect(try store.participantSuggestions(meetingID: id).isEmpty)
        #expect(throws: DictationStoreError.self) {
            try store.resolveParticipantSuggestion(meetingID: id, fingerprint: fingerprint, name: "Maya", add: true)
        }
        #expect(try store.listMeetingParticipants(meetingID: id).isEmpty)
        try store.updateMeetingTranscript(id: id, rawTranscript: transcript)
        try store.saveParticipantSuggestions(meetingID: id, fingerprint: fingerprint, suggestions: [supported])
        try store.resolveParticipantSuggestion(meetingID: id, fingerprint: fingerprint, name: "Maya", add: true)
        #expect(try store.listMeetingParticipants(meetingID: id).map(\.displayName) == ["Maya"])
        #expect(try store.participantSuggestions(meetingID: id).isEmpty)
        try store.saveParticipantSuggestions(meetingID: id, fingerprint: fingerprint, suggestions: [supported])
        #expect(try store.participantSuggestions(meetingID: id).isEmpty)
    }

    @Test("Confirming a suggested existing person links its canonical identity")
    func confirmExistingPerson() throws {
        let store = try makeStore()
        let earlier = try makeMeeting(in: store)
        let current = try makeMeeting(in: store)
        try store.attachMeetingParticipant(meetingID: earlier, participant: participant("contact:maya", name: "Maya"))
        let person = try #require(store.searchMeetingPeople(query: "Maya").first)
        let transcript = "Welcome Maya, thanks for joining us today."
        try store.updateMeetingTranscript(id: current, rawTranscript: transcript)
        let fingerprint = DictationStore.participantEvidenceFingerprint(transcript: transcript, notes: "")
        let suggestion = MeetingParticipantSuggestion(id: "Maya", name: "Maya", source: "transcript", excerpt: "Welcome Maya, thanks for joining")
        try store.saveParticipantSuggestions(meetingID: current, fingerprint: fingerprint, suggestions: [suggestion])
        #expect(try store.relatedMeetings(meetingID: earlier).isEmpty)
        try store.resolveParticipantSuggestion(meetingID: current, fingerprint: fingerprint, name: "Maya", add: true, existingPerson: person)
        #expect(try store.relatedMeetings(meetingID: earlier).map(\.meetingID) == [current])
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
            "person_id",
        ])
    }

    @Test("Legacy participant snapshots get stable person identities on migration")
    func legacyPeopleMigration() throws {
        let store = try makeStore()
        let first = try makeMeeting(in: store)
        let second = try makeMeeting(in: store)
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
          DELETE FROM local_migrations WHERE identifier='meeting_people_v1';
          INSERT INTO meeting_participants(meeting_id,participant_identifier,display_name,email_address,insertion_order)
          VALUES(\(first),'email:legacy@example.test','Legacy Person','legacy@example.test',0),
                (\(second),'email:legacy@example.test','Legacy Person','legacy@example.test',0);
          """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        try store.migrateIfNeeded()
        let id = try #require(store.searchMeetingPeople(query: "Legacy").first?.personID)
        #expect(try store.relatedMeetings(meetingID: first).map(\.meetingID) == [second])
        try store.migrateIfNeeded()
        #expect(try store.searchMeetingPeople(query: "Legacy").first?.personID == id)
    }

    @Test("Calendar attendee renames update the People search index", arguments: ["calendar:alice", "email:alice@example.test"])
    func calendarRenameUpdatesPeopleSearch(identifier: String) throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        try store.attachCalendarMeetingParticipants(meetingID: meetingID, participants: [participant(identifier, name: "Alice Old")])
        let original = try #require(store.searchMeetingPeople(query: "Alice Old").first?.personID)
        try store.attachCalendarMeetingParticipants(meetingID: meetingID, participants: [participant(identifier, name: "Alice New")])
        #expect(try store.searchMeetingPeople(query: "Alice New").first?.personID == original)
        #expect(try store.searchMeetingPeople(query: "Alice Old").isEmpty)
    }

    @Test("Calendar updates do not overwrite a manually curated identity")
    func calendarRenamePreservesManualName() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(in: store)
        let id = "email:alice@example.test"
        try store.attachMeetingParticipant(meetingID: meetingID, participant: participant(id, name: "Alice Preferred"))
        try store.attachCalendarMeetingParticipants(meetingID: meetingID, participants: [participant(id, name: "Alice Calendar")])
        #expect(try store.searchMeetingPeople(query: "Alice Preferred").count == 1)
        #expect(try store.searchMeetingPeople(query: "Alice Calendar").isEmpty)
    }

    @Test("Calendar renames preserve the chosen merged contact name")
    func calendarRenamePreservesMergedContact() throws {
        let store = try makeStore()
        let calendar = try makeMeeting(in: store)
        let contact = try makeMeeting(in: store)
        let email = "alice@example.test"
        try store.attachCalendarMeetingParticipants(meetingID: calendar, participants: [participant("email:\(email)", name: "Alice Calendar", email: email)])
        try store.attachMeetingParticipant(meetingID: contact, participant: participant("contact:alice", name: "Alice Preferred", email: email))
        let pair = try #require(store.duplicateMeetingPeople().first)
        let target = try #require(pair.first.displayName == "Alice Preferred" ? pair.first.personID : pair.second.personID)
        let source = try #require(pair.first.personID == target ? pair.second.personID : pair.first.personID)
        try store.mergeMeetingPeople(targetID: target, sourceID: source)
        try store.reconcileCalendarMeetingParticipants(meetingID: calendar, participants: [participant("email:\(email)", name: "Alice Renamed", email: email)])
        #expect(try store.searchMeetingPeople(query: "Alice Preferred").first?.personID == target)
        #expect(try store.searchMeetingPeople(query: "Alice Renamed").isEmpty)
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
