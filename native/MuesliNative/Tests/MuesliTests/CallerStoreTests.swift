import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Caller store", .serialized)
struct CallerStoreTests {
    private let phone = CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!
    private let otherPhone = CallerHandleNormalizer.phone("+1 202 555 0199", region: nil)!

    private func makeStore() throws -> (DictationStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-callers-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return (store, url)
    }

    private func makeMeeting(in store: DictationStore, title: String, offset: TimeInterval = 0) throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_775_000_000 + offset)
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

    private func count(_ table: String, at url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func rawDisplayName(meetingID: Int64, identifier: String, at url: URL) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT display_name FROM meeting_participants WHERE meeting_id = ? AND participant_identifier = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (identifier as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func meetingID(recordName: String, at url: URL) throws -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM meetings WHERE cloud_record_name = ?", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (recordName as NSString).utf8String, -1, nil)
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    private func attachedID(_ result: CallerAttachResult) throws -> UUID {
        guard case .attached(let id) = result else {
            Issue.record("expected attached, got \(result)")
            throw CancellationError()
        }
        return id
    }

    @Test("First attach creates a nameless person and participant")
    func attachCreatesPersonAndParticipant() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Call")
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: meeting))

        #expect(id == CallerHandleNormalizer.personID(forKey: "phone:+12025550123"))
        let participants = try store.listMeetingParticipants(meetingID: meeting)
        #expect(participants.map(\.participantIdentifier) == ["call-person:\(id.uuidString)"])
        #expect(participants.first?.displayName == "+1 202 555 0123")
        #expect(participants.first?.emailAddress == nil)
        #expect(try store.callerPerson(id: id) == CallerPerson(id: id, displayName: nil, handles: [phone]))
    }

    @Test("Later calls from the same handle reuse the person")
    func secondMeetingReusesPerson() throws {
        let (store, _) = try makeStore()
        let first = try makeMeeting(in: store, title: "First")
        let second = try makeMeeting(in: store, title: "Second", offset: 3_600)
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: first))
        let sameFormat = CallerHandleNormalizer.phone("+12025550123", region: nil)!

        #expect(try store.attachCaller(sameFormat, toMeetingID: second) == .attached(id))
        #expect(try store.callerHistory(personID: id).map(\.meetingID) == [second, first])
        #expect(try store.callerHistory(personID: id).map(\.title) == ["Second", "First"])
    }

    @Test("Caller history pages preserve newest-first ordering")
    func callerHistoryPages() throws {
        let (store, _) = try makeStore()
        let first = try makeMeeting(in: store, title: "First")
        let second = try makeMeeting(in: store, title: "Second", offset: 3_600)
        let third = try makeMeeting(in: store, title: "Third", offset: 7_200)
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: first))
        #expect(try store.attachCaller(phone, toMeetingID: second) == .attached(id))
        #expect(try store.attachCaller(phone, toMeetingID: third) == .attached(id))

        #expect(try store.callerHistory(personID: id, limit: 2, offset: 0).map(\.meetingID) == [third, second])
        #expect(try store.callerHistory(personID: id, limit: 2, offset: 2).map(\.meetingID) == [first])
        #expect(try store.callerHistory(personID: id, limit: 2, offset: 3).isEmpty)
    }

    @Test("Missing and deleted meetings are rejected")
    func missingOrDeletedMeetingRejected() throws {
        let (store, _) = try makeStore()
        #expect(try store.attachCaller(phone, toMeetingID: 999) == .meetingMissing)
        let meeting = try makeMeeting(in: store, title: "Gone")
        try store.deleteMeeting(id: meeting)
        #expect(try store.attachCaller(phone, toMeetingID: meeting) == .meetingMissing)
    }

    @Test("An email already on the meeting is not added twice")
    func emailAlreadyPresentFromCalendar() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Calendar")
        try store.attachCalendarMeetingParticipants(meetingID: meeting, participants: [
            MeetingParticipantDraft(participantIdentifier: "email:bob@x.test", displayName: "Bob", emailAddress: "Bob@X.test"),
        ])
        let email = CallerHandleNormalizer.email("bob@x.test")!

        let personID = CallerHandleNormalizer.personID(forKey: email.key)
        #expect(try store.attachCaller(email, toMeetingID: meeting) == .attached(personID))
        #expect(try store.listMeetingParticipants(meetingID: meeting).count == 1)
        #expect(try store.callerPerson(id: personID) != nil)
        #expect(try store.callerHistory(personID: personID).map(\.meetingID) == [meeting])
        #expect(try store.listMeetingParticipants(meetingID: meeting).first?.callerPersonID == personID)
        #expect(try store.attachCaller(email, toMeetingID: meeting) == .alreadyPresent)

        try store.detachCaller(personID: personID, fromMeetingID: meeting)
        #expect(try store.callerPerson(id: personID) == nil)
        #expect(try store.callerHistory(personID: personID).isEmpty)
        #expect(try store.listMeetingParticipants(meetingID: meeting).count == 1)
    }

    @Test("A suppressed attendee email prevents a duplicate caller row")
    func suppressedCalendarEmailDoesNotCreateCallerRow() throws {
        let (store, url) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Suppressed calendar attendee")
        let email = CallerHandleNormalizer.email("bob@x.test")!
        let identifier = "email:bob@x.test"
        try store.attachCalendarMeetingParticipants(meetingID: meeting, participants: [
            MeetingParticipantDraft(
                participantIdentifier: identifier,
                displayName: "Bob",
                emailAddress: "Bob@X.test"
            ),
        ])
        try store.removeMeetingParticipant(meetingID: meeting, participantIdentifier: identifier)

        #expect(try store.attachCaller(email, toMeetingID: meeting) == .alreadyPresent)
        #expect(try count("meeting_participants", at: url) == 1)
        #expect(try store.listMeetingParticipants(meetingID: meeting).isEmpty)
        #expect(try store.callerPerson(id: CallerHandleNormalizer.personID(forKey: email.key)) == nil)
    }

    @Test("Caller history excludes meetings with only a matching attendee email")
    func matchingCalendarEmailDoesNotCreateCallerHistory() throws {
        let (store, _) = try makeStore()
        let callerMeeting = try makeMeeting(in: store, title: "Phone call")
        let unrelatedMeeting = try makeMeeting(in: store, title: "Unrelated", offset: 60)
        let email = CallerHandleNormalizer.email("bob@x.test")!
        let personID = try attachedID(try store.attachCaller(email, toMeetingID: callerMeeting))
        try store.attachCalendarMeetingParticipants(meetingID: unrelatedMeeting, participants: [
            MeetingParticipantDraft(
                participantIdentifier: "email:bob@x.test",
                displayName: "Bob",
                emailAddress: "Bob@X.test"
            ),
        ])

        #expect(try store.callerHistory(personID: personID).map(\.meetingID) == [callerMeeting])
        #expect(try store.listMeetingParticipants(meetingID: unrelatedMeeting).first?.callerPersonID == nil)
    }

    @Test("A calendar refresh preserves history for a caller captured from an attendee")
    func calendarRefreshPreservesCallerHistory() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Phone call with attendee")
        let email = CallerHandleNormalizer.email("bob@x.test")!
        try store.attachCalendarMeetingParticipants(meetingID: meeting, participants: [
            MeetingParticipantDraft(
                participantIdentifier: "calendar:bob",
                displayName: "Bob",
                emailAddress: "Bob@X.test"
            ),
        ])
        let personID = try attachedID(try store.attachCaller(email, toMeetingID: meeting))

        try store.reconcileCalendarMeetingParticipants(meetingID: meeting, participants: [])

        #expect(try store.listMeetingParticipants(meetingID: meeting).isEmpty)
        #expect(try store.callerHistory(personID: personID).map(\.meetingID) == [meeting])

        try store.reconcileCalendarMeetingParticipants(meetingID: meeting, participants: [
            MeetingParticipantDraft(
                participantIdentifier: "calendar:bob",
                displayName: "Bob",
                emailAddress: "Bob@X.test"
            ),
        ])
        #expect(try store.attachCaller(email, toMeetingID: meeting) == .attached(personID))
        #expect(try store.listMeetingParticipants(meetingID: meeting).first?.callerPersonID == personID)
    }

    @Test("Removing a manual attendee removes its caller history")
    func removingManualAttendeeRemovesCallerHistory() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Phone call with contact")
        let email = CallerHandleNormalizer.email("bob@x.test")!
        let identifier = "contact:bob"
        try store.attachMeetingParticipant(
            meetingID: meeting,
            participant: MeetingParticipantDraft(
                participantIdentifier: identifier,
                displayName: "Bob",
                emailAddress: "Bob@X.test"
            )
        )
        let personID = try attachedID(try store.attachCaller(email, toMeetingID: meeting))
        #expect(try store.callerHistory(personID: personID).map(\.meetingID) == [meeting])

        try store.removeMeetingParticipant(meetingID: meeting, participantIdentifier: identifier)

        #expect(try store.callerHistory(personID: personID).isEmpty)
        #expect(try store.callerPerson(id: personID) == nil)
    }

    @Test("A calendar refresh keeps a removed attendee out of caller history")
    func calendarRefreshKeepsSuppressedCallerOutOfHistory() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Removed phone call attendee")
        let email = CallerHandleNormalizer.email("bob@x.test")!
        let identifier = "calendar:bob"
        try store.attachCalendarMeetingParticipants(meetingID: meeting, participants: [
            MeetingParticipantDraft(
                participantIdentifier: identifier,
                displayName: "Bob",
                emailAddress: "Bob@X.test"
            ),
        ])
        let personID = try attachedID(try store.attachCaller(email, toMeetingID: meeting))
        try store.removeMeetingParticipant(meetingID: meeting, participantIdentifier: identifier)

        try store.reconcileCalendarMeetingParticipants(meetingID: meeting, participants: [])

        #expect(try store.callerHistory(personID: personID).isEmpty)
    }

    @Test("Removing an automatic caller suppresses it for good")
    func removalSuppressesAndSticks() throws {
        let (store, url) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Removed")
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: meeting))
        let identifier = "call-person:\(id.uuidString)"

        try store.removeMeetingParticipant(meetingID: meeting, participantIdentifier: identifier)
        #expect(try store.listMeetingParticipants(meetingID: meeting).isEmpty)
        _ = try store.renameCallerPerson(id: id, displayName: "Ann")
        #expect(try store.attachCaller(phone, toMeetingID: meeting) == .suppressed)
        #expect(try store.listMeetingParticipants(meetingID: meeting).isEmpty)
        #expect(try rawDisplayName(meetingID: meeting, identifier: identifier, at: url) == "+1 202 555 0123")
        #expect(try store.callerHistory(personID: id).isEmpty)
    }

    @Test("An existing caller row is left untouched")
    func existingRowUntouched() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Twice")
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: meeting))

        #expect(try store.attachCaller(phone, toMeetingID: meeting) == .alreadyPresent)
        #expect(try store.listMeetingParticipants(meetingID: meeting).map(\.participantIdentifier) == ["call-person:\(id.uuidString)"])
    }

    @Test("Renaming updates caller rows and clearing falls back to the handle")
    func renameUpdatesRowsAndClears() throws {
        let (store, _) = try makeStore()
        let first = try makeMeeting(in: store, title: "First")
        let second = try makeMeeting(in: store, title: "Second", offset: 3_600)
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: first))
        _ = try store.attachCaller(phone, toMeetingID: second)

        #expect(try store.renameCallerPerson(id: id, displayName: "  Ann Lee ") == [second, first])
        #expect(try store.callerPerson(id: id)?.displayName == "Ann Lee")
        #expect(try store.listMeetingParticipants(meetingID: first).first?.displayName == "Ann Lee")
        #expect(try store.listMeetingParticipants(meetingID: second).first?.displayName == "Ann Lee")

        _ = try store.renameCallerPerson(id: id, displayName: "  ")
        #expect(try store.callerPerson(id: id)?.displayName == nil)
        #expect(try store.listMeetingParticipants(meetingID: first).first?.displayName == "+1 202 555 0123")
    }

    @Test("A later attach uses the edited name")
    func attachUsesEditedName() throws {
        let (store, _) = try makeStore()
        let first = try makeMeeting(in: store, title: "First")
        let second = try makeMeeting(in: store, title: "Second", offset: 3_600)
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: first))
        _ = try store.renameCallerPerson(id: id, displayName: "Ann Lee")

        _ = try store.attachCaller(phone, toMeetingID: second)
        #expect(try store.listMeetingParticipants(meetingID: second).first?.displayName == "Ann Lee")
    }

    @Test("History excludes deleted meetings and suppressed rows")
    func historyExcludesDeletedAndSuppressed() throws {
        let (store, _) = try makeStore()
        let kept = try makeMeeting(in: store, title: "Kept")
        let deleted = try makeMeeting(in: store, title: "Deleted", offset: 60)
        let removed = try makeMeeting(in: store, title: "Removed", offset: 120)
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: kept))
        _ = try store.attachCaller(phone, toMeetingID: deleted)
        _ = try store.attachCaller(phone, toMeetingID: removed)

        try store.deleteMeeting(id: deleted)
        try store.removeMeetingParticipant(meetingID: removed, participantIdentifier: "call-person:\(id.uuidString)")
        #expect(try store.callerHistory(personID: id).map(\.meetingID) == [kept])
    }

    @Test("Deleting a meeting removes callers no meeting references")
    func deleteMeetingRemovesOrphanCallers() throws {
        let (store, url) = try makeStore()
        let shared = try makeMeeting(in: store, title: "Shared")
        let only = try makeMeeting(in: store, title: "Only", offset: 60)
        let kept = try attachedID(try store.attachCaller(phone, toMeetingID: shared))
        _ = try store.attachCaller(phone, toMeetingID: only)
        let orphan = try attachedID(try store.attachCaller(otherPhone, toMeetingID: only))

        try store.deleteMeeting(id: only)
        #expect(try store.callerPerson(id: orphan) == nil)
        #expect(try store.callerPerson(id: kept) != nil)
        #expect(try count("caller_person_handles", at: url) == 1)
    }

    @Test("Clearing meeting history removes all caller data")
    func clearMeetingsRemovesAllCallerData() throws {
        let (store, url) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Call")
        _ = try store.attachCaller(phone, toMeetingID: meeting)
        _ = try store.attachCaller(otherPhone, toMeetingID: meeting)

        try store.clearMeetings()
        #expect(try count("caller_people", at: url) == 0)
        #expect(try count("caller_person_handles", at: url) == 0)
    }

    @Test("Clearing meeting history is all-or-nothing")
    func clearMeetingsIsAtomic() throws {
        let (store, url) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Call")
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: meeting))
        try execute(
            "CREATE TRIGGER abort_clear BEFORE UPDATE OF deleted_at ON meetings BEGIN SELECT RAISE(ABORT, 'forced'); END;",
            at: url
        )

        #expect(throws: (any Error).self) { try store.clearMeetings() }
        #expect(try store.listMeetingParticipants(meetingID: meeting).count == 1)
        #expect(try store.callerPerson(id: id) != nil)
    }

    @Test("A meeting deleted on another device drops its callers")
    func remoteDeletedMeetingDropsCallers() throws {
        let (store, url) = try makeStore()
        let updatedAt = Date(timeIntervalSince1970: 1_775_000_000)
        func record(deleted: Bool, at date: Date) -> SyncTextRecord {
            SyncTextRecord(
                id: "meeting-remote-caller",
                kind: .meeting,
                title: deleted ? nil : "Remote call",
                text: deleted ? "" : "hello",
                speakerTranscript: nil,
                summaryText: nil,
                manualNotes: nil,
                source: "ios",
                meetingStatus: .completed,
                engineIdentifier: "engine",
                createdAt: updatedAt.addingTimeInterval(-120),
                updatedAt: date,
                startedAt: updatedAt.addingTimeInterval(-120),
                endedAt: updatedAt,
                durationSeconds: 120,
                wordCount: deleted ? 0 : 1,
                isDeleted: deleted
            )
        }
        _ = try store.upsertSyncedTextRecord(record(deleted: false, at: updatedAt))
        let meeting = try #require(try meetingID(recordName: "meeting-remote-caller", at: url))
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: meeting))

        _ = try store.upsertSyncedTextRecord(record(deleted: true, at: updatedAt.addingTimeInterval(60)))
        #expect(try store.listMeetingParticipants(meetingID: meeting).isEmpty)
        #expect(try store.callerPerson(id: id) == nil)
    }

    @Test("Orphan cleanup can find caller rows through an index")
    func participantIdentifierIsIndexed() throws {
        let (_, url) = try makeStore()
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = """
        SELECT COUNT(*) FROM pragma_index_list('meeting_participants') AS list
        WHERE (SELECT name FROM pragma_index_info(list.name) WHERE seqno = 0) = 'participant_identifier'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int64(statement, 0) >= 1)
    }

    @Test("Migration is idempotent and leaves curated participants alone")
    func migrationIdempotentWithCuratedParticipants() throws {
        let (store, url) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Curated")
        try store.attachMeetingParticipant(meetingID: meeting, participant: MeetingParticipantDraft(
            participantIdentifier: "contact:1", displayName: "Bob", emailAddress: nil
        ))
        try store.attachCalendarMeetingParticipants(meetingID: meeting, participants: [
            MeetingParticipantDraft(participantIdentifier: "calendar:c", displayName: "Cy", emailAddress: "cy@x.test"),
        ])
        let before = try store.listMeetingParticipants(meetingID: meeting)

        try store.migrateIfNeeded()
        try store.migrateIfNeeded()
        #expect(try store.listMeetingParticipants(meetingID: meeting) == before)
        #expect(try count("caller_people", at: url) == 0)
    }

    @Test("Detaching removes the caller from a meeting without suppressing it")
    func detachCallerDeletesRowAndOrphan() throws {
        let (store, _) = try makeStore()
        let meeting = try makeMeeting(in: store, title: "Resumed")
        let id = try attachedID(try store.attachCaller(phone, toMeetingID: meeting))

        try store.detachCaller(personID: id, fromMeetingID: meeting)
        #expect(try store.listMeetingParticipants(meetingID: meeting).isEmpty)
        #expect(try store.callerPerson(id: id) == nil)
        #expect(try store.attachCaller(phone, toMeetingID: meeting) == .attached(id))
    }

    @Test("Only call-person identifiers map to caller IDs")
    func callerPersonIDParsesOnlyCallIdentifiers() {
        #expect(
            DictationStore.callerPersonID(fromParticipantIdentifier: "call-person:086aa82b-2ca7-5f63-b6b9-9a94cc45b53c")
                == UUID(uuidString: "086aa82b-2ca7-5f63-b6b9-9a94cc45b53c")
        )
        #expect(DictationStore.callerPersonID(fromParticipantIdentifier: "contact:x") == nil)
        #expect(DictationStore.callerPersonID(fromParticipantIdentifier: "call-person:nope") == nil)
    }
}
