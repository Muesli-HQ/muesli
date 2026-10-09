import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting chat client")
struct MeetingChatClientTests {
    private func evidence(title: String = "Planning") -> MeetingChatEvidence {
        let passage = MeetingChatPassage(id: "p1", sourceKey: "S1", meetingID: 1, title: title,
            startDate: Date(timeIntervalSince1970: 1_000), kind: .transcript, excerpt: "[00:00:05] You: Ship Friday.",
            range: .init(location: 0, length: 34), timestamp: "00:00:05", revision: "r1")
        return .init(scope: .init(), passages: [passage], dependencies: [.init(meetingID: 1, revision: "r1")],
                     coverage: .init(eligibleMeetingCount: 1, evidenceMeetingCount: 1, isPartialRecap: false))
    }

    @Test func resolvesOnlySuppliedSourceMarkers() throws {
        let answer = try MeetingChatClient.validateResponse(#"{"status":"answered","markdown":"We ship Friday. [[S1]]"}"#, evidence: evidence())
        #expect(answer.citations.map(\.sourceKey) == ["S1"])
        #expect(answer.citations.first?.excerpt == "[00:00:05] You: Ship Friday.")
        #expect(throws: MeetingChatError.self) {
            try MeetingChatClient.validateResponse(#"{"status":"answered","markdown":"Friday [[S999]]"}"#, evidence: evidence())
        }
        #expect(throws: MeetingChatError.self) {
            try MeetingChatClient.validateResponse(#"{"status":"answered","markdown":"Friday"}"#, evidence: evidence())
        }
    }
    @Test func acceptsExplicitInsufficientEvidence() throws {
        let answer = try MeetingChatClient.validateResponse(#"{"status":"insufficient_evidence","markdown":"The saved meetings do not say."}"#, evidence: evidence())
        #expect(answer.insufficientEvidence)
        #expect(answer.citations.isEmpty)
    }
    @Test func rejectsMalformedEnvelopesAndModelLinksAreNotCitationTargets() throws {
        #expect(throws: MeetingChatError.self) { try MeetingChatClient.validateResponse("not JSON", evidence: evidence()) }
        let answer = try MeetingChatClient.validateResponse(#"{"status":"answered","markdown":"Friday [open](file:///private/secret) [[S1]]"}"#, evidence: evidence())
        #expect(answer.citations.first?.meetingID == 1)
        #expect(!MeetingChatClient.displayText(answer.markdown).contains("file:///"))
    }
    @Test func promptBudgetsAndUntrustedContext() throws {
        let prompt = try MeetingChatClient.makePrompt(question: String(repeating: "a", count: 2_000), evidence: evidence(), history: [])
        #expect(prompt.totalUTF8Bytes <= 24_000)
        #expect(prompt.system.contains("untrusted"))
        #expect(throws: MeetingChatError.self) {
            try MeetingChatClient.makePrompt(question: String(repeating: "a", count: 2_001), evidence: evidence(), history: [])
        }
        let long = try MeetingChatClient.makePrompt(question: "When?", evidence: evidence(title: String(repeating: "🌻", count: 10_000)), history: [])
        #expect(long.totalUTF8Bytes <= 24_000)
    }

    @Test(arguments: ["openai", "openrouter", "ollama", "lmstudio", "custom_llm"])
    func buildsRequestForSelectedProvider(backend: String) throws {
        var config = AppConfig(); config.meetingSummaryBackend = backend
        config.openAIModel = "test-model"; config.openRouterModel = "test-model"; config.ollamaModel = "test-model"
        config.lmStudioModel = "test-model"; config.customLLMModel = "test-model"; config.customLLMURL = "http://localhost:1234"
        let request = try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config), credential: "synthetic-test-key")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "test-model")
        #expect(request.httpMethod == "POST")
        if backend == "openai" { #expect(body["store"] as? Bool == false) }
    }
    @Test func buildsAnthropicFormatAndRejectsMissingCredentials() throws {
        var config = AppConfig(); config.meetingSummaryBackend = "custom_llm"; config.customLLMFormat = "anthropic"
        config.customLLMModel = "test"; config.customLLMURL = "http://localhost:1234"
        let request = try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config), credential: "synthetic")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(throws: MeetingTextGenerationError.self) {
            try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config), credential: "")
        }
    }
    @Test func chatGPTUsesExistingStreamingContract() async throws {
        var config = AppConfig(); config.meetingSummaryBackend = "chatgpt"
        let generator = MeetingTextGenerationClient(chatGPT: { _ in "synthetic reply" })
        #expect(try await generator.generate(.init(system: "System", user: "User", config: config)) == "synthetic reply")
    }

    @Test(arguments: ["openai", "openrouter", "ollama", "lmstudio", "custom_llm"])
    func parsesProviderRepliesWithoutLiveNetwork(backend: String) async throws {
        var config = AppConfig(); config.meetingSummaryBackend = backend
        config.lmStudioModel = "test"; config.customLLMModel = "test"
        let generator = MeetingTextGenerationClient(credentialResolver: { _ in "synthetic" }, load: { request in
            let text: String
            if backend == "openai" { text = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"synthetic reply"}]}]}"# }
            else if backend == "ollama" { text = #"{"message":{"content":"synthetic reply"}}"# }
            else { text = #"{"choices":[{"message":{"content":"synthetic reply"}}]}"# }
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await generator.generate(.init(system: "S", user: "U", config: config)) == "synthetic reply")
    }

    @Test func providerErrorDoesNotEchoSourceContent() async throws {
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        let generator = MeetingTextGenerationClient(credentialResolver: { _ in "synthetic" }, load: { request in
            (Data("secret source content".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await generator.generate(.init(system: "S", user: "U", config: config))
            Issue.record("Expected provider failure")
        } catch { #expect(!error.localizedDescription.contains("secret source")) }
    }

    @MainActor private func coordinatorFixture(generator: any MeetingTextGenerating) throws -> (DictationStore, MeetingChatCoordinator, Int64) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-race-\(UUID()).db")
        let store = DictationStore(databaseURL: url); try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Launch Friday", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        return (store, MeetingChatCoordinator(databaseURL: url, generator: generator), id)
    }

    @Test @MainActor func sourceDeleteDuringAwaitCannotPersist() async throws {
        let gate = ChatReplyGate()
        let (store, coordinator, id) = try coordinatorFixture(generator: gate)
        coordinator.createChat(scope: .init()); coordinator.send(question: "launch", config: AppConfig())
        await gate.waitUntilStarted()
        try store.deleteMeeting(id: id)
        await gate.finish(); await coordinator.waitForIdle()
        #expect(coordinator.turns.first?.state == .sourceDeleted)
        #expect(coordinator.turns.first?.originalAnswer == nil)
    }

    @Test @MainActor func switchChatPreservesReplyOwner() async throws {
        let gate = ChatReplyGate()
        let (store, coordinator, _) = try coordinatorFixture(generator: gate)
        coordinator.createChat(scope: .init())
        let original = try #require(coordinator.selectedSessionID)
        coordinator.send(question: "launch", config: AppConfig()); await gate.waitUntilStarted()
        coordinator.createChat(scope: .init())
        await gate.finish(); await coordinator.waitForIdle()
        #expect(coordinator.turns.isEmpty)
        #expect(try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).turns(sessionID: original).first?.state == .completed)
    }

    @Test @MainActor func retryReusesQuestionAndScopeChangesExcludeOldHistory() async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, id) = try coordinatorFixture(generator: probe)
        coordinator.createChat(scope: .init()); coordinator.send(question: "launch", config: AppConfig())
        await coordinator.waitForIdle()
        let first = try #require(coordinator.turns.first)
        coordinator.retry(turnID: first.id, config: AppConfig()); await coordinator.waitForIdle()
        #expect(coordinator.turns.count == 1)
        coordinator.setScope(.init(selection: .meetings([id])))
        coordinator.setScope(.init())
        coordinator.send(question: "launch follow-up", config: AppConfig()); await coordinator.waitForIdle()
        let requests = await probe.requests
        #expect(!requests.last!.user.contains("HISTORICAL_ANSWER"))
        #expect(try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).turns(sessionID: coordinator.selectedSessionID!).count == 2)
    }

    @Test @MainActor func deletingBackgroundChatCancelsItsRequest() async throws {
        let gate = ChatReplyGate()
        let (_, coordinator, _) = try coordinatorFixture(generator: gate)
        coordinator.createChat(scope: .init()); let original = coordinator.selectedSessionID!
        coordinator.send(question: "launch", config: AppConfig()); await gate.waitUntilStarted()
        coordinator.createChat(scope: .init()); coordinator.deleteChat(id: original)
        #expect(!coordinator.isBusy)
        await gate.finish(); await coordinator.waitForIdle()
    }

    @Test @MainActor func editedSourceDoesNotBlockFreshFollowUp() async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, id) = try coordinatorFixture(generator: probe)
        coordinator.createChat(scope: .init()); coordinator.send(question: "launch", config: AppConfig()); await coordinator.waitForIdle()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Launch Monday")
        coordinator.send(question: "launch now?", config: AppConfig()); await coordinator.waitForIdle()
        #expect(coordinator.turns.last?.state == .completed)
        #expect(await probe.requests.count == 2)
    }

    @Test @MainActor func targetedDecisionQuestionKeepsOldRelevantMeeting() async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, _) = try coordinatorFixture(generator: probe)
        _ = try store.insertMeeting(title: "Sunflower", calendarEventID: nil, startTime: Date(timeIntervalSince1970: 1_000), endTime: Date(timeIntervalSince1970: 1_060), rawTranscript: "The sunflower contract was approved.", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        for _ in 0..<300 { _ = try store.insertMeeting(title: "Routine", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Unrelated check-in.", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil) }
        coordinator.createChat(scope: .init())
        coordinator.send(question: "What decisions did we make about sunflower?", config: AppConfig())
        await coordinator.waitForIdle()
        #expect(await probe.requests.last?.user.contains("The sunflower contract was approved.") == true)
    }

    @Test @MainActor func clearingHistoryCancelsSuspendedGenerationAndClearsVisibleTurns() async throws {
        let gate = ChatReplyGate()
        let (store, coordinator, _) = try coordinatorFixture(generator: gate)
        let directory = store.resolvedDatabaseURL.deletingLastPathComponent().appendingPathComponent("chat-wipe-support-\(UUID())")
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil), dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        controller.meetingChatCoordinator = coordinator
        coordinator.createChat(scope: .init()); coordinator.send(question: "launch", config: AppConfig())
        await gate.waitUntilStarted()
        controller.clearMeetingHistory()
        #expect(!coordinator.isBusy)
        #expect(coordinator.turns.isEmpty)
        await gate.finish(); await coordinator.waitForIdle()
        #expect(coordinator.sessions.isEmpty)
    }

    @Test @MainActor func stopThenLateResultIsIgnored() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID()).db")
        let store = DictationStore(databaseURL: url); try store.migrateIfNeeded()
        _ = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Launch Friday", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        let gate = ChatReplyGate()
        let coordinator = MeetingChatCoordinator(databaseURL: url, generator: gate)
        coordinator.createChat(scope: .init())
        coordinator.send(question: "launch", config: AppConfig())
        await gate.waitUntilStarted()
        coordinator.stop()
        await gate.finish()
        await coordinator.waitForIdle()
        #expect(coordinator.turns.first?.state == .stopped)
        #expect(coordinator.turns.first?.originalAnswer == nil)
    }
}

private actor ChatReplyGate: MeetingTextGenerating {
    private var started = false
    private var continuation: CheckedContinuation<String, Never>?
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<500 where !started { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func finish() { continuation?.resume(returning: #"{"status":"answered","markdown":"Friday [[S1]]"}"#); continuation = nil }
}

private actor ChatPromptProbe: MeetingTextGenerating {
    var requests: [MeetingTextGenerationRequest] = []
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request)
        return #"{"status":"answered","markdown":"HISTORICAL_ANSWER Friday [[S1]]"}"#
    }
}
