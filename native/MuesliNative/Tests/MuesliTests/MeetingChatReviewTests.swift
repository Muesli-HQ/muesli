import Foundation
import SQLite3
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat review regressions", .serialized)
struct MeetingChatReviewTests {
    private func fullReadFixture(text: String = "[00:00:01] You: Launch Friday.") throws -> (DictationStore, MeetingChatStore, MeetingChatWorker, Int64) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-full-read-\(UUID()).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(timeIntervalSince1970: 1_000), endTime: Date(timeIntervalSince1970: 1_100), rawTranscript: text, formattedNotes: "Generated decision.", micAudioPath: nil, systemAudioPath: nil)
        try store.updateMeetingManualNotes(id: id, manualNotes: "Written reminder.")
        return (store, MeetingChatStore(databaseURL: url), MeetingChatWorker(databaseURL: url), id)
    }
    private func fullReadTurn(_ chat: MeetingChatStore, scope: MeetingChatScope) throws -> MeetingChatTurn {
        let session = try chat.createSession(scope: scope, title: "New chat")
        return try chat.beginTurn(sessionID: session.id, question: "Read everything", scope: scope, provider: "test", model: "test")
    }
    private func emptyReadEvidence(_ scope: MeetingChatScope) -> MeetingChatEvidence {
        .init(scope: scope, passages: [], dependencies: [], coverage: .init(eligibleMeetingCount: 1, evidenceMeetingCount: 0, isPartialRecap: false))
    }

    @Test func nativeFullReadIncludesAllKindsAndExactCitations() async throws {
        let (_, chat, worker, id) = try fullReadFixture()
        let scope = MeetingChatScope(selection: .meetings([id]))
        let turn = try fullReadTurn(chat, scope: scope)
        let (result, _, count, nextPage) = try await worker.execute(.readMeeting(id, 0), turn: turn, evidence: emptyReadEvidence(scope), nextSourceKey: 1, native: true)
        #expect(count == 3)
        #expect(nextPage == nil)
        #expect(Set(result.passages.map(\.kind)) == Set([.transcript, .manualNotes, .generatedNotes]))
        let snapshot = try #require(chat.sourceSnapshots(scope: scope).first)
        for passage in result.passages {
            let text: String
            switch passage.kind { case .transcript: text = snapshot.transcript; case .manualNotes: text = snapshot.manualNotes; case .generatedNotes: text = snapshot.generatedNotes }
            #expect((text as NSString).substring(with: passage.range.nsRange) == passage.excerpt)
            #expect(!passage.sourceKey.isEmpty)
        }
        #expect(try chat.dependencies(turnID: turn.id).map(\.meetingID) == [id])
    }

    @Test func nativeFullReadRejectsOutOfScopeDatesFoldersAndRemovedSources() async throws {
        let (store, chat, worker, id) = try fullReadFixture()
        let folder = try store.createFolder(name: "Other")
        let scopes: [MeetingChatScope] = [
            .init(selection: .meetings([])), .init(selection: .folder(folder)),
            .init(startDate: Date(timeIntervalSince1970: 1_001)),
            .init(endDateExclusive: Date(timeIntervalSince1970: 1_000))
        ]
        for scope in scopes {
            let turn = try fullReadTurn(chat, scope: scope)
            await #expect(throws: MeetingChatError.self) {
                _ = try await worker.execute(.readMeeting(id, 0), turn: turn, evidence: emptyReadEvidence(scope), nextSourceKey: 1, native: true)
            }
            #expect(try chat.dependencies(turnID: turn.id).isEmpty)
        }
        let scope = MeetingChatScope(selection: .meetings([id]))
        let turn = try fullReadTurn(chat, scope: scope)
        let (evidence, next, _, _) = try await worker.execute(.readMeeting(id, 0), turn: turn, evidence: emptyReadEvidence(scope), nextSourceKey: 1, native: true)
        try store.updateMeetingTranscript(id: id, rawTranscript: "Changed after first read")
        await #expect(throws: MeetingChatError.self) {
            _ = try await worker.execute(.readMeeting(id, 0), turn: turn, evidence: evidence, nextSourceKey: next, native: true)
        }
        try store.deleteMeeting(id: id)
        await #expect(throws: MeetingChatError.self) {
            _ = try await worker.execute(.readMeeting(id, 0), turn: turn, evidence: emptyReadEvidence(scope), nextSourceKey: 1, native: true)
        }
    }

    @Test func nativeFullReadPagesRetainLateContentAndEarlierMarkers() async throws {
        let text = (0..<90).map { "[00:00:01] You: Passage \($0) " + String(repeating: "discussion ", count: 70) }.joined(separator: "\n") + "\n[00:59:59] You: Final sunflower decision."
        let (_, chat, worker, id) = try fullReadFixture(text: text)
        let scope = MeetingChatScope(selection: .meetings([id]))
        let turn = try fullReadTurn(chat, scope: scope)
        var evidence = emptyReadEvidence(scope)
        var key = 1
        var page = 0
        var firstMarker: String?
        while true {
            let (result, nextKey, _, nextPage) = try await worker.execute(.readMeeting(id, page), turn: turn, evidence: evidence, nextSourceKey: key, native: true)
            firstMarker = firstMarker ?? result.passages.first?.sourceKey
            evidence = result
            key = nextKey
            guard let nextPage else { break }
            #expect(nextPage == page + 1)
            page = nextPage
        }
        #expect(page > 0)
        #expect(evidence.passages.contains { $0.excerpt.contains("Final sunflower decision") })
        #expect(evidence.passages.contains { $0.sourceKey == firstMarker && $0.excerpt.contains("Passage 0 ") })
        let source = try #require(chat.sourceSnapshots(scope: scope).first)
        #expect(Set(evidence.passages.map(\.id)) == Set(MeetingChatPassages.extract(from: source).map(\.id)))
        for invalidPage in [-1, page + 1, 10_000] {
            await #expect(throws: MeetingChatError.self) {
                _ = try await worker.execute(.readMeeting(id, invalidPage), turn: turn, evidence: evidence, nextSourceKey: key, native: true)
            }
        }
    }

    @Test func nativeFullReadFailsAtBudgetInsteadOfSilentlyDroppingPages() async throws {
        let text = (0..<400).map { "[00:00:01] You: Passage \($0) " + String(repeating: "discussion ", count: 100) }.joined(separator: "\n")
        let (_, chat, worker, id) = try fullReadFixture(text: text)
        let scope = MeetingChatScope(selection: .meetings([id]))
        let turn = try fullReadTurn(chat, scope: scope)
        var evidence = emptyReadEvidence(scope)
        var key = 1
        var failedForBudget = false
        for page in 0..<10 {
            do {
                let (result, nextKey, _, nextPage) = try await worker.execute(.readMeeting(id, page), turn: turn, evidence: evidence, nextSourceKey: key, native: true)
                #expect(Set(evidence.passages.map(\.id)).isSubset(of: Set(result.passages.map(\.id))))
                evidence = result; key = nextKey
                if nextPage == nil { break }
            } catch MeetingChatError.promptTooLarge {
                failedForBudget = true; break
            }
        }
        #expect(failedForBudget)
    }

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

    @Test func invalidatedRegistrationCannotTakeTheUntitledDraft() async throws {
        let (store, coordinator) = try fixture()
        await coordinator.waitForIdle()
        coordinator.composerDraft = "Keep my unsent question"
        // Reproduce the state after a worker committed registration, but before
        // its continuation resumes: the new session has not won selection yet.
        let registered = try coordinator.store.createSession(scope: .init(), title: "New chat")
        _ = try store.insertMeeting(title: "Source changed", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Updated", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        coordinator.refreshForSourceChanges()
        coordinator.adoptUntitledComposerDraft(sessionID: registered.id)
        #expect(coordinator.selectedSessionID == nil)
        #expect(coordinator.composerDraft == "Keep my unsent question")
        coordinator.selectChat(id: registered.id)
        #expect(coordinator.composerDraft.isEmpty)
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

    @Test func rollingMemorySurvivesProviderSwitchAndIsScrubbedOnDeletion() async throws {
        let probe = RollingMemoryProbe()
        let (meetings, coordinator) = try fixture(generator: probe)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init())
        let session = try #require(coordinator.selectedSessionID)
        let source = try #require(coordinator.store.sourceSnapshots(scope: .init()).first)
        let first = try coordinator.store.beginTurn(sessionID: session, question: "Remember the launch", scope: .init(), provider: "old", model: "old")
        let deps = [MeetingChatDependency(meetingID: source.meetingID, revision: source.revision)]
        try coordinator.store.attachEvidence(turnID: first.id, dependencies: deps)
        #expect(try coordinator.store.finishTurn(turnID: first.id, answer: String(repeating: "Launch discussion. ", count: 2000) + "Unique promise: Friday.", citations: [], dependencies: deps))
        var config = AppConfig(); config.meetingSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend
        await coordinator.send(question: "Make it short", config: config)
        await coordinator.waitForIdle()
        #expect(try coordinator.store.turns(sessionID: session).last?.state == .completed)
        #expect(try coordinator.store.sessions().first(where: { $0.id == session })?.rollingSummary != nil)
        config.meetingSummaryBackend = MeetingSummaryBackendOption.anthropic.backend
        await coordinator.send(question: "What promise did we discuss?", config: config)
        await coordinator.waitForIdle()
        #expect(try coordinator.store.turns(sessionID: session).last?.state == .completed)
        #expect(await probe.answerPrompts.count == 2)
        #expect(await probe.answerPrompts.allSatisfy { $0.contains("Unique promise: Friday") })
        #expect(await probe.answerProviders.last == MeetingSummaryBackendOption.anthropic.backend)
        try meetings.deleteMeeting(id: source.meetingID)
        #expect(try coordinator.store.sessions().first(where: { $0.id == session })?.rollingSummary == nil)
        #expect(try coordinator.store.turns(sessionID: session).last?.state == .sourceDeleted)
    }

    @Test func attachedMeetingContentsReachFirstModelRequest() async throws {
        let probe = AttachedContextProbe()
        let (store, coordinator) = try fixture(generator: probe)
        let id = try store.insertMeeting(title: "Cinematography", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Solaris and Stalker have distinctive cinematography.", formattedNotes: "## Meeting Summary\n\nDiscussed framing and lighting in Solaris.", micAudioPath: nil, systemAudioPath: nil)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "which movies was this meeting about?", config: AppConfig())
        await coordinator.waitForIdle()
        let prompt = try #require(await probe.user)
        #expect(prompt.contains("Solaris and Stalker have distinctive cinematography."))
        #expect(prompt.contains("Discussed framing and lighting in Solaris."))
        #expect(!prompt.contains("## Meeting Summary"))
        #expect(await probe.calls == 1)
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

    @Test func composerUndoIdentityFollowsAttachmentRegistrationAndResetsOnSend() async throws {
        let (_, coordinator) = try fixture()
        await coordinator.refreshChoices()
        let meeting = try #require(coordinator.sourceChoices.first)
        coordinator.composerDraft = "Question @Launch"
        let draftIdentity = coordinator.composerUndoIdentity
        #expect(await coordinator.addMeetingToScope(id: meeting.id))
        #expect(coordinator.composerUndoIdentity == draftIdentity)
        let firstSession = try #require(coordinator.selectedSessionID)
        coordinator.composerDraft = "Launch?"
        await coordinator.send(question: "Launch?", config: AppConfig())
        #expect(coordinator.composerUndoIdentity != draftIdentity)
        let submittedIdentity = coordinator.composerUndoIdentity
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init())
        #expect(coordinator.composerUndoIdentity != submittedIdentity)
        coordinator.selectChat(id: firstSession)
        #expect(coordinator.composerUndoIdentity == submittedIdentity)
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

private actor AttachedContextProbe: MeetingTextGenerating {
    private(set) var user: String?
    private(set) var calls = 0
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        calls += 1; user = request.user
        return #"{"status":"answered","markdown":"Solaris and Stalker [[S1]]"}"#
    }
}

private actor RollingMemoryProbe: MeetingTextGenerating {
    private(set) var answerPrompts: [String] = []
    private(set) var answerProviders: [String] = []
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        if request.system.contains("Compress conversation history") { return "Unique promise: Friday. This is a prior conversation claim, not fresh evidence." }
        answerPrompts.append(request.user)
        answerProviders.append(request.config.meetingSummaryBackend)
        return #"{"status":"conversation","markdown":"We discussed a Friday promise."}"#
    }
}
