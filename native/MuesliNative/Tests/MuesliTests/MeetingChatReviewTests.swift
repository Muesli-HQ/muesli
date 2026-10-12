import Foundation
import SQLite3
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat review regressions", .serialized)
struct MeetingChatReviewTests {
    @Test func providerFailuresGiveSafeActionableGuidance() {
        let rejected = MeetingChatCoordinator.failureMessage(ChatGPTResponsesError.backendFailed(statusCode: 400, message: "private server details"))
        #expect(rejected.contains("selected model"))
        #expect(!rejected.contains("private server details"))
        #expect(MeetingChatCoordinator.failureMessage(ChatGPTResponsesError.backendFailed(statusCode: 429, message: "private server details")).contains("usage or rate limit"))
        #expect(MeetingChatCoordinator.failureMessage(ChatGPTAuthError.refreshFailed("private server details")).contains("Sign in again"))
        #expect(MeetingChatCoordinator.failureMessage(URLError(.timedOut)).contains("timed out"))
    }
    private func fixture(generator: any MeetingTextGenerating = ReviewReplyProbe()) throws -> (DictationStore, MeetingChatCoordinator) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-review-\(UUID()).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        _ = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Launch Friday", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        return (store, MeetingChatCoordinator(databaseURL: url, generator: generator))
    }

    private func holdWriter(_ store: DictationStore, clearChatHistory: Bool = false) async -> (task: Task<Void, Error>, release: DispatchSemaphore) {
        let release = DispatchSemaphore(value: 0)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let writer = Task.detached {
            defer { continuation.finish() }
            try store.withChatDatabase { db in
                guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "test-lock", code: 1) }
                continuation.yield(())
                let progressed = release.wait(timeout: .now() + 10) == .success
                if clearChatHistory { try MeetingChatSQL.clear(db: db) }
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                guard progressed else { throw NSError(domain: "test-lock-timeout", code: 1) }
            }
        }
        for await _ in events.prefix(1) { break }
        return (writer, release)
    }

    @Test func switchingAndCreatingChatsPreservesEachUnsentQuestion() async throws {
        let (_, coordinator) = try fixture()
        await coordinator.createChat(scope: .init())
        let first = try #require(coordinator.selectedSessionID)
        coordinator.composerDraft = "First unsent question"
        await coordinator.createChat(scope: .init())
        let second = try #require(coordinator.selectedSessionID)
        #expect(coordinator.composerDraft.isEmpty)
        coordinator.composerDraft = "Second unsent question"
        coordinator.selectChat(id: first)
        #expect(coordinator.composerDraft == "First unsent question")
        coordinator.selectChat(id: second)
        #expect(coordinator.composerDraft == "Second unsent question")
        coordinator.selectChat(id: second)
        #expect(coordinator.composerDraft == "Second unsent question")
    }

    @Test func creatingChatDoesNotBlockMainActorBehindSQLiteWriter() async throws {
        let (store, coordinator) = try fixture()
        let release = DispatchSemaphore(value: 0)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let writer = Task.detached {
            defer { continuation.finish() }
            return try store.withChatDatabase { db in
                guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "test-lock", code: 1) }
                continuation.yield(())
                // A main-actor heartbeat releases the writer. The timeout only prevents
                // a broken implementation from deadlocking the test process.
                let progressed = release.wait(timeout: .now() + 10) == .success
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                return progressed
            }
        }
        for await _ in events.prefix(1) { break }
        var creationFinished = false
        let heartbeat = Task { @MainActor in
            #expect(!creationFinished)
            release.signal()
        }
        await coordinator.createChat(scope: .init())
        creationFinished = true
        await heartbeat.value
        #expect(try await writer.value)
        #expect(coordinator.selectedSessionID != nil)
    }

    @Test func stopWhileSavingDoesNotGenerateOrLoseComposerText() async throws {
        let probe = ReviewReplyProbe()
        let (store, coordinator) = try fixture(generator: probe)
        await coordinator.createChat(scope: .init())
        let session = try #require(coordinator.selectedSessionID)
        coordinator.composerDraft = "Launch?"
        let writer = await holdWriter(store)
        let request = Task { await coordinator.send(question: coordinator.composerDraft, config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isBusy)
        let start = Date()
        coordinator.stop()
        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(!coordinator.isBusy)
        writer.release.signal(); try await writer.task.value
        await request.value
        await coordinator.waitForIdle()
        let turns = try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).turns(sessionID: session)
        #expect(turns.first?.state == .stopped)
        #expect(turns.first?.originalAnswer == nil)
        #expect(await probe.calls == 0)
        #expect(coordinator.composerDraft == "Launch?")
    }

    @Test func pendingSendKeepsItsOwnerAndDoesNotClearNewTyping() async throws {
        let probe = ReviewReplyProbe()
        let (store, coordinator) = try fixture(generator: probe)
        await coordinator.createChat(scope: .init())
        let first = try #require(coordinator.selectedSessionID)
        coordinator.composerDraft = "Launch?"
        await coordinator.createChat(scope: .init())
        let second = try #require(coordinator.selectedSessionID)
        coordinator.composerDraft = "Second chat draft"
        coordinator.selectChat(id: first)
        let writer = await holdWriter(store)
        let request = Task { await coordinator.send(question: coordinator.composerDraft, config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        coordinator.composerDraft = "New text typed while saving"
        coordinator.selectChat(id: second)
        writer.release.signal(); try await writer.task.value
        await request.value
        await coordinator.waitForIdle()
        #expect(coordinator.selectedSessionID == second)
        #expect(coordinator.composerDraft == "Second chat draft")
        let turns = try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).turns(sessionID: first)
        #expect(turns.first?.question == "Launch?")
        #expect(turns.first?.state == .completed)
        coordinator.selectChat(id: first)
        #expect(coordinator.composerDraft == "New text typed while saving")
        #expect(await probe.calls == 1)
    }

    @Test func implicitChatCreationDoesNotSendIntoANewSelection() async throws {
        let (store, coordinator) = try fixture()
        // The writer lock must block chat creation, not startup recovery.
        await coordinator.waitForIdle()
        await coordinator.refreshChoices()
        let existing = try coordinator.store.createSession(scope: .init(), title: "Existing chat")
        coordinator.reload()
        coordinator.composerDraft = "Launch?"
        let writer = await holdWriter(store)
        let request = Task { await coordinator.send(question: coordinator.composerDraft, config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isUpdatingChat { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isUpdatingChat)
        coordinator.selectChat(id: existing.id)
        coordinator.composerDraft = "Existing chat draft"
        writer.release.signal(); try await writer.task.value
        await request.value
        await coordinator.waitForIdle()
        #expect(coordinator.selectedSessionID == existing.id)
        #expect(coordinator.composerDraft == "Existing chat draft")
        #expect(coordinator.sessions.first(where: { $0.id == existing.id })?.title == "Existing chat")
        #expect(try coordinator.store.turns(sessionID: existing.id).isEmpty)
        let created = try #require(coordinator.sessions.first(where: { $0.id != existing.id }))
        #expect(try coordinator.store.turns(sessionID: created.id).first?.question == "Launch?")
        #expect(try coordinator.store.turns(sessionID: created.id).first?.state == .completed)
    }

    @Test func delayedWeeklyPromptDoesNotOverwriteANewSelection() async throws {
        let (store, coordinator) = try fixture()
        await coordinator.refreshChoices()
        let existing = try coordinator.store.createSession(scope: .init(), title: "Existing chat")
        coordinator.reload()
        let prompt = MeetingChatQuickAction.weeklyRecap.prepare(scope: .init(), now: Date(), calendar: .current, userDisplayName: nil)
        let writer = await holdWriter(store)
        let preparation = Task { await coordinator.applyPreparedPrompt(prompt) }
        for _ in 0..<100 where !coordinator.isUpdatingChat { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isUpdatingChat)
        coordinator.selectChat(id: existing.id)
        coordinator.composerDraft = "Existing chat draft"
        writer.release.signal(); try await writer.task.value
        #expect(await preparation.value == false)
        #expect(coordinator.selectedSessionID == existing.id)
        #expect(coordinator.composerDraft == "Existing chat draft")
        #expect(coordinator.scope == existing.scope)
    }

    @Test(arguments: [false, true]) func delayedPreparedPromptPreservesTyping(existingChat: Bool) async throws {
        let (store, coordinator) = try fixture()
        await coordinator.waitForIdle()
        await coordinator.refreshChoices()
        if existingChat { await coordinator.createChat(scope: .init()) }
        coordinator.composerDraft = "Original draft"
        let prompt = MeetingChatQuickAction.weeklyRecap.prepare(scope: .init(), now: Date(), calendar: .current, userDisplayName: nil)
        let writer = await holdWriter(store)
        let preparation = Task { await coordinator.applyPreparedPrompt(prompt) }
        for _ in 0..<100 where !coordinator.isUpdatingChat { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isUpdatingChat)
        coordinator.composerDraft = "My newer question"
        writer.release.signal(); try await writer.task.value
        #expect(await preparation.value == false)
        #expect(coordinator.composerDraft == "My newer question")
    }

    @Test func queuedImplicitCreationCannotRecreateWipedHistory() async throws {
        let probe = ReviewReplyProbe()
        let (store, coordinator) = try fixture(generator: probe)
        await coordinator.waitForIdle()
        await coordinator.refreshChoices()
        coordinator.composerDraft = "Launch?"
        // The wipe owns the writer transaction first. Session creation is queued
        // behind it and must validate its original version after obtaining the lock.
        let writer = await holdWriter(store, clearChatHistory: true)
        let request = Task { await coordinator.send(question: coordinator.composerDraft, config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isUpdatingChat { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isUpdatingChat)
        writer.release.signal(); try await writer.task.value
        await request.value
        coordinator.refreshForSourceChanges()
        await coordinator.waitForIdle()
        #expect(!coordinator.isBusy)
        #expect(coordinator.sessions.isEmpty)
        #expect(try coordinator.store.sessions().isEmpty)
        #expect(await probe.calls == 0)
    }

    @Test func stoppedImplicitCreationKeepsTextTypedWhileSaving() async throws {
        let probe = ReviewReplyProbe()
        let (store, coordinator) = try fixture(generator: probe)
        await coordinator.waitForIdle()
        await coordinator.refreshChoices()
        coordinator.composerDraft = "Launch?"
        let writer = await holdWriter(store)
        let request = Task { await coordinator.send(question: coordinator.composerDraft, config: AppConfig()) }
        for _ in 0..<100 where !coordinator.isUpdatingChat { try await Task.sleep(for: .milliseconds(2)) }
        #expect(coordinator.isUpdatingChat)
        coordinator.composerDraft = "New text typed while saving"
        coordinator.stop()
        writer.release.signal(); try await writer.task.value
        await request.value
        await coordinator.waitForIdle()
        let session = try #require(coordinator.selectedSessionID)
        #expect(coordinator.composerDraft == "New text typed while saving")
        #expect(try coordinator.store.turns(sessionID: session).isEmpty)
        #expect(await probe.calls == 0)
    }
    @Test func emptyScopeNewAndRetriedFollowupsUseHistoryWithoutRebuildingIndex() async throws {
        for retry in [false, true] {
            let probe = ConversationHistoryProbe()
            let (meetings, coordinator) = try fixture(generator: probe)
            await coordinator.waitForIdle()
            await coordinator.createChat(scope: .init())
            let session = try #require(coordinator.selectedSessionID)
            let source = try #require(coordinator.store.sourceSnapshots(scope: .init()).first)
            let first = try coordinator.store.beginTurn(sessionID: session, question: "When is launch?", scope: .init(), provider: "test", model: "test")
            let deps = [MeetingChatDependency(meetingID: source.meetingID, revision: source.revision)]
            try coordinator.store.attachEvidence(turnID: first.id, dependencies: deps)
            #expect(try coordinator.store.finishTurn(turnID: first.id, answer: "Launch Friday [[S1]]", citations: [], dependencies: deps))
            await coordinator.setScope(.init(selection: .meetings([])))
            if retry {
                let interrupted = try coordinator.store.beginTurn(sessionID: session, question: "Put it in a table", scope: coordinator.scope, provider: "test", model: "test")
                try coordinator.store.setTurnState(id: interrupted.id, state: .interrupted)
                coordinator.reload()
                await coordinator.retry(turnID: interrupted.id, config: AppConfig())
            } else {
                await coordinator.send(question: "Put it in a table", config: AppConfig())
            }
            await coordinator.waitForIdle()
            #expect(await probe.calls == 1)
            let prompt = try #require(await probe.lastUser)
            #expect(prompt.contains("Launch Friday"))
            #expect(!prompt.contains("[[S1]]"))
            #expect(!prompt.contains("\"excerpt\""))
            let saved = try #require(coordinator.store.turns(sessionID: session).last)
            #expect(saved.state == .completed)
            #expect(saved.citations.isEmpty)
            #expect(try coordinator.store.dependencies(turnID: saved.id) == deps)
            try meetings.withChatDatabase { db in
                let count = try MeetingChatSQL.rows("SELECT COUNT(*) FROM meeting_chat_index_state", db: db) { sqlite3_column_int64($0, 0) }.first
                #expect(count == 0)
            }
            try meetings.deleteMeeting(id: source.meetingID)
            #expect(try coordinator.store.turns(sessionID: session).last?.state == .sourceDeleted)
        }
    }

    @Test func toolCardsExposeResultsAndReasoningStopsStreamingAfterCompletion() async throws {
        let (_, coordinator) = try fixture(generator: ToolPresentationProbe())
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init())
        await coordinator.send(question: "Review launch context", config: AppConfig())
        await coordinator.waitForIdle()
        let activity = try #require(coordinator.activities.first)
        #expect(activity.state == .completed)
        #expect(activity.output?.contains("passages returned") == true)
        #expect(activity.error == nil)
        #expect(coordinator.reasoningSummaries.contains("Checking the supplied launch context."))
        #expect(!coordinator.reasoningIsStreaming)
    }

}

private actor ReviewReplyProbe: MeetingTextGenerating {
    private(set) var calls = 0
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        calls += 1
        return #"{"status":"answered","markdown":"Launch Friday [[S1]]"}"#
    }
}

private actor ConversationHistoryProbe: MeetingTextGenerating {
    private(set) var calls = 0
    private(set) var lastUser: String?
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        calls += 1; lastUser = request.user
        return #"{"status":"conversation","markdown":"| Item | Date |\n| --- | --- |\n| Launch | Friday |"}"#
    }
}

private actor ToolPresentationProbe: MeetingTextGenerating {
    var calls = 0
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        calls += 1
        await request.onReasoningSummary?("Checking the supplied launch context.")
        if calls == 1 { return #"{"tool":"browse_meeting_sources"}"# }
        return #"{"status":"answered","markdown":"Launch Friday [[S1]]"}"#
    }
}
