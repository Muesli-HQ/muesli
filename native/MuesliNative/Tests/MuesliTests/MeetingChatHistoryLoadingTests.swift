import Foundation
import Observation
import SQLite3
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

/// Chat navigation publishes selection immediately and reads history on the worker. These
/// tests hold the SQLite writer lock so the worker is busy, then check that the main actor
/// stays responsive and that late reads cannot override newer navigation.
@MainActor
@Suite("Meeting chat history loading", .serialized)
struct MeetingChatHistoryLoadingTests {
    private func fixture() async throws -> (DictationStore, MeetingChatCoordinator, first: UUID, second: UUID) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-history-loading-\(UUID()).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        _ = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Launch Friday", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        let coordinator = MeetingChatCoordinator(databaseURL: url, generator: HistoryLoadingProbe())
        await coordinator.waitForIdle()
        let first = try coordinator.store.createSession(scope: .init(), title: "First chat")
        _ = try coordinator.store.beginTurn(sessionID: first.id, question: "Question in first", scope: .init(), provider: "test", model: "test")
        let second = try coordinator.store.createSession(scope: .init(), title: "Second chat")
        _ = try coordinator.store.beginTurn(sessionID: second.id, question: "Question in second", scope: .init(), provider: "test", model: "test")
        coordinator.reload()
        return (store, coordinator, first.id, second.id)
    }

    /// Occupies the worker with a write blocked behind an external transaction.
    private func occupyWorker(_ coordinator: MeetingChatCoordinator, store: DictationStore, renaming id: UUID) async throws -> (OpaquePointer?, Task<Void, Never>) {
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let writer = Task { await coordinator.renameChat(id: id, title: "Renamed while busy") }
        for _ in 0..<100 where coordinator.pendingChatMutations[id] == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.pendingChatMutations[id] == .renaming)
        // Give the worker time to enter the blocked write before navigation is queued.
        try await Task.sleep(for: .milliseconds(50))
        return (db, writer)
    }

    @Test func navigationIsImmediateAndOnlyTheLatestSelectionPublishes() async throws {
        let (store, coordinator, first, second) = try await fixture()
        let (db, writer) = try await occupyWorker(coordinator, store: store, renaming: first)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }

        let clock = ContinuousClock(); let start = clock.now
        coordinator.selectChat(id: second)
        #expect(start.duration(to: clock.now) < .milliseconds(500))
        #expect(coordinator.selectedSessionID == second)
        #expect(coordinator.isLoadingConversation)
        #expect(coordinator.turns.isEmpty)

        coordinator.composerDraft = "Draft for second"
        coordinator.selectChat(id: first)
        coordinator.composerDraft = "Draft for first"
        coordinator.selectChat(id: second)
        #expect(start.duration(to: clock.now) < .milliseconds(500))

        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        await writer.value
        await coordinator.waitForIdle()

        // Earlier reads for the first chat finished after newer navigation and were discarded.
        #expect(coordinator.selectedSessionID == second)
        #expect(!coordinator.isLoadingConversation)
        #expect(coordinator.turns.map(\.question) == ["Question in second"])
        #expect(coordinator.composerDraft == "Draft for second")
        coordinator.selectChat(id: first)
        #expect(coordinator.composerDraft == "Draft for first")
        await coordinator.waitForIdle()
        #expect(coordinator.turns.map(\.question) == ["Question in first"])
    }

    @Test func returningToTheIndexIsNotRevertedByALateConversationRead() async throws {
        let (store, coordinator, first, second) = try await fixture()
        let (db, writer) = try await occupyWorker(coordinator, store: store, renaming: second)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }

        coordinator.selectChat(id: first)
        coordinator.showIndex()
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        await writer.value
        await coordinator.waitForIdle()

        #expect(coordinator.selectedSessionID == nil)
        #expect(coordinator.turns.isEmpty)
        #expect(!coordinator.isLoadingConversation)
        #expect(Set(coordinator.sessions.map(\.id)) == [first, second])
    }

    @Test func pendingDeletionIgnoresRepeatsAndCannotBeReopened() async throws {
        let (store, coordinator, first, second) = try await fixture()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let deletion = Task { await coordinator.deleteChat(id: first) }
        for _ in 0..<100 where coordinator.pendingChatMutations[first] == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.pendingChatMutations[first] == .deleting)

        let clock = ContinuousClock(); let start = clock.now
        await coordinator.deleteChat(id: first)
        await coordinator.renameChat(id: first, title: "Too late")
        #expect(start.duration(to: clock.now) < .seconds(1))
        coordinator.selectChat(id: first)
        #expect(coordinator.selectedSessionID == nil)

        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        await deletion.value
        await coordinator.waitForIdle()
        #expect(coordinator.pendingChatMutations.isEmpty)
        #expect(coordinator.sessions.map(\.id) == [second])
        #expect(try coordinator.store.sessions().map(\.id) == [second])
    }

    @Test(arguments: [false, true])
    func emptySelectionFollowUpIsCheckedAgainstStorageWhileHistoryLoads(completedAnswer: Bool) async throws {
        let (store, coordinator, first, _) = try await fixture()
        if completedAnswer {
            let turn = try #require(coordinator.store.turns(sessionID: first).first)
            #expect(try coordinator.store.finishTurn(turnID: turn.id, answer: "Previous answer", citations: [], dependencies: []))
        }
        try coordinator.store.updateSession(id: first, title: nil, scope: .init(selection: .meetings([])))
        coordinator.reload()
        let (db, writer) = try await occupyWorker(coordinator, store: store, renaming: first)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }

        coordinator.selectChat(id: first)
        #expect(coordinator.isLoadingConversation)
        coordinator.composerDraft = "Next steps?"
        let request = Task { await coordinator.send(question: "Next steps?", config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        // The request is reserved before the storage check, so a second send cannot race it.
        #expect(coordinator.isBusy)

        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        await writer.value
        await request.value
        await coordinator.waitForIdle()
        #expect(!coordinator.isBusy)
        if completedAnswer {
            #expect(coordinator.errorMessage?.contains("Attach a meeting") != true)
            let turns = try coordinator.store.turns(sessionID: first)
            #expect(turns.count == 2)
            #expect(turns.last?.scope.selection == .meetings([]))
        } else {
            #expect(coordinator.errorMessage?.contains("Attach a meeting") == true)
            #expect(coordinator.composerDraft == "Next steps?")
            #expect(try coordinator.store.turns(sessionID: first).count == 1)
        }
    }
    @Test func unreadableFollowUpHistoryPreservesDraftAndReportsReadFailure() async throws {
        let (store, coordinator, first, _) = try await fixture()
        try coordinator.store.updateSession(id: first, title: nil, scope: .init(selection: .meetings([])))
        coordinator.reload()
        let (db, writer) = try await occupyWorker(coordinator, store: store, renaming: first)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        coordinator.selectChat(id: first)
        coordinator.composerDraft = "Explain that answer"
        let send = Task { await coordinator.send(question: "Explain that answer", config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isBusy)
        // Deliberately corrupt only this synthetic fixture after the worker is
        // queued, so the storage read throws rather than reporting empty history.
        #expect(sqlite3_exec(db, "UPDATE meeting_chat_turns SET body='{}'", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK)
        await writer.value
        await send.value
        await coordinator.waitForIdle()
        #expect(!coordinator.isBusy)
        #expect(coordinator.composerDraft == "Explain that answer")
        // The concurrent history refresh can also publish its read error.
        #expect(["Could not load meeting chat history.",
                 "Could not read this chat’s previous answers. Please retry. Your question is still in the composer."]
            .contains(coordinator.errorMessage ?? ""))
        #expect(coordinator.errorMessage?.contains("Attach a meeting") != true)
        // A failed history publication must not make a retry look like loaded,
        // empty history and replace the read error with an attachment warning.
        await coordinator.send(question: "Explain that answer", config: AppConfig())
        #expect(coordinator.errorMessage?.contains("Could not read") == true)
        #expect(coordinator.composerDraft == "Explain that answer")
        coordinator.startDraft(scope: .init(selection: .meetings([])))
        await coordinator.send(question: "New question", config: AppConfig())
        #expect(coordinator.selectedSessionID == nil)
        #expect(coordinator.errorMessage?.contains("Attach a meeting") == true)
    }

    @Test func stopDuringPostSendHistoryPublicationCannotRelaunchTheRequest() async throws {
        let (_, coordinator, first, _) = try await fixture()
        coordinator.selectChat(id: first)
        await coordinator.waitForIdle()
        coordinator.composerDraft = "Summarize the launch"
        withObservationTracking {
            _ = coordinator.turns
        } onChange: {
            MainActor.assumeIsolated { coordinator.stop() }
        }
        await coordinator.send(question: "Summarize the launch", config: AppConfig())
        await coordinator.waitForIdle()
        #expect(!coordinator.isBusy)
        let turns = try coordinator.store.turns(sessionID: first)
        #expect(turns.count == 2)
        #expect(turns.last?.state == .stopped)
    }

}

private actor HistoryLoadingProbe: MeetingTextGenerating {
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        #"{"status":"answered","markdown":"Launch Friday [[S1]]"}"#
    }
}
