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
}

private actor RequestSpy: MeetingTextGenerating {
    private var requests: [String] = []
    private var calls = 0
    private let firstReply: String?
    private let answer: String

    init(firstReply: String? = nil,
         answer: String = #"{"status":"answered","markdown":"Discussed [[S1]]."}"#) {
        self.firstReply = firstReply
        self.answer = answer
    }

    func requestsContaining(_ text: String) -> Int { requests.filter { $0.contains(text) }.count }

    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request.system + "\n" + request.user)
        calls += 1
        if calls == 1, let firstReply { return firstReply }
        return answer
    }
}
