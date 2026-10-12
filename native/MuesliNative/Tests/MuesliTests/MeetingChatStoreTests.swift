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
    @Test func anchorSurvivesScopeChangesAndDeletionDetachesThread() throws {
        let (meetings, chat, id) = try fixture()
        let session = try chat.createSession(scope: .init(selection: .meetings([id])), title: "Planning")
        #expect(session.anchorMeetingID == id)
        try chat.updateSession(id: session.id, title: nil, scope: .init(selection: .meetings([])))
        #expect(try chat.sessions(meetingID: id).map(\.id) == [session.id])
        #expect(try chat.sessions().first?.anchorMeetingID == id)
        #expect(try chat.sourceSnapshots(scope: .init(selection: .meetings([]))).isEmpty)
        try meetings.deleteMeeting(id: id)
        #expect(try chat.sessions(meetingID: id).isEmpty)
        #expect(try chat.sessions().first?.anchorMeetingID == nil)
        #expect(try chat.sessions().count == 1)
    }

    @Test func scopeMembershipCanCoverMultipleMeetingsWithoutInventingAnchor() throws {
        let (meetings, chat, id) = try fixture()
        let second = try meetings.insertMeeting(title: "Review", calendarEventID: nil,
            startTime: Date(), endTime: Date(), rawTranscript: "Review launch.", formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil)
        let session = try chat.createSession(scope: .init(selection: .meetings([id, second])), title: "Launch")
        #expect(session.anchorMeetingID == nil)
        #expect(try chat.sessions(meetingID: id).map(\.id) == [session.id])
        #expect(try chat.sessions(meetingID: second).map(\.id) == [session.id])
        try chat.updateSession(id: session.id, title: nil, scope: .init(selection: .meetings([second])))
        #expect(try chat.sessions(meetingID: id).isEmpty)
        #expect(try chat.sessions(meetingID: second).count == 1)
    }

    @Test func dependenciesAddedAtCompletionArePersistedForDeletion() throws {
        let (meetings, chat, id) = try fixture()
        let session = try chat.createSession(scope: .init(), title: "Launch")
        let turn = try chat.beginTurn(sessionID: session.id, question: "When?", scope: .init(), provider: "test", model: "test")
        let source = try #require(chat.sourceSnapshots(scope: .init()).first)
        let dependency = MeetingChatDependency(meetingID: id, revision: source.revision)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: [dependency]))
        #expect(try chat.dependencies(turnID: turn.id) == [dependency])
        #expect(try chat.sessions(meetingID: id).map(\.id) == [session.id])
        try meetings.deleteMeeting(id: id)
        #expect(try chat.turns(sessionID: session.id).first?.state == .sourceDeleted)
    }

    @Test func attachingMoreEvidenceRetainsPreviouslyConsultedSources() throws {
        let (meetings, chat, id) = try fixture()
        let (session, turn, dependencies) = try pending(chat, id)
        try chat.attachEvidence(turnID: turn.id, dependencies: [])
        #expect(try chat.dependencies(turnID: turn.id) == dependencies)
        try meetings.deleteMeeting(id: id)
        #expect(try chat.turns(sessionID: session.id).first?.state == .sourceDeleted)
    }

    @Test func legacySessionMembershipBackfillsOnlyOnce() throws {
        let (meetings, chat, id) = try fixture()
        let session = try chat.createSession(scope: .init(selection: .meetings([id])), title: "Legacy")
        try meetings.withChatDatabase { db in
            try MeetingChatSQL.execute("DELETE FROM meeting_chat_session_meetings", db: db)
            try MeetingChatSQL.execute("DELETE FROM local_migrations WHERE identifier='meeting_chat_session_meetings_v1'", db: db)
            try MeetingChatSQL.execute("UPDATE meeting_chat_sessions SET body=json_remove(body,'$.anchorMeetingID')", db: db)
            try MeetingChatSQL.migrate(db: db)
        }
        #expect(try chat.sessions().first?.anchorMeetingID == id)
        #expect(try chat.sessions(meetingID: id).map(\.id) == [session.id])
        try meetings.withChatDatabase { db in
            try MeetingChatSQL.execute("DELETE FROM meeting_chat_session_meetings", db: db)
            try MeetingChatSQL.migrate(db: db)
        }
        #expect(try chat.sessions(meetingID: id).isEmpty)
    }

    @Test func citationSourcesCannotBypassDeletionTracking() throws {
        let (meetings, chat, id) = try fixture()
        let session = try chat.createSession(scope: .init(), title: "Launch")
        let turn = try chat.beginTurn(sessionID: session.id, question: "When?", scope: .init(), provider: "test", model: "test")
        let source = try #require(chat.sourceSnapshots(scope: .init()).first)
        let citation = MeetingChatCitation(sourceKey: "S1", meetingID: id, title: source.title,
            startDate: source.startDate, kind: .transcript, excerpt: "Ship Friday",
            range: .init(location: 0, length: 11), revision: source.revision)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday [S1]", citations: [citation], dependencies: []))
        #expect(try chat.dependencies(turnID: turn.id).map(\.meetingID) == [id])
        try meetings.deleteMeeting(id: id)
        #expect(try chat.turns(sessionID: session.id).first?.originalAnswer == nil)
    }

    @Test func automaticTitleCommitIsGuardedByNewestAttemptAndManualRename() throws {
        let (_, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        let attempt = try #require(turn.attemptID)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: UUID(), title: "Wrong attempt") == false)
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: attempt, title: "Launch timeline"))
        #expect(try chat.sessions().first?.generatedTitleTurnID == turn.id)
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: attempt, title: "Duplicate result") == false)
        try chat.updateSession(id: session.id, title: "My project", scope: nil)
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: attempt, title: "Late generated title") == false)
        #expect(try chat.sessions().first?.title == "My project")
    }

    @Test func automaticTitleCannotOverwriteManualRenameBeforeFirstResult() throws {
        let (_, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        try chat.updateSession(id: session.id, title: "Keep my title", scope: nil)
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: try #require(turn.attemptID), title: "Generated") == false)
        #expect(try chat.sessions().first?.title == "Keep my title")
    }

    @Test func newerTurnOrScopeChangeRejectsLateAutomaticTitle() throws {
        let (_, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        try chat.updateSession(id: session.id, title: nil, scope: .init(selection: .meetings([id])))
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: try #require(turn.attemptID), title: "Old scope") == false)
        try chat.updateSession(id: session.id, title: nil, scope: .init())
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: try #require(turn.attemptID), title: "Returned scope") == false)
        let newer = try chat.beginTurn(sessionID: session.id, question: "What next?", scope: .init(), provider: "test", model: "test")
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: try #require(turn.attemptID), title: "Old conversation") == false)
        #expect(try chat.updateTitleIfAutomatic(turnID: newer.id, attemptID: try #require(newer.attemptID), title: "Still pending") == false)
    }

    @Test func deletingSourceScrubsCommittedGeneratedTitleAndRejectsLateReply() throws {
        let (meetings, chat, id) = try fixture()
        let (_, turn, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        let attempt = try #require(turn.attemptID)
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: attempt, title: "Confidential launch Friday"))
        try meetings.deleteMeeting(id: id)
        #expect(try chat.sessions().first?.title == "New chat")
        #expect(try chat.sessions().first?.generatedTitleTurnID == nil)
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: attempt, title: "Late confidential title") == false)
    }

    @Test func hardDeletionAndEditsScrubGeneratedTitleButPreserveManualTitle() throws {
        for hardDelete in [false, true] {
            let (meetings, chat, id) = try fixture()
            let (_, turn, deps) = try pending(chat, id)
            #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
            #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: try #require(turn.attemptID), title: "Private launch"))
            if hardDelete {
                try meetings.withChatDatabase { db in try MeetingChatSQL.execute("DELETE FROM meetings WHERE id=?", [.integer(id)], db: db) }
            } else { try meetings.updateMeetingNotes(id: id, formattedNotes: "Changed") }
            #expect(try chat.sessions().first?.title == "New chat")
        }
        let (meetings, chat, id) = try fixture()
        let (session, turn, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: deps))
        #expect(try chat.updateTitleIfAutomatic(turnID: turn.id, attemptID: try #require(turn.attemptID), title: "Launch"))
        try chat.updateSession(id: session.id, title: "My title", scope: nil)
        try meetings.deleteMeeting(id: id)
        #expect(try chat.sessions().first?.title == "My title")
    }

    @Test func automaticTitleMigrationRecognizesOnlyLegacyDefaults() throws {
        let (meetings, chat, id) = try fixture()
        let (session, _, _) = try pending(chat, id)
        let custom = try chat.createSession(scope: .init(), title: "Custom project name")
        try meetings.withChatDatabase { db in
            try MeetingChatSQL.execute("UPDATE meeting_chat_sessions SET body=json_remove(body,'$.titleIsAutomatic')", db: db)
            try MeetingChatSQL.execute("DELETE FROM local_migrations WHERE identifier='meeting_chat_automatic_titles_v1'", db: db)
            try MeetingChatSQL.migrate(db: db)
        }
        let sessions = try chat.sessions()
        #expect(sessions.first { $0.id == session.id }?.titleIsAutomatic == true)
        #expect(sessions.first { $0.id == custom.id }?.titleIsAutomatic == nil)
    }

    @Test func pickerFindsNewMeetingsWithoutPreparingRetrievalIndex() throws {
        let (meetings, chat, id) = try fixture()
        #expect(try chat.sourceChoices().map(\.id) == [id])
        try meetings.withChatDatabase { db in
            let count = try MeetingChatSQL.rows("SELECT COUNT(*) FROM meeting_chat_index_state", db: db) { sqlite3_column_int64($0, 0) }.first
            #expect(count == 0)
        }
        let second = try meetings.insertMeeting(title: "New meeting", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "Fresh evidence", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        #expect(try chat.sourceChoices().map(\.id) == [second, id])
        try meetings.deleteMeeting(id: second)
        #expect(try chat.sourceChoices().map(\.id) == [id])
    }

    @Test func pickerExcludesUnavailableSourcesAndFailureNotesWithoutIndex() throws {
        let (meetings, chat, id) = try fixture()
        try meetings.withChatDatabase { db in
            try MeetingChatSQL.execute("UPDATE meetings SET raw_transcript=?,manual_notes='',formatted_notes='## Summary failed: retry' WHERE id=?", [.text(" \n\t\u{00A0}"), .integer(id)], db: db)
        }
        #expect(try chat.sourceChoices().isEmpty)
        try meetings.updateMeetingManualNotes(id: id, manualNotes: "Written notes are evidence")
        #expect(try chat.sourceChoices().map(\.id) == [id])
        try meetings.withChatDatabase { db in
            try MeetingChatSQL.execute("UPDATE meetings SET meeting_status='recording' WHERE id=?", [.integer(id)], db: db)
        }
        #expect(try chat.sourceChoices().isEmpty)
    }

    @Test func historySurvivesScopeChangesWithoutReturningOldSourceExcerpts() throws {
        let (_, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Friday [[S1]]", citations: [], dependencies: deps))
        for selection in [MeetingChatSelection.meetings([id]), .meetings([]), .all] {
            try chat.updateSession(id: session.id, title: nil, scope: .init(selection: selection))
            let next = try chat.beginTurn(sessionID: session.id, question: "Make it shorter", scope: .init(selection: selection), provider: "test", model: "test")
            let context = try chat.historyContext(before: next)
            #expect(context.turns.map(\.id) == [first.id])
            #expect(context.dependencies == deps)
            #expect(context.turns.allSatisfy { $0.citations.isEmpty })
            #expect(!MeetingChatHistory.promptBlock(context.turns[0]).contains("[[S1]]"))
        }
    }

    @Test func conversationalFollowupInheritsDeletionDependencies() throws {
        let (meetings, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Friday", citations: [], dependencies: deps))
        try chat.updateSession(id: session.id, title: nil, scope: .init(selection: .meetings([])))
        let next = try chat.beginTurn(sessionID: session.id, question: "Use a table", scope: .init(selection: .meetings([])), provider: "test", model: "test")
        let context = try chat.historyContext(before: next)
        try chat.attachEvidence(turnID: next.id, dependencies: context.dependencies)
        #expect(try chat.finishTurn(turnID: next.id, answer: "| Date |\n| --- |\n| Friday |", citations: [], dependencies: context.dependencies))
        try meetings.deleteMeeting(id: id)
        #expect(try chat.turns(sessionID: session.id).allSatisfy { $0.state == .sourceDeleted })
    }

    @Test func historyExcludesEditedAndDeletedSourceAnswersButKeepsSourceFreeConversation() throws {
        let (meetings, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Friday", citations: [], dependencies: deps))
        try meetings.updateMeetingNotes(id: id, formattedNotes: "Now Monday")
        let second = try chat.beginTurn(sessionID: session.id, question: "Hello", scope: .init(), provider: "test", model: "test")
        #expect(try chat.historyContext(before: second).turns.isEmpty)
        #expect(try chat.finishTurn(turnID: second.id, answer: "Hello!", citations: [], dependencies: []))
        try meetings.deleteMeeting(id: id)
        let third = try chat.beginTurn(sessionID: session.id, question: "Thanks", scope: .init(selection: .meetings([])), provider: "test", model: "test")
        let context = try chat.historyContext(before: third)
        #expect(context.turns.map(\.id) == [second.id])
        #expect(context.dependencies.isEmpty)
    }

    @Test func longLatestHistoryIsCompleteForCallerManagedCompaction() throws {
        let (_, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: String(repeating: "🌻", count: 2_000) + " [[S999]]", citations: [], dependencies: deps))
        let next = try chat.beginTurn(sessionID: session.id, question: "Shorten it", scope: .init(), provider: "test", model: "test")
        let context = try chat.historyContext(before: next)
        #expect(context.turns.map(\.id) == [first.id])
        let block = MeetingChatHistory.promptBlock(context.turns[0])
        #expect(block.utf8.count > 4_000)
        #expect(!block.contains("[truncated]"))
        #expect(!block.contains("[[S999]]"))
    }

    @Test func rollingSummaryRoundTripsAndValidatesExactCoveredPrefix() throws {
        let (_, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Launch Friday", citations: [], dependencies: deps))
        let request = try chat.beginTurn(sessionID: session.id, question: "Continue", scope: .init(), provider: "test", model: "test")
        let context = try chat.historyContext(before: request)
        #expect(try chat.saveRollingSummary(text: "Launch is planned for Friday.", coveredTurns: context.turns, for: request))
        let saved = try chat.rollingSummary(before: request)
        let summary = try #require(saved)
        #expect(summary.throughOrdinal == first.ordinal)
        #expect(summary.dependencies == deps)
        #expect(summary.text == "Launch is planned for Friday.")
        _ = try chat.restartTurn(id: first.id, provider: "test", model: "test")
        #expect(try chat.rollingSummary(before: request) == nil)
        #expect(try chat.sessions().first?.rollingSummary == nil)
        #expect(try chat.saveRollingSummary(text: "Late old summary", coveredTurns: context.turns, for: request) == false)
    }

    @Test func rollingSummaryCannotCommitAfterStopOrPartialPrefix() throws {
        let (_, chat, id) = try fixture()
        let (session, first, deps) = try pending(chat, id)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Friday", citations: [], dependencies: deps))
        let second = try chat.beginTurn(sessionID: session.id, question: "Greeting", scope: .init(), provider: "test", model: "test")
        #expect(try chat.finishTurn(turnID: second.id, answer: "Hello", citations: [], dependencies: []))
        let request = try chat.beginTurn(sessionID: session.id, question: "Next", scope: .init(), provider: "test", model: "test")
        let context = try chat.historyContext(before: request)
        #expect(try chat.saveRollingSummary(text: "Skipped first turn", coveredTurns: Array(context.turns.suffix(1)), for: request) == false)
        try chat.setTurnState(id: request.id, state: .stopped)
        #expect(try chat.saveRollingSummary(text: "Late summary", coveredTurns: context.turns, for: request) == false)
    }

    @Test func sourceDeletionAndEditScrubPersistedRollingSummary() throws {
        for operation in ["soft", "hard", "edit"] {
            let (meetings, chat, id) = try fixture()
            let (session, first, deps) = try pending(chat, id)
            #expect(try chat.finishTurn(turnID: first.id, answer: "Secret Friday launch", citations: [], dependencies: deps))
            let request = try chat.beginTurn(sessionID: session.id, question: "Next", scope: .init(), provider: "test", model: "test")
            let context = try chat.historyContext(before: request)
            #expect(try chat.saveRollingSummary(text: "Private launch recap", coveredTurns: context.turns, for: request))
            if operation == "soft" { try meetings.deleteMeeting(id: id) }
            else if operation == "edit" { try meetings.updateMeetingNotes(id: id, formattedNotes: "Changed decision") }
            else { try meetings.withChatDatabase { db in try MeetingChatSQL.execute("DELETE FROM meetings WHERE id=?", [.integer(id)], db: db) } }
            // Inspect persisted storage directly: validation alone must not leave private derived text behind.
            #expect(try chat.sessions().first?.rollingSummary == nil)
            #expect(try chat.rollingSummary(before: request) == nil)
            #expect(try chat.saveRollingSummary(text: "Late private recap", coveredTurns: context.turns, for: request) == false)
        }
    }

    @Test func historyIncludesMoreThanFiftyFullExchangesByDefault() throws {
        let (_, chat, _) = try fixture()
        let session = try chat.createSession(scope: .init(), title: "Long discussion")
        for index in 0..<55 {
            let turn = try chat.beginTurn(sessionID: session.id, question: "Question \(index)", scope: .init(), provider: "test", model: "test")
            #expect(try chat.finishTurn(turnID: turn.id, answer: String(repeating: "Detail ", count: 100), citations: [], dependencies: []))
        }
        let request = try chat.beginTurn(sessionID: session.id, question: "Recap", scope: .init(), provider: "test", model: "test")
        let context = try chat.historyContext(before: request)
        #expect(context.turns.count == 55)
        #expect(context.turns.first?.ordinal == 0)
        #expect(context.turns.reduce(0) { $0 + MeetingChatHistory.promptBlock($1).utf8.count } > 4_000)
    }

    @Test func summaryParticipantTriggersUpgradeAndInvalidateBothSidesOfReassignment() throws {
        let (meetings, chat, firstID) = try fixture()
        let secondID = try meetings.insertMeeting(title: "Review", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "Review Friday", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        try meetings.withChatDatabase { db in
            try MeetingChatSQL.execute("INSERT INTO meeting_participants(meeting_id,participant_identifier,display_name,insertion_order) VALUES(?,'person','Taylor',0)", [.integer(firstID)], db: db)
        }
        for id in [firstID, secondID] {
            let (session, first, deps) = try pending(chat, id)
            #expect(try chat.finishTurn(turnID: first.id, answer: "Discussion", citations: [], dependencies: deps))
            let request = try chat.beginTurn(sessionID: session.id, question: "Next", scope: .init(), provider: "test", model: "test")
            let context = try chat.historyContext(before: request)
            #expect(try chat.saveRollingSummary(text: "Participant discussion", coveredTurns: context.turns, for: request))
        }
        try meetings.withChatDatabase { db in
            // Simulate an installed schema with the old participant triggers but
            // without the newly introduced, independently named summary triggers.
            for suffix in ["inserted", "edited", "removed"] {
                try MeetingChatSQL.execute("DROP TRIGGER meeting_chat_rolling_summary_participant_\(suffix)", db: db)
            }
            try MeetingChatSQL.migrate(db: db)
            try MeetingChatSQL.execute("UPDATE meeting_participants SET meeting_id=? WHERE meeting_id=? AND participant_identifier='person'", [.integer(secondID), .integer(firstID)], db: db)
        }
        #expect(try chat.sessions().count == 2)
        #expect(try chat.sessions().allSatisfy { $0.rollingSummary == nil })
    }

    @Test func retryOlderUncompletedTurnCanCompactBeforeALaterSavedSummary() throws {
        for state in [MeetingChatTurnState.failed, .stopped] {
            let (_, chat, id) = try fixture()
            let (session, first, deps) = try pending(chat, id)
            #expect(try chat.finishTurn(turnID: first.id, answer: String(repeating: "Earlier context. ", count: 400), citations: [], dependencies: deps))
            let older = try chat.beginTurn(sessionID: session.id, question: "Retry this later", scope: .init(), provider: "test", model: "test")
            try chat.setTurnState(id: older.id, state: state)
            let later = try chat.beginTurn(sessionID: session.id, question: "Later question", scope: .init(), provider: "test", model: "test")
            #expect(try chat.finishTurn(turnID: later.id, answer: "Later answer", citations: [], dependencies: []))
            let newest = try chat.beginTurn(sessionID: session.id, question: "Summarize", scope: .init(), provider: "test", model: "test")
            let laterContext = try chat.historyContext(before: newest)
            #expect(try chat.saveRollingSummary(text: "Later conversation memory", coveredTurns: laterContext.turns, for: newest))
            #expect(try chat.sessions().first?.rollingSummary?.throughOrdinal == later.ordinal)
            try chat.setTurnState(id: newest.id, state: .stopped)

            let retry = try #require(try chat.restartTurn(id: older.id, provider: "test", model: "test"))
            #expect(retry.attemptID != older.attemptID)
            #expect(try chat.rollingSummary(before: retry) == nil)
            #expect(try chat.sessions().first?.rollingSummary == nil)
            let retryContext = try chat.historyContext(before: retry)
            #expect(retryContext.turns.map(\.id) == [first.id])
            #expect(try chat.saveRollingSummary(text: "Earlier request memory", coveredTurns: retryContext.turns, for: retry))
            #expect(try chat.rollingSummary(before: retry)?.throughOrdinal == first.ordinal)
            // Clearing the derived cache preserves all later raw exchanges.
            #expect(try chat.turns(sessionID: session.id).first { $0.id == later.id }?.originalAnswer == "Later answer")
        }
    }

}
