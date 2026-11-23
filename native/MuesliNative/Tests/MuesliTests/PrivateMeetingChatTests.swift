import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Private meetings in Ask Meetings")
struct PrivateMeetingChatTests {
    private let marker = "zanzibar-private-marker"

    private func database() throws -> DictationStore {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("private-chat-\(UUID()).db"))
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func insert(_ store: DictationStore, text: String, title: String = "Planning") throws -> Int64 {
        let now = Date()
        return try store.insertMeeting(title: title, calendarEventID: nil, startTime: now,
            endTime: now.addingTimeInterval(60), rawTranscript: text, formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil)
    }

    private func trustedConfig() -> AppConfig {
        var config = AppConfig()
        config.privateTrustedBackends = [PrivateMeetingPolicy.effectiveBackend(of: config)]
        return config
    }

    // MARK: - Retrieval filter (F13)

    @Test func retrievalExcludesPrivateMeetingsWhenAsked() throws {
        let store = try database()
        try store.setMeetingPrivate(id: try insert(store, text: "\(marker) budget"), isPrivate: true)
        try insert(store, text: "ordinary budget review")
        let retrieval = MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL)

        let open = try retrieval.retrieve(question: "budget", scope: .init())
        #expect(open.passages.count == 2)

        let excluded = try retrieval.retrieve(question: "budget", scope: .init(), excludePrivateMeetings: true)
        #expect(excluded.passages.count == 1)
        #expect(!excluded.passages.contains { $0.excerpt.contains(marker) })
        #expect(excluded.coverage.eligibleMeetingCount == 1)
    }

    @Test func retrievalExcludesMeetingsPrivateThroughTheirFolder() throws {
        let store = try database()
        let root = try store.createFolder(name: "Legal")
        let child = try store.createFolder(name: "Cases", parentID: root)
        let id = try insert(store, text: "\(marker) settlement")
        try store.moveMeeting(id: id, toFolder: child)
        try store.setFolderPrivate(id: root, isPrivate: true)
        let retrieval = MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL)

        #expect(try retrieval.retrieve(question: "settlement", scope: .init(), excludePrivateMeetings: true).passages.isEmpty)
        #expect(try retrieval.retrieve(question: "settlement", scope: .init()).passages.count == 1)
    }

    @Test func explicitlyAttachingAPrivateMeetingDoesNotBypassTheFilter() throws {
        let store = try database()
        let id = try insert(store, text: "\(marker) settlement")
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let retrieval = MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL)

        let evidence = try retrieval.retrieve(question: "settlement",
            scope: .init(selection: .meetings([id])), includeScopeContext: true, excludePrivateMeetings: true)
        #expect(evidence.passages.isEmpty)
        #expect(evidence.coverage.eligibleMeetingCount == 0)
    }

    // MARK: - End to end through the coordinator

    @Test @MainActor func untrustedBackendNeverSeesPrivateMeetingText() async throws {
        let store = try database()
        let id = try insert(store, text: "\(marker) budget")
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let spy = RequestSpy()
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "budget", config: AppConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) == 0)
    }

    @Test @MainActor func trustedBackendDoesSeePrivateMeetingText() async throws {
        let store = try database()
        let id = try insert(store, text: "\(marker) budget")
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let spy = RequestSpy()
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "budget", config: trustedConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) >= 1)
    }

    @Test @MainActor func searchToolCannotReachPrivateMeetingsOnAnUntrustedBackend() async throws {
        let store = try database()
        try store.setMeetingPrivate(id: try insert(store, text: "\(marker) budget"), isPrivate: true)
        try insert(store, text: "ordinary budget review")
        let spy = RequestSpy(firstReply: #"{"tool":"search_history","kind":"meeting","query":"zanzibar"}"#)
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init())
        await coordinator.send(question: "budget", config: AppConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) == 0)
    }

    @Test @MainActor func discoverMeetingsExcludesPrivateMeetingsWhenAsked() throws {
        let store = try database()
        try store.setMeetingPrivate(id: try insert(store, text: "secret", title: marker), isPrivate: true)
        try insert(store, text: "normal", title: "Weekly Sync")
        let chatStore = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)

        let open = try chatStore.discoverMeetings(in: .init(), title: "", limit: 10, asOf: Date().addingTimeInterval(60))
        #expect(open.passages.contains { $0.title == marker })

        let excluded = try chatStore.discoverMeetings(in: .init(), title: "", limit: 10, asOf: Date().addingTimeInterval(60), excludePrivateMeetings: true)
        #expect(!excluded.passages.contains { $0.title == marker })
        #expect(excluded.passages.contains { $0.title == "Weekly Sync" })
    }

    // MARK: - Conversation memory (F14)

    @Test @MainActor func answersBuiltFromPrivateMeetingsDoNotFlowToAnUntrustedBackendLater() async throws {
        let store = try database()
        let id = try insert(store, text: "\(marker) budget")
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let spy = RequestSpy(answer: #"{"status":"answered","markdown":"The meeting covered the \#(marker) plan [[S1]]."}"#)
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "budget", config: trustedConfig())
        await coordinator.waitForIdle()
        let before = await spy.requestsContaining(marker)
        #expect(before >= 1)

        await coordinator.send(question: "and the follow-up?", config: AppConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) == before)
        let last = try #require(coordinator.turns.last)
        #expect(last.state == .failed)
    }

    // MARK: - SQL & Library tools (Finding 1)

    @Test @MainActor func sqlToolExcludesPrivateMeetingsAndPrivateFolderMeetingsOnUntrustedBackend() async throws {
        let store = try database()
        let directPrivateID = try insert(store, text: "\(marker) direct-secret", title: "Direct Secret")
        try store.setMeetingPrivate(id: directPrivateID, isPrivate: true)
        let folder = try store.createFolder(name: "Confidential")
        try store.setFolderPrivate(id: folder, isPrivate: true)
        let nestedFolder = try store.createFolder(name: "Subfolder", parentID: folder)
        let folderPrivateID = try insert(store, text: "\(marker) folder-secret", title: "Folder Secret")
        try store.moveMeeting(id: folderPrivateID, toFolder: nestedFolder)
        _ = try insert(store, text: "open-budget notes", title: "Weekly Sync")

        let spy = RequestSpy(
            firstReply: #"{"tool":"query_history_sql","sql":"SELECT id, title, text FROM meetings ORDER BY id"}"#,
            answer: #"{"status":"conversation","markdown":"Checked SQL."}"#
        )
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: MeetingChatScopePolicy.empty, implicit: true)
        await coordinator.send(question: "query meetings with sql", config: AppConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) == 0)
        #expect(await spy.requestsContaining("Direct Secret") == 0)
        #expect(await spy.requestsContaining("Folder Secret") == 0)
        #expect(await spy.requestsContaining("Weekly Sync") >= 1)
    }

    @Test @MainActor func sqlToolExcludesSavedChatsDerivedFromPrivateMeetingsOnUntrustedBackend() async throws {
        let store = try database()
        let privateID = try insert(store, text: "\(marker) merger-plan", title: "Merger Plan")
        try store.setMeetingPrivate(id: privateID, isPrivate: true)
        let publicID = try insert(store, text: "ordinary standup notes", title: "Standup")

        let chatStore = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)
        let privateChat = try chatStore.createSession(scope: .init(selection: .meetings([privateID])), title: "Private Chat")
        let privateTurn = try chatStore.beginTurn(sessionID: privateChat.id, question: "Summarize merger", scope: .init(selection: .meetings([privateID])), provider: "test", model: "test")
        let privateSnapshot = try #require(chatStore.sourceSnapshots(scope: .init(selection: .meetings([privateID]))).first)
        #expect(try chatStore.finishTurn(turnID: privateTurn.id, answer: "Secret \(marker) summary", citations: [], dependencies: [.init(meetingID: privateID, revision: privateSnapshot.revision)]))

        let publicChat = try chatStore.createSession(scope: .init(selection: .meetings([publicID])), title: "Public Chat")
        let publicTurn = try chatStore.beginTurn(sessionID: publicChat.id, question: "Summarize standup", scope: .init(selection: .meetings([publicID])), provider: "test", model: "test")
        let publicSnapshot = try #require(chatStore.sourceSnapshots(scope: .init(selection: .meetings([publicID]))).first)
        #expect(try chatStore.finishTurn(turnID: publicTurn.id, answer: "Normal standup summary", citations: [], dependencies: [.init(meetingID: publicID, revision: publicSnapshot.revision)]))

        let spy = RequestSpy(
            firstReply: #"{"tool":"query_history_sql","sql":"SELECT id, title, text FROM chats ORDER BY id"}"#,
            answer: #"{"status":"conversation","markdown":"Checked chats."}"#
        )
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: MeetingChatScopePolicy.empty, implicit: true)
        await coordinator.send(question: "list saved chats with sql", config: AppConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) == 0)
        #expect(await spy.requestsContaining("Private Chat") == 0)
        #expect(await spy.requestsContaining("Normal standup summary") >= 1)
    }

    @Test @MainActor func sqlToolAllowsPrivateMeetingsOnTrustedBackend() async throws {
        let store = try database()
        let privateID = try insert(store, text: "\(marker) trusted-secret", title: "Trusted Secret")
        try store.setMeetingPrivate(id: privateID, isPrivate: true)

        let spy = RequestSpy(
            firstReply: #"{"tool":"query_history_sql","sql":"SELECT title, text FROM meetings"}"#,
            answer: #"{"status":"conversation","markdown":"Checked trusted SQL."}"#
        )
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: MeetingChatScopePolicy.empty, implicit: true)
        await coordinator.send(question: "query meetings with sql", config: trustedConfig())
        await coordinator.waitForIdle()

        #expect(await spy.requestsContaining(marker) >= 1)
    }

    // MARK: - Mid-chat locking (Finding 3)

    @Test @MainActor func markingMeetingPrivateMidChatAbortsNextModelRequest() async throws {
        let store = try database()
        let id = try insert(store, text: "\(marker) roadmap")
        let other = try insert(store, text: "unrelated notes", title: "Other")
        let spy = RequestSpy(
            firstReply: #"{"tool":"search_history","kind":"meeting","query":"unrelated"}"#,
            answer: #"{"status":"answered","markdown":"Should never publish [[S1]]."}"#,
            onFirstCall: {
                try store.setMeetingPrivate(id: id, isPrivate: true)
            }
        )
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init(selection: .meetings([id, other])))
        await coordinator.send(question: "roadmap", config: AppConfig())
        await coordinator.waitForIdle()

        // First call ran before the lock; the second model call must be aborted before firing.
        #expect(await spy.callCount() == 1)
        let last = try #require(coordinator.turns.last)
        #expect(last.state == .failed)
    }

    @Test @MainActor func markingFolderPrivateMidChatWithAttachedMeetingAbortsBeforeSecondRequest() async throws {
        let store = try database()
        let folder = try store.createFolder(name: "Board")
        let id = try insert(store, text: "\(marker) acquisition")
        try store.moveMeeting(id: id, toFolder: folder)

        let spy = RequestSpy(
            firstReply: #"{"tool":"search_history","kind":"meeting","query":"acquisition"}"#,
            answer: #"{"status":"answered","markdown":"Should never publish [[S1]]."}"#,
            onFirstCall: {
                try store.setFolderPrivate(id: folder, isPrivate: true)
            }
        )
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "acquisition", config: AppConfig())
        await coordinator.waitForIdle()

        #expect(await spy.callCount() == 1)
        let last = try #require(coordinator.turns.last)
        #expect(last.state == .failed)
    }

    @Test @MainActor func markingFolderPrivateAfterToolExecutionAbortsNextValidationBeforeModelRequest() async throws {
        let store = try database()
        let folder = try store.createFolder(name: "Board")
        let id = try insert(store, text: "\(marker) acquisition")
        try store.moveMeeting(id: id, toFolder: folder)

        let chatStore = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)
        let session = try chatStore.createSession(scope: .init(selection: .all), title: "Chat")
        let turn = try chatStore.beginTurn(
            sessionID: session.id,
            question: "acquisition",
            scope: .init(selection: .all),
            provider: "test",
            model: "test"
        )
        let worker = MeetingChatWorker(databaseURL: store.resolvedDatabaseURL)
        let (initial, _) = try await worker.evidence(for: turn, excludePrivate: true)
        let (updated, _, count, _) = try await worker.execute(
            .search("acquisition"),
            turn: turn,
            evidence: initial,
            nextSourceKey: 1,
            excludePrivate: true
        )
        #expect(count >= 1)
        #expect(updated.dependencies.contains { $0.meetingID == id })

        // Folder becomes private after tool retrieval returned passages, before next model request.
        try store.setFolderPrivate(id: folder, isPrivate: true)
        await #expect(throws: MeetingChatError.privateMeetingBlocked) {
            _ = try await worker.canPublishSummary(turn: turn, excludePrivate: true)
        }
    }

    @Test @MainActor func markingMeetingPrivateMidChatAfterSQLToolAbortsPublicationAndBlocksNextCheck() async throws {
        let store = try database()
        let id = try insert(store, text: "\(marker) board-notes", title: "Board Notes")

        // 1. Mid-flight lock during the 2nd model request (after SQL ran in iteration 1) must abort publication.
        let spy = RequestSpy(
            firstReply: #"{"tool":"query_history_sql","sql":"SELECT title, text FROM meetings"}"#,
            answer: #"{"status":"conversation","markdown":"Should not publish."}"#,
            onSecondCall: {
                try store.setMeetingPrivate(id: id, isPrivate: true)
            }
        )
        let coordinator = MeetingChatCoordinator(databaseURL: store.resolvedDatabaseURL, generator: spy)
        await coordinator.waitForIdle()
        await coordinator.createChat(scope: MeetingChatScopePolicy.empty, implicit: true)
        await coordinator.send(question: "summarize board notes", config: AppConfig())
        await coordinator.waitForIdle()

        let last = try #require(coordinator.turns.last)
        #expect(last.state == .failed)
        #expect(last.originalAnswer == nil)

        // 2. Also verify direct worker validation throws privateMeetingBlocked right after SQL records sqlMeeting.
        let id2 = try insert(store, text: "open-notes", title: "Open Notes")
        let chatStore = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)
        let session = try chatStore.createSession(scope: MeetingChatScopePolicy.empty, title: "SQL Chat", allowsRequestedMeetingDiscovery: true)
        let turn = try chatStore.beginTurn(
            sessionID: session.id,
            question: "count meetings",
            scope: MeetingChatScopePolicy.empty,
            provider: "test",
            model: "test"
        )
        let library = ChatLibraryTools(turn: turn, databaseURL: store.resolvedDatabaseURL, excludePrivate: true)
        _ = try await library.execute(.sql("SELECT id, title FROM meetings"), evidence: .init(scope: MeetingChatScopePolicy.empty, passages: [], dependencies: [], coverage: .init(eligibleMeetingCount: 0, evidenceMeetingCount: 0, isPartialRecap: false)))
        try store.setMeetingPrivate(id: id2, isPrivate: true)
        let worker = MeetingChatWorker(databaseURL: store.resolvedDatabaseURL)
        await #expect(throws: MeetingChatError.privateMeetingBlocked) {
            _ = try await worker.canPublishSummary(turn: turn, excludePrivate: true)
        }
    }

    @Test func sourceRevisionChangesWhenMeetingOrFolderBecomesPrivate() throws {
        let store = try database()
        let folder = try store.createFolder(name: "Legal")
        let id = try insert(store, text: "contract review")
        try store.moveMeeting(id: id, toFolder: folder)

        let chatStore = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)
        let publicSnap = try #require(try chatStore.sourceSnapshots(scope: .init(selection: .meetings([id]))).first)
        let dep = [MeetingChatDependency(meetingID: id, revision: publicSnap.revision)]
        #expect(try chatStore.dependenciesAreCurrent(dep))

        try store.setFolderPrivate(id: folder, isPrivate: true)
        let folderPrivateSnap = try #require(try chatStore.sourceSnapshots(scope: .init(selection: .meetings([id]))).first)
        #expect(folderPrivateSnap.revision != publicSnap.revision)
        #expect(!(try chatStore.dependenciesAreCurrent(dep)))

        try store.setFolderPrivate(id: folder, isPrivate: false)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let directPrivateSnap = try #require(try chatStore.sourceSnapshots(scope: .init(selection: .meetings([id]))).first)
        #expect(directPrivateSnap.revision != publicSnap.revision)
        #expect(!(try chatStore.dependenciesAreCurrent(dep)))
    }
}

private actor RequestSpy: MeetingTextGenerating {
    private var requests: [String] = []
    private var calls = 0
    private let firstReply: String?
    private let answer: String
    private let onFirstCall: (@Sendable () throws -> Void)?
    private let onSecondCall: (@Sendable () throws -> Void)?
    private let afterFirstReplyHook: (@Sendable () throws -> Void)?

    init(firstReply: String? = nil,
         answer: String = #"{"status":"answered","markdown":"Discussed [[S1]]."}"#,
         onFirstCall: (@Sendable () throws -> Void)? = nil,
         onSecondCall: (@Sendable () throws -> Void)? = nil,
         afterFirstReplyHook: (@Sendable () throws -> Void)? = nil) {
        self.firstReply = firstReply
        self.answer = answer
        self.onFirstCall = onFirstCall
        self.onSecondCall = onSecondCall
        self.afterFirstReplyHook = afterFirstReplyHook
    }

    func callCount() -> Int { calls }
    func requestsContaining(_ text: String) -> Int { requests.filter { $0.contains(text) }.count }

    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request.system + "\n" + request.user)
        calls += 1
        if calls == 1 {
            try onFirstCall?()
            if let firstReply {
                try afterFirstReplyHook?()
                return firstReply
            }
        }
        if calls == 2 {
            try onSecondCall?()
        }
        return answer
    }
}
