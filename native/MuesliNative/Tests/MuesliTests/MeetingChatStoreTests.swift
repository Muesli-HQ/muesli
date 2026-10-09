import Foundation
import Testing
import SQLite3
@testable import MuesliCore

@Suite("Meeting chat storage")
struct MeetingChatStoreTests {
    private func fixture() throws -> (DictationStore, MeetingChatStore, Int64) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID()).db")
        let meetings = DictationStore(databaseURL: url)
        try meetings.migrateIfNeeded()
        let id = try meetings.insertMeeting(title: "Planning", calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_000), endTime: Date(timeIntervalSince1970: 1_060),
            rawTranscript: "[00:00:05] You: Ship on Friday.", formattedNotes: "## Decisions\nShip Friday.",
            micAudioPath: nil, systemAudioPath: nil)
        return (meetings, MeetingChatStore(databaseURL: url), id)
    }

    private func pending(_ chat: MeetingChatStore, _ id: Int64) throws -> (MeetingChatSession, MeetingChatTurn, [MeetingChatDependency]) {
        let session = try chat.createSession(scope: .init(), title: "Launch")
        let turn = try chat.beginTurn(sessionID: session.id, question: "When do we ship?", scope: .init(), provider: "test", model: "test")
        let source = try #require(chat.sourceSnapshots(scope: .init()).first { $0.meetingID == id })
        let dependencies = [MeetingChatDependency(meetingID: id, revision: source.revision)]
        try chat.attachEvidence(turnID: turn.id, dependencies: dependencies)
        return (session, turn, dependencies)
    }

    @Test func roundTripsSessionTurnAndEditedDraft() throws {
        let (_, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        try chat.saveDraft(turnID: turn.id, text: "We plan to ship Friday.")
        let saved = try #require(chat.turns(sessionID: session.id).first)
        #expect(saved.originalAnswer == "Friday")
        #expect(saved.editableDraft == "We plan to ship Friday.")
        #expect(saved.state == .completed)
    }

    @Test func recoversPendingTurnsAsInterrupted() throws {
        let (_, chat, id) = try fixture()
        let (session, _, _) = try pending(chat, id)
        try chat.interruptPendingTurns()
        #expect(try chat.turns(sessionID: session.id).first?.state == .interrupted)
    }

    @Test func deletionScrubsAnswersIncludingInheritedDependencies() throws {
        let (meetings, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Friday", citations: [], dependencies: deps))
        let second = try chat.beginTurn(sessionID: session.id, question: "And the deadline?", scope: .init(), provider: "test", model: "test")
        try chat.attachEvidence(turnID: second.id, dependencies: deps)
        #expect(try chat.finishTurn(turnID: second.id, answer: "Friday again", citations: [], dependencies: deps))
        try chat.saveDraft(turnID: second.id, text: "Private draft")
        try meetings.deleteMeeting(id: id)
        for turn in try chat.turns(sessionID: session.id) {
            #expect(turn.state == .sourceDeleted)
            #expect(turn.originalAnswer == nil)
            #expect(turn.editableDraft == nil)
            #expect(turn.citations.isEmpty)
            #expect(!turn.question.isEmpty)
        }
    }

    @Test func historyWipeRemovesChatAndDerivedContent() throws {
        let (meetings, chat, id) = try fixture()
        _ = try pending(chat, id)
        try meetings.clearMeetings()
        #expect(try chat.sessions().isEmpty)
        #expect(try chat.sourceSnapshots(scope: .init()).isEmpty)
    }

    @Test func lateCompletionCannotRecreateDeletedSession() throws {
        let (_, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        try chat.deleteSession(id: session.id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Late secret", citations: [], dependencies: deps) == false)
        #expect(try chat.sessions().isEmpty)
    }

    @Test func sameTimestampEditRejectsCompletion() throws {
        let (meetings, chat, id) = try fixture()
        try meetings.withChatDatabase { db in try MeetingChatSQL.execute("UPDATE meetings SET updated_at=1000 WHERE id=?", [.integer(id)], db: db) }
        let (_, turn, deps) = try pending(chat, id)
        try meetings.updateMeetingNotes(id: id, formattedNotes: "## Decisions\nShip Monday.")
        try meetings.withChatDatabase { db in try MeetingChatSQL.execute("UPDATE meetings SET updated_at=1000 WHERE id=?", [.integer(id)], db: db) }
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps) == false)
    }

    @Test func completionChecksStoredDependenciesEvenIfCallerOmitsThem() throws {
        let (meetings, chat, id) = try fixture()
        let (_, turn, _) = try pending(chat, id)
        try meetings.updateMeetingNotes(id: id, formattedNotes: "Changed source")
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Stale", citations: [], dependencies: []) == false)
    }

    @Test func usesSuppliedDatabaseURL() throws {
        let (_, first, _) = try fixture()
        let (_, second, _) = try fixture()
        _ = try first.createSession(scope: .init(), title: "Only first")
        #expect(try second.sessions().isEmpty)
    }

    @Test func scopeChangesResetContextEvenWhenReturningToPreviousScope() throws {
        let (_, chat, id) = try fixture()
        let (session, _, _) = try pending(chat, id)
        try chat.updateSession(id: session.id, title: nil, scope: .init(selection: .meetings([id])))
        try chat.updateSession(id: session.id, title: nil, scope: .init())
        #expect(try chat.sessions().first?.contextStartOrdinal == 1)
    }

    @Test func syncedTombstoneInvalidatesAnswer() throws {
        let (meetings, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        var record = try #require(meetings.textRecordsNeedingSync().first { $0.kind == .meeting })
        record.isDeleted = true
        record.updatedAt = Date().addingTimeInterval(60)
        _ = try meetings.upsertSyncedTextRecords([record])
        #expect(try chat.turns(sessionID: session.id).first?.originalAnswer == nil)
        #expect(try chat.turns(sessionID: session.id).first?.state == .sourceDeleted)
    }

    @Test func stopBetweenEvidenceAndWritingCannotReviveTurn() throws {
        let (_, chat, id) = try fixture()
        let (session, turn, _) = try pending(chat, id)
        try chat.setTurnState(id: turn.id, state: .stopped)
        try chat.setTurnState(id: turn.id, state: .writing)
        #expect(try chat.turns(sessionID: session.id).first?.state == .stopped)
    }
}
