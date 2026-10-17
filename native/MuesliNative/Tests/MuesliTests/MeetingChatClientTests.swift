import Foundation
import Testing
import SQLite3
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

    @Test func transcriptPromptShowsHumanReadableSpeakerLabelsAndKeepsEvidenceOriginal() throws {
        var packet = evidence()
        packet.passages[0].excerpt = MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:05", speaker: "Team: Example", text: "Ship Friday."
        )
        let storedExcerpt = packet.passages[0].excerpt

        let prompt = try MeetingChatClient.makePrompt(question: "What did they decide?", evidence: packet, history: [])
        let sourceBoundary = "QUOTED SOURCES (JSON):\n"
        let start = try #require(prompt.user.range(of: sourceBoundary)?.upperBound)
        let end = try #require(prompt.user[start...].range(of: "\nUSER QUESTION:")?.lowerBound)
        let sourceJSON = String(prompt.user[start..<end])
        let sources = try #require(JSONSerialization.jsonObject(with: Data(sourceJSON.utf8)) as? [[String: String]])

        #expect(sources.first?["excerpt"] == #"[00:00:05] Team: Example: Ship Friday."#)
        #expect(packet.passages[0].excerpt == storedExcerpt)
    }

    @Test func rollingMemoryIsPortableContextAndLongRecentAnswersAreNotClipped() throws {
        let longAnswer = String(repeating: "A useful detail. ", count: 330) + "KEEP THE LAST DETAIL"
        let turn = MeetingChatTurn(id: UUID(), sessionID: UUID(), ordinal: 0, question: "Explain the plan",
            scope: .init(), state: .completed, originalAnswer: longAnswer, citations: [], provider: "Old provider", model: "Old model")
        var config = AppConfig(); config.meetingSummaryBackend = "chatgpt"
        let budget = MeetingChatContextBudget(config: config)
        let prompt = try MeetingChatClient.makePrompt(question: "What remains?", evidence: evidence(), history: [turn],
            rollingSummary: "Earlier we agreed to compare options, not commit to a deadline.", budget: budget)
        #expect(prompt.user.contains("KEEP THE LAST DETAIL"))
        #expect(prompt.user.contains("Earlier we agreed to compare options"))
        #expect(!prompt.user.contains("[truncated]"))
        let response = try MeetingChatClient.validateResponse(#"{"status":"conversation","markdown":"The comparison remains open."}"#,
            evidence: evidence(), history: [], rollingSummary: "Earlier we agreed to compare options.")
        #expect(response.markdown == "The comparison remains open.")
    }

    @Test @MainActor func nativeCallsUseRegisteredToolsAndReplayOutputsWithReasoning() async throws {
        let probe = NativeHarnessProbe()
        var initial = evidence()
        initial.coverage.isPartialRecap = true
        var executed: [MeetingChatToolCall] = []
        let (answer, final) = try await MeetingChatClient.run(question: "Read the entire meeting", evidence: initial, history: [], config: AppConfig(), sessionID: UUID(), generator: probe,
            execute: { call, current in
                executed.append(call)
                var result = current
                var passage = current.passages[0]; passage.id = "p2"; passage.sourceKey = "S2"
                passage.excerpt = MeetingSpeakerState.renderTranscriptTurn(
                    timestamp: "00:00:07", speaker: "Team: Example", text: "Full meeting detail."
                )
                result.passages.append(passage)
                return .init(evidence: result, matchedPassageCount: 1)
            }, activity: { _, _ in })
        #expect(executed == [.readMeeting(1, 0)])
        #expect(answer.citations.map(\.sourceKey) == ["S2"])
        #expect(final.passages.count == 2)
        #expect(!answer.coverage.isPartialRecap)
        let requests = await probe.requests
        #expect(requests.count == 2)
        let definitions = try #require(JSONSerialization.jsonObject(with: requests[0].tools) as? [[String: Any]])
        #expect(Set(definitions.compactMap { $0["name"] as? String }) == ["search_meeting_sources", "browse_meeting_sources", "read_meeting_source", "read_full_meeting"])
        let replay = try #require(JSONSerialization.jsonObject(with: requests[1].inputItems) as? [[String: Any]])
        #expect(replay.contains { $0["type"] as? String == "reasoning" && $0["encrypted_content"] as? String == "opaque-test-state" })
        let result = try #require(replay.first { $0["type"] as? String == "function_call_output" })
        #expect(result["call_id"] as? String == "native-call-1")
        #expect((result["output"] as? String)?.contains("Team: Example: Full meeting detail.") == true)
        #expect((result["output"] as? String)?.contains(#"Team\: Example"#) == false)
        #expect(final.passages.last?.excerpt == MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:07", speaker: "Team: Example", text: "Full meeting detail."
        ))
        #expect(!requests[0].base.system.contains("returning exactly {\"tool\""))
    }

    @Test func nativeFullReadRejectsForgedArguments() throws {
        #expect(try MeetingChatNativeHarness.call(name: "read_full_meeting", arguments: #"{"meeting_id":4,"page":0}"#) == .readMeeting(4, 0))
        for bad in [#"{"meeting_id":true,"page":0}"#, #"{"meeting_id":4,"page":-1}"#, #"{"meeting_id":4,"page":10000}"#, #"{"meeting_id":4,"page":0,"scope":"all"}"#] {
            #expect(throws: (any Error).self) { try MeetingChatNativeHarness.call(name: "read_full_meeting", arguments: bad) }
        }
    }

    @Test func nativeCapabilityFollowsProviderNotModelSubstring() {
        let client = MeetingTextGenerationClient()
        var config = AppConfig()
        for backend in ["chatgpt", "openai", "ollama", "custom_llm", "openrouter", "anthropic"] {
            config.meetingSummaryBackend = backend
            #expect(client.supportsNativeTools(config: config) == ["chatgpt", "openai"].contains(backend))
        }
    }

    @Test(arguments: ["chatgpt", "openai"])
    @MainActor func sendsAndRetriesWithSelectedModelAndEffortUnchanged(backend: String) async throws {
        let probe = ChatPromptProbe()
        let (_, coordinator, _) = try coordinatorFixture(generator: probe)
        var config = AppConfig(); config.meetingSummaryBackend = backend
        let provider = MeetingSummaryBackendOption.resolved(backend)
        config[keyPath: provider.modelKeyPath] = "my-selected-catalog-model"
        config.meetingSummaryReasoningEffort = .high
        await coordinator.createChat(scope: .init())
        await coordinator.send(question: "launch", config: config); await coordinator.waitForIdle()
        let turnID = try #require(coordinator.turns.first?.id)
        await coordinator.retry(turnID: turnID, config: config); await coordinator.waitForIdle()
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.config[keyPath: provider.modelKeyPath] == "my-selected-catalog-model" && $0.config.meetingSummaryReasoningEffort == .high })
    }

    @Test func conversationTitlesAreBoundedPlainMetadata() throws {
        let request = try MeetingChatClient.conversationTitleRequest(question: String(repeating: "🌻", count: 5_000), answer: String(repeating: "Source fact ", count: 2_000), config: AppConfig(), sessionID: UUID())
        #expect(request.system.utf8.count + request.user.utf8.count < 4_000)
        #expect(request.maxOutputTokens == 2_048)
        #expect(MeetingChatClient.validatedConversationTitle(#"{"title":"Launch Timing and Decisions"}"#) == "Launch Timing and Decisions")
        #expect(MeetingChatClient.validatedConversationTitle(#"{"title":"Fact [[S1]]"}"#) == nil)
        #expect(MeetingChatClient.validatedConversationTitle(#"{"title":"Title","action":"delete"}"#) == nil)
    }

    @Test @MainActor func backgroundTitleUsesSelectedModelWithoutBlockingAnswerOrManualRename() async throws {
        let gate = ChatTitleGate()
        let (_, coordinator, _) = try coordinatorFixture(generator: gate)
        var config = AppConfig(); config.meetingSummaryBackend = "chatgpt"; config.chatGPTModel = "my-selected-model"; config.meetingSummaryReasoningEffort = .high
        await coordinator.createChat(scope: .init()); let sessionID = try #require(coordinator.selectedSessionID)
        await coordinator.send(question: "launch", config: config)
        await coordinator.waitForIdle(); await gate.waitUntilStarted()
        #expect(!coordinator.isBusy)
        #expect(coordinator.turns.first?.state == .completed)
        let request = try #require(await gate.titleRequest)
        #expect(request.config.chatGPTModel == "my-selected-model")
        #expect(request.config.meetingSummaryReasoningEffort == .high)
        await coordinator.renameChat(id: sessionID, title: "My chosen title")
        await gate.finish()
        await coordinator.waitForTitles()
        #expect(coordinator.sessions.first?.title == "My chosen title")
    }

    @Test @MainActor func successfulTitleUpdatesOriginalChatOnce() async throws {
        let gate = ChatTitleGate()
        let (_, coordinator, _) = try coordinatorFixture(generator: gate)
        await coordinator.createChat(scope: .init()); let sessionID = try #require(coordinator.selectedSessionID)
        await coordinator.send(question: "launch", config: AppConfig()); await coordinator.waitForIdle(); await gate.waitUntilStarted()
        await coordinator.createChat(scope: .init())
        await gate.finish(); await coordinator.waitForTitles()
        #expect(coordinator.sessions.first(where: { $0.id == sessionID })?.title == "Launch Timing and Decisions")
        #expect(coordinator.selectedSessionID != sessionID)
        #expect(coordinator.turns.isEmpty)
    }

    @Test @MainActor func generatedTitleBelongsToOriginalChatAndInvalidatedSourcesCannotRename() async throws {
        let gate = ChatTitleGate()
        let (store, coordinator, id) = try coordinatorFixture(generator: gate)
        await coordinator.createChat(scope: .init()); let sessionID = try #require(coordinator.selectedSessionID)
        await coordinator.send(question: "launch", config: AppConfig()); await coordinator.waitForIdle(); await gate.waitUntilStarted()
        await coordinator.createChat(scope: .init())
        try store.deleteMeeting(id: id)
        await gate.finish(); await coordinator.waitForTitles()
        #expect(coordinator.sessions.first(where: { $0.id == sessionID })?.title != "Launch Timing and Decisions")
        #expect(coordinator.selectedSessionID != sessionID)
    }

    @Test @MainActor func explicitEmptyFollowupUsesConversationWithoutNewRetrieval() async throws {
        let probe = ChatPromptProbe()
        let (_, coordinator, id) = try coordinatorFixture(generator: probe)
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "launch", config: AppConfig()); await coordinator.waitForIdle()
        await coordinator.setScope(.init(selection: .meetings([])))
        coordinator.composerDraft = "Next steps?"
        await coordinator.send(question: coordinator.composerDraft, config: AppConfig()); await coordinator.waitForIdle()
        #expect(!coordinator.isBusy)
        #expect(coordinator.composerDraft.isEmpty)
        #expect(coordinator.turns.count == 2)
        #expect(coordinator.turns.last?.state == .completed)
        #expect(coordinator.turns.last?.citations.isEmpty == true)
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests.last?.user.contains("HISTORICAL_ANSWER") == true)
        #expect(requests.last?.user.contains("QUOTED SOURCES (JSON):\n[]") == true)
    }

    @Test @MainActor func emptyScopeDoesNotReserveBusyStateWhenWorkerStorageIsBlocked() async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, _) = try coordinatorFixture(generator: probe)
        await coordinator.createChat(scope: .init(selection: .meetings([])))
        let sessionID = try #require(coordinator.selectedSessionID)
        var db: OpaquePointer?
        let opened = sqlite3_open(store.resolvedDatabaseURL.path, &db)
        #expect(opened == SQLITE_OK)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let blockedWriter = Task { await coordinator.renameChat(id: sessionID, title: "Test chat") }
        await Task.yield()
        coordinator.composerDraft = "Next steps?"
        let clock = ContinuousClock(); let start = clock.now
        await coordinator.send(question: coordinator.composerDraft, config: AppConfig())
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(!coordinator.isBusy)
        #expect(coordinator.composerDraft == "Next steps?")
        #expect(coordinator.turns.isEmpty)
        #expect(await probe.requests.isEmpty)
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        await blockedWriter.value
    }

    @Test func chatGPTStreamHasAbsoluteResourceDeadline() {
        let configuration = ChatGPTResponsesTransport.sessionConfiguration()
        #expect(configuration.timeoutIntervalForResource == 180)
        #expect(configuration.timeoutIntervalForRequest == 120)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.urlCache == nil)
    }

    @Test func reasoningSummariesUseOnlyExplicitSummaryEvents() {
        var accumulator = ChatGPTReasoningSummaryAccumulator()
        let ignoredRawReasoning = accumulator.apply(["type": "response.reasoning_text.delta", "item_id": "r1", "output_index": 0, "summary_index": 0, "delta": "HIDDEN_REASONING"])
        #expect(!ignoredRawReasoning)
        let firstDeltaChanged = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "r1", "output_index": 0, "summary_index": 0, "delta": "Checking "])
        #expect(firstDeltaChanged)
        let secondDeltaChanged = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "r1", "output_index": 0, "summary_index": 0, "delta": "meeting sources."])
        #expect(secondDeltaChanged)
        let completedChanged = accumulator.apply(["type": "response.reasoning_summary_text.done", "item_id": "r1", "output_index": 0, "summary_index": 0, "text": "Checking meeting sources."])
        #expect(!completedChanged)
        #expect(accumulator.text == "Checking meeting sources.")
        #expect(!accumulator.text.contains("HIDDEN_REASONING"))
        let payload: [String: Any] = ["output": [["type": "reasoning", "content": [["text": "HIDDEN_REASONING"]]], ["type": "message", "content": [["text": "Final answer"]]]]]
        #expect(ChatGPTResponsesClient.extractOutputText(from: payload) == "Final answer")
    }

    @Test func reasoningSummariesOrderInterleavedPartsAndIgnoreLateDeltas() {
        var accumulator = ChatGPTReasoningSummaryAccumulator()
        _ = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "b", "output_index": 2, "summary_index": 0, "delta": "Third"])
        _ = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "a", "output_index": 0, "summary_index": 1, "delta": "Second"])
        _ = accumulator.apply(["type": "response.reasoning_summary_part.done", "item_id": "a", "output_index": 0, "summary_index": 0, "part": ["type": "summary_text", "text": "First"]])
        #expect(accumulator.text == "First\n\nSecond\n\nThird")
        let late = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "a", "output_index": 0, "summary_index": 0, "delta": " duplicated"])
        let duplicate = accumulator.apply(["type": "response.reasoning_summary_text.done", "item_id": "a", "output_index": 0, "summary_index": 0, "text": "First"])
        #expect(!late && !duplicate)
        #expect(accumulator.text == "First\n\nSecond\n\nThird")
    }

    @Test func reasoningFinalSnapshotReconcilesWithoutExposingPrivateContent() {
        var accumulator = ChatGPTReasoningSummaryAccumulator()
        _ = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "a", "output_index": 0, "summary_index": 0, "delta": "Partial"])
        let final: [String: Any] = ["type": "response.output_item.done", "output_index": 0,
            "item": ["id": "a", "type": "reasoning", "encrypted_content": "SECRET", "content": [["type": "reasoning_text", "text": "HIDDEN"]],
                     "summary": [["type": "summary_text", "text": "Final public summary"], ["type": "reasoning_text", "text": "HIDDEN"]]]]
        let changed = accumulator.apply(final)
        let duplicate = accumulator.apply(final)
        let late = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "a", "output_index": 0, "summary_index": 1, "delta": "Late"])
        #expect(changed && !duplicate && !late)
        #expect(accumulator.text == "Final public summary")
        let unrelated = accumulator.apply(["type": "response.output_item.done", "output_index": 1, "item": ["id": "m", "type": "message", "summary": [["type": "summary_text", "text": "NOT_REASONING"]]]])
        #expect(!unrelated)
    }

    @Test func reasoningSummaryRejectsInvalidIndicesAndBoundsFinalSnapshots() {
        var accumulator = ChatGPTReasoningSummaryAccumulator()
        for (output, summary) in [(-1, 0), (0, -1), (0, 32)] {
            let changed = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "a", "output_index": output, "summary_index": summary, "delta": "INVALID"])
            #expect(!changed)
        }
        let parts = (0..<40).map { index in ["type": "summary_text", "text": "Part \(index)"] }
        _ = accumulator.apply(["type": "response.output_item.done", "output_index": 0, "item": ["id": "a", "type": "reasoning", "summary": parts]])
        #expect(accumulator.text.contains("Part 31"))
        #expect(!accumulator.text.contains("Part 32"))
        _ = accumulator.apply(["type": "response.output_item.done", "output_index": 0, "item": ["id": "a", "type": "reasoning", "summary": [["type": "summary_text", "text": String(repeating: "x", count: 8_000)]]]])
        #expect(accumulator.text.count == 6_000)
    }

    @Test func reasoningSummaryRequestsAreOptInAndRespectModelCapabilities() {
        let summary = ChatGPTResponsesClient.requestBody(systemPrompt: "S", userPrompt: "U", model: "gpt-6.1-sol", reasoningEffort: .low, includeReasoningSummary: true)
        #expect((summary["reasoning"] as? [String: String])?["summary"] == "auto")
        let off = ChatGPTResponsesClient.requestBody(systemPrompt: "S", userPrompt: "U", model: "gpt-6-luna", reasoningEffort: .off, includeReasoningSummary: true)
        #expect((off["reasoning"] as? [String: String])?["summary"] == nil)
        let normal = ChatGPTResponsesClient.requestBody(systemPrompt: "S", userPrompt: "U", model: "gpt-6.1-sol", reasoningEffort: .low)
        #expect((normal["reasoning"] as? [String: String])?["summary"] == nil)
        var accumulator = ChatGPTReasoningSummaryAccumulator()
        _ = accumulator.apply(["type": "response.reasoning_summary_text.delta", "item_id": "r1", "output_index": 0, "summary_index": 0, "delta": String(repeating: "a", count: 8_000)])
        #expect(accumulator.text.count == 6_000)
    }

    @Test @MainActor func sourceDeletionScrubsLateReasoningSummaryBeforeUIRefresh() async throws {
        let gate = ChatSummaryGate()
        let (store, coordinator, id) = try coordinatorFixture(generator: gate)
        await coordinator.createChat(scope: .init())
        await coordinator.send(question: "launch", config: AppConfig())
        await gate.waitUntilStarted()
        #expect(coordinator.reasoningSummaries == ["Provider summary"])
        try store.deleteMeeting(id: id)
        await gate.finish(); await coordinator.waitForIdle()
        #expect(coordinator.reasoningSummaries.isEmpty)
        #expect(coordinator.activityTurnID == nil)
        #expect(coordinator.turns.first?.state == .sourceDeleted)
    }

    private func priorExchange() -> MeetingChatTurn {
        .init(id: UUID(), sessionID: UUID(), ordinal: 0, question: "Summarize launch",
            scope: .init(selection: .meetings([1])), state: .completed,
            originalAnswer: "The launch is Friday [[S1]].", citations: [], provider: "test", model: "test")
    }

    @Test func conversationalRepliesNeedUsableHistoryButNoNewCitations() throws {
        var empty = evidence(); empty.passages = []
        let raw = #"{"status":"conversation","markdown":"Suggestion: confirm the launch checklist."}"#
        let answer = try MeetingChatClient.validateResponse(raw, evidence: empty, history: [priorExchange()])
        #expect(!answer.insufficientEvidence)
        #expect(answer.citations.isEmpty)
        #expect(throws: MeetingChatError.self) { try MeetingChatClient.validateResponse(raw, evidence: empty) }
        var deleted = priorExchange(); deleted.state = .sourceDeleted
        #expect(throws: MeetingChatError.self) { try MeetingChatClient.validateResponse(raw, evidence: empty, history: [deleted]) }
        #expect(throws: MeetingChatError.self) {
            try MeetingChatClient.validateResponse(#"{"status":"answered","markdown":"Friday [[S1]]"}"#, evidence: empty, history: [priorExchange()])
        }
    }

    @Test @MainActor func historyOnlyTransformationDoesNotRunRetrieval() async throws {
        var empty = evidence(); empty.passages = []; empty.coverage.eligibleMeetingCount = 0
        empty.coverage.evidenceMeetingCount = 0
        let generator = ChatScriptedReplies(replies: [#"{"status":"conversation","markdown":"Suggestion: review the launch checklist."}"#])
        let (answer, _) = try await MeetingChatClient.run(question: "Next steps?", evidence: empty, history: [priorExchange()], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in Issue.record("Conversation-only followup must not retrieve"); return .init(evidence: current) }, activity: { _, _ in })
        #expect(!answer.insufficientEvidence)
        let requests = await generator.requests
        #expect(requests.count == 1)
        #expect(requests[0].user.contains("The launch is Friday"))
        #expect(!requests[0].user.contains("[[S1]]"))
        #expect(requests[0].system.contains("Retrieval tools are unavailable"))
    }

    @Test @MainActor func newMeetingFactsCanRetrieveLazilyFromSafeConversation() async throws {
        var empty = evidence(); empty.passages = []
        let generator = ChatScriptedReplies(replies: [#"{"tool":"search_meeting_sources","query":"launch owner"}"#, #"{"status":"answered","markdown":"Friday [[S1]]"}"#])
        var calls: [MeetingChatToolCall] = []
        let (answer, _) = try await MeetingChatClient.run(question: "What did we agree in the meeting?", evidence: empty, history: [priorExchange()], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { call, _ in calls.append(call); return .init(evidence: evidence()) }, activity: { _, _ in })
        #expect(calls == [.search("launch owner")])
        #expect(answer.citations.map(\.sourceKey) == ["S1"])
    }

    @Test @MainActor func removedScopeCannotRetrieveNewFactsThroughConversationMode() async throws {
        var empty = evidence(); empty.passages = []; empty.coverage.eligibleMeetingCount = 0
        let generator = ChatScriptedReplies(replies: [#"{"tool":"search_meeting_sources","query":"launch owner"}"#, #"{"status":"insufficient_evidence","markdown":"Attach a meeting to check who was assigned."}"#])
        let (answer, _) = try await MeetingChatClient.run(question: "Who was assigned?", evidence: empty, history: [priorExchange()], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in Issue.record("Empty search scope must not retrieve"); return .init(evidence: current) }, activity: { _, _ in })
        #expect(answer.insufficientEvidence)
        #expect(await generator.requests.count == 2)
    }

    @Test func validatesRetrievalToolArguments() throws {
        #expect(try MeetingChatClient.parseToolCall(#"{"tool":"search_meeting_sources","query":" release date "}"#) == .search("release date"))
        #expect(try MeetingChatClient.parseToolCall(#"{"tool":"read_meeting_source","source":"S2"}"#) == .read("S2"))
        #expect(try MeetingChatClient.parseToolCall(#"{"tool":"browse_meeting_sources"}"#) == .browse)
        for invalid in [#"{"tool":"shell","query":"ls"}"#, #"{"tool":"search_meeting_sources","query":"","scope":"all"}"#, #"{"tool":"read_meeting_source","source":"../secret"}"#] {
            #expect(throws: MeetingChatError.self) { try MeetingChatClient.parseToolCall(invalid) }
        }
    }

    @Test @MainActor func toolLoopFeedsResultsBackAndKeepsSessionIdentity() async throws {
        let generator = ChatScriptedReplies(replies: [#"{"tool":"search_meeting_sources","query":"launch"}"#, #"{"status":"answered","markdown":"Ship Friday [[S1]]"}"#])
        var empty = evidence(); empty.passages = []; empty.dependencies = []
        let sessionID = UUID()
        var calls: [MeetingChatToolCall] = []
        let (answer, _) = try await MeetingChatClient.run(question: "When is it?", evidence: empty, history: [], config: AppConfig(), sessionID: sessionID, generator: generator,
            execute: { call, _ in calls.append(call); return .init(evidence: evidence()) }, activity: { _, _ in })
        #expect(calls == [.search("launch")])
        #expect(answer.citations.count == 1)
        let requests = await generator.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.sessionID == sessionID })
        #expect(requests[1].user.contains("Ship Friday"))
        #expect(requests[1].user.contains("QUOTED TOOL HISTORY"))
        #expect(requests[0].system.contains("For a final answer, return exactly two keys"))
        #expect(requests[0].system.contains("The final-answer schema does not apply to tool requests"))
        #expect(requests[0].system.contains("never status or markdown"))
        #expect(!requests[0].system.contains("Return only JSON with exactly two keys"))
    }

    @Test @MainActor func toolLoopCannotExceedBudget() async throws {
        let generator = ChatScriptedReplies(replies: (1...5).map { "{\"tool\":\"search_meeting_sources\",\"query\":\"query \($0)\"}" })
        var calls = 0
        do {
            _ = try await MeetingChatClient.run(question: "Find it", evidence: evidence(), history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
                execute: { _, current in calls += 1; return .init(evidence: current) }, activity: { _, _ in })
            Issue.record("Expected budget rejection")
        } catch { #expect(error is MeetingChatHarnessError) }
        #expect(calls == 3)
        #expect(await generator.requests.count == 5)
    }

    @Test @MainActor func exhaustedToolBudgetGetsOneFinalizationPass() async throws {
        let tools = (1...4).map { "{\"tool\":\"search_meeting_sources\",\"query\":\"query \($0)\"}" }
        let generator = ChatScriptedReplies(replies: tools + [#"{"status":"answered","markdown":"Friday [[S1]]"}"#])
        var executions = 0
        let (answer, _) = try await MeetingChatClient.run(question: "When?", evidence: evidence(), history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in executions += 1; return .init(evidence: current) }, activity: { _, _ in })
        #expect(executions == 3)
        #expect(await generator.requests.count == 5)
        #expect(answer.citations.count == 1)
    }

    @Test @MainActor func sourceReadUsesAdjacentPassagesAndPreservesScope() async throws {
        let generator = ChatScriptedReplies(replies: [#"{"tool":"read_meeting_source","source":"S1"}"#, #"{"status":"answered","markdown":"Launch Monday [[S2]]"}"#])
        let (store, coordinator, id) = try coordinatorFixture(generator: generator)
        try store.updateMeetingTranscript(id: id, rawTranscript: "Launch Friday\nActually Monday is agreed.")
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "Friday", config: AppConfig()); await coordinator.waitForIdle()
        let requests = await generator.requests
        #expect(requests.count == 2)
        #expect(requests.last?.user.contains("Actually Monday is agreed") == true)
        #expect(coordinator.turns.first?.state == .completed)
        #expect(coordinator.turns.first?.citations.first?.meetingID == id)
    }

    @Test @MainActor func emptyScopeDoesNotContactProvider() async throws {
        let generator = ChatScriptedReplies(replies: [])
        var empty = evidence(); empty.passages = []; empty.dependencies = []
        empty.coverage.eligibleMeetingCount = 0
        let (answer, _) = try await MeetingChatClient.run(question: "Anything?", evidence: empty, history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in Issue.record("Unexpected tool execution"); return .init(evidence: current) }, activity: { _, _ in })
        #expect(answer.insufficientEvidence)
        #expect(await generator.requests.isEmpty)
    }

    @Test @MainActor func repeatedCallFinalizesWithoutExecutingAgain() async throws {
        let repeated = #"{"tool":"search_meeting_sources","query":"launch"}"#
        let generator = ChatScriptedReplies(replies: [repeated, repeated, #"{"status":"answered","markdown":"Friday [[S1]]"}"#])
        var executions = 0
        let (answer, _) = try await MeetingChatClient.run(question: "When?", evidence: evidence(), history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in executions += 1; return .init(evidence: current) }, activity: { _, _ in })
        #expect(executions == 1)
        #expect(answer.citations.count == 1)
        #expect(await generator.requests.last?.system.contains("Retrieval tools are unavailable") == true)
    }

    @Test @MainActor func malformedAnswerGetsOneFormatRepair() async throws {
        let generator = ChatScriptedReplies(replies: ["Friday", #"{"status":"answered","markdown":"Friday [[S1]]"}"#])
        let (answer, _) = try await MeetingChatClient.run(question: "When?", evidence: evidence(), history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in Issue.record("Unexpected tool execution"); return .init(evidence: current) }, activity: { _, _ in })
        #expect(answer.citations.count == 1)
        #expect(await generator.requests.count == 2)
    }

    @Test(arguments: [
        ("not JSON", "Formatting answer"),
        (#"{"status":"answered","markdown":"Friday"}"#, "Checking source references"),
        (#"{"status":"answered","markdown":"Friday [[S999]]"}"#, "Checking source references"),
        (#"{"status":"conversation","markdown":"As discussed earlier"}"#, "Checking conversation context"),
        (#"{"tool":"unavailable_tool"}"#, "Preparing final answer"),
        (String(repeating: "x", count: 64_001), "Shortening answer")
    ]) @MainActor func repairProgressDescribesTheActualValidationIssue(raw: String, expected: String) async throws {
        let generator = ChatScriptedReplies(replies: [raw, #"{"status":"answered","markdown":"Friday [[S1]]"}"#])
        var progress: [String] = []
        let (answer, _) = try await MeetingChatClient.run(question: "When?", evidence: evidence(), history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
            execute: { _, current in Issue.record("Unexpected tool execution"); return .init(evidence: current) }, activity: { _, _ in }, progress: { progress.append($0) })
        #expect(answer.citations.count == 1)
        #expect(progress.first == "Preparing answer")
        // Successful final validation adds the last source-check event; the
        // preceding event describes the specific reason for the repair request.
        #expect(progress.dropLast().last == expected)
        #expect(!progress.contains("Retrying answer format"))
        #expect(await generator.requests.count == 2)
        #expect(await generator.requests.last?.system.contains("Do not request a tool") == true)
    }

    @Test @MainActor func repeatedInvalidCitationsHavePrecisePrivateDiagnostic() async throws {
        let raw = #"{"status":"answered","markdown":"PRIVATE_MODEL_OUTPUT [[S999]]"}"#
        let generator = ChatScriptedReplies(replies: [raw, raw])
        do {
            _ = try await MeetingChatClient.run(question: "When?", evidence: evidence(), history: [], config: AppConfig(), sessionID: UUID(), generator: generator,
                execute: { _, current in Issue.record("Unexpected tool execution"); return .init(evidence: current) }, activity: { _, _ in })
            Issue.record("Expected invalid citation failure")
        } catch {
            #expect(error is MeetingChatHarnessError)
            #expect(error.localizedDescription.contains("outside the retrieved context"))
            #expect(!error.localizedDescription.contains("PRIVATE_MODEL_OUTPUT"))
        }
        #expect(await generator.requests.count == 2)
        #expect(await generator.requests.last?.user.contains("PRIVATE_MODEL_OUTPUT") == false)
    }

    @Test @MainActor func emptySearchPreservesEvidenceAndReportsZeroMatches() async throws {
        let generator = ChatScriptedReplies(replies: [#"{"tool":"search_meeting_sources","query":"zznomatch"}"#, #"{"tool":"search_meeting_sources","query":"launch"}"#, #"{"status":"answered","markdown":"Friday [[S1]]"}"#])
        let (_, coordinator, id) = try coordinatorFixture(generator: generator)
        await coordinator.createChat(scope: .init(selection: .meetings([id])))
        await coordinator.send(question: "launch", config: AppConfig()); await coordinator.waitForIdle()
        let requests = await generator.requests
        #expect(requests.count == 3)
        #expect(requests[1].user.contains("Tool returned 0 matching passages"))
        #expect(requests[1].user.contains("Launch Friday"))
        #expect(requests[2].user.contains("\"id\":\"S1\""))
        #expect(requests.allSatisfy { $0.system.utf8.count + $0.user.utf8.count <= 28_000 })
        #expect(coordinator.turns.first?.state == .completed)
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

    @Test(arguments: ["openai", "anthropic", "openrouter", "ollama", "lmstudio", "custom_llm"])
    func buildsRequestForSelectedProvider(backend: String) throws {
        var config = AppConfig(); config.meetingSummaryBackend = backend
        config.openAIModel = "test-model"; config.openRouterModel = "test-model"; config.ollamaModel = "test-model"
        config.anthropicModel = "test-model"
        config.lmStudioModel = "test-model"; config.customLLMModel = "test-model"; config.customLLMURL = "http://localhost:1234"
        let request = try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config), credential: "synthetic-test-key")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "test-model")
        #expect(request.httpMethod == "POST")
        if backend == "openai" { #expect(body["store"] as? Bool == false) }
    }
    @Test(arguments: [ReasoningEffort.off, .low, .high])
    func openAIReasoningBudgetIncludesVisibleAnswer(effort: ReasoningEffort) throws {
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        config.openAIModel = "gpt-5.4-mini"; config.meetingSummaryReasoningEffort = effort
        let request = try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config), credential: "synthetic")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_output_tokens"] as? Int == (effort == .off ? 1_500 : 32_768))
        #expect((body["reasoning"] as? [String: String])?["effort"] == effort.rawValue)
    }

    @Test func nonReasoningOpenAIPreservesRequestedBudget() throws {
        var config = AppConfig(); config.meetingSummaryBackend = "openai"; config.openAIModel = "gpt-4o"
        let request = try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config, maxOutputTokens: 2_048), credential: "synthetic")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_output_tokens"] as? Int == 2_048)
        #expect(body["reasoning"] == nil)
    }

    @Test(arguments: [1_500, 40_000]) func ollamaBudgetAccommodatesThinking(requested: Int) throws {
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"; config.ollamaModel = "qwen3.5"
        let request = try MeetingTextGenerationClient.makeRequest(.init(system: "System", user: "User", config: config, maxOutputTokens: requested), credential: "")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["options"] as? [String: Int])?["num_predict"] == max(requested, 8_192))
        #expect(body["reasoning"] == nil)
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

    @Test func claudeCodeUsesConfiguredBridgeWithoutStartingARealProcess() async throws {
        var config = AppConfig(); config.meetingSummaryBackend = "claude_code"
        let generator = MeetingTextGenerationClient(claudeCode: { request in
            #expect(request.system == "System")
            return "synthetic CLI reply"
        })
        #expect(try await generator.generate(.init(system: "System", user: "User", config: config)) == "synthetic CLI reply")
    }

    @Test func customGatewayHeadersAndCredentialCommandRouteArePreserved() async throws {
        var config = AppConfig(); config.meetingSummaryBackend = "custom_llm"; config.customLLMModel = "test"
        config.customLLMHeaders = [.init(name: "X-Gateway", value: "synthetic")]
        config.customLLMAPIKeyCommand = "synthetic-command-not-executed"
        let generator = MeetingTextGenerationClient(credentialResolver: { _ in "synthetic-resolved" }, load: { request in
            #expect(request.value(forHTTPHeaderField: "X-Gateway") == "synthetic")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-resolved")
            return (Data(#"{"choices":[{"message":{"content":"reply"}}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await generator.generate(.init(system: "System", user: "User", config: config)) == "reply")
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
        await coordinator.createChat(scope: .init()); await coordinator.send(question: "launch", config: AppConfig())
        await gate.waitUntilStarted()
        try store.deleteMeeting(id: id)
        await gate.finish(); await coordinator.waitForIdle()
        #expect(coordinator.turns.first?.state == .sourceDeleted)
        #expect(coordinator.turns.first?.originalAnswer == nil)
    }

    @Test @MainActor func switchChatPreservesReplyOwner() async throws {
        let gate = ChatReplyGate()
        let (store, coordinator, _) = try coordinatorFixture(generator: gate)
        await coordinator.createChat(scope: .init())
        let original = try #require(coordinator.selectedSessionID)
        await coordinator.send(question: "launch", config: AppConfig()); await gate.waitUntilStarted()
        await coordinator.createChat(scope: .init())
        await gate.finish(); await coordinator.waitForIdle()
        #expect(coordinator.turns.isEmpty)
        #expect(try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).turns(sessionID: original).first?.state == .completed)
    }

    @Test @MainActor func retryReusesQuestionAndScopeChangesKeepValidConversation() async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, id) = try coordinatorFixture(generator: probe)
        await coordinator.createChat(scope: .init()); await coordinator.send(question: "launch", config: AppConfig())
        await coordinator.waitForIdle()
        let first = try #require(coordinator.turns.first)
        await coordinator.retry(turnID: first.id, config: AppConfig()); await coordinator.waitForIdle()
        #expect(coordinator.turns.count == 1)
        await coordinator.setScope(.init(selection: .meetings([id])))
        await coordinator.setScope(.init())
        await coordinator.send(question: "launch follow-up", config: AppConfig()); await coordinator.waitForIdle()
        let requests = await probe.requests
        #expect(requests.last!.user.contains("HISTORICAL_ANSWER"))
        #expect(try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).turns(sessionID: coordinator.selectedSessionID!).count == 2)
    }

    @Test @MainActor func deletingBackgroundChatCancelsItsRequest() async throws {
        let gate = ChatReplyGate()
        let (_, coordinator, _) = try coordinatorFixture(generator: gate)
        await coordinator.createChat(scope: .init()); let original = coordinator.selectedSessionID!
        await coordinator.send(question: "launch", config: AppConfig()); await gate.waitUntilStarted()
        await coordinator.createChat(scope: .init()); await coordinator.deleteChat(id: original)
        #expect(!coordinator.isBusy)
        await gate.finish(); await coordinator.waitForIdle()
    }

    @Test @MainActor func editedSourceDoesNotBlockFreshFollowUp() async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, id) = try coordinatorFixture(generator: probe)
        await coordinator.createChat(scope: .init()); await coordinator.send(question: "launch", config: AppConfig()); await coordinator.waitForIdle()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Launch Monday")
        await coordinator.send(question: "launch now?", config: AppConfig()); await coordinator.waitForIdle()
        #expect(coordinator.turns.last?.state == .completed)
        #expect(await probe.requests.count == 2)
    }

    @Test(arguments: ["What decisions did we make about sunflower?", "Sunflower decisions", "Draft a follow-up on sunflower", "Next steps for sunflower"])
    @MainActor func targetedDecisionQuestionKeepsOldRelevantMeeting(question: String) async throws {
        let probe = ChatPromptProbe()
        let (store, coordinator, _) = try coordinatorFixture(generator: probe)
        _ = try store.insertMeeting(title: "Sunflower", calendarEventID: nil, startTime: Date(timeIntervalSince1970: 1_000), endTime: Date(timeIntervalSince1970: 1_060), rawTranscript: "The sunflower contract was approved.", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        for _ in 0..<300 { _ = try store.insertMeeting(title: "Routine", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "Unrelated check-in.", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil) }
        await coordinator.createChat(scope: .init())
        await coordinator.send(question: question, config: AppConfig())
        await coordinator.waitForIdle()
        #expect(await probe.requests.last?.user.contains("The sunflower contract was approved.") == true)
    }

    @Test @MainActor func clearingHistoryCancelsSuspendedGenerationAndClearsVisibleTurns() async throws {
        let gate = ChatReplyGate()
        let (store, coordinator, _) = try coordinatorFixture(generator: gate)
        let directory = store.resolvedDatabaseURL.deletingLastPathComponent().appendingPathComponent("chat-wipe-support-\(UUID())")
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil), dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        controller.meetingChatCoordinator = coordinator
        await coordinator.createChat(scope: .init()); await coordinator.send(question: "launch", config: AppConfig())
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
        await coordinator.createChat(scope: .init())
        await coordinator.send(question: "launch", config: AppConfig())
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
        if request.user.contains("QUOTED SOURCES (JSON):\n[]"), request.user.contains("HISTORICAL_ANSWER") {
            return #"{"status":"conversation","markdown":"Suggestion: confirm the launch plan with the team."}"#
        }
        return #"{"status":"answered","markdown":"HISTORICAL_ANSWER Friday [[S1]]"}"#
    }
}

private actor ChatScriptedReplies: MeetingTextGenerating {
    var replies: [String]
    var requests: [MeetingTextGenerationRequest] = []
    init(replies: [String]) { self.replies = replies }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request)
        guard !replies.isEmpty else { throw MeetingChatError.invalidResponse }
        return replies.removeFirst()
    }
}

private actor ChatSummaryGate: MeetingTextGenerating {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        await request.onReasoningSummary?("Provider summary")
        started = true
        await withCheckedContinuation { continuation = $0 }
        await request.onReasoningSummary?("Late provider summary")
        return #"{"status":"answered","markdown":"Friday [[S1]]"}"#
    }
    func waitUntilStarted() async {
        for _ in 0..<500 where !started { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor ChatTitleGate: MeetingTextGenerating {
    var titleRequest: MeetingTextGenerationRequest?
    private var continuation: CheckedContinuation<String?, Never>?
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        #"{"status":"answered","markdown":"Friday [[S1]]"}"#
    }
    func generateConversationTitle(_ request: MeetingTextGenerationRequest) async throws -> String? {
        titleRequest = request
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<500 where titleRequest == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func finish() { continuation?.resume(returning: #"{"title":"Launch Timing and Decisions"}"#); continuation = nil }
}

private actor NativeHarnessProbe: MeetingTextGenerating {
    private(set) var requests: [MeetingNativeToolRequest] = []
    nonisolated func supportsNativeTools(config: AppConfig) -> Bool { true }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        Issue.record("Native-capable provider must not use JSON-in-text tool requests")
        return ""
    }
    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        requests.append(request)
        if requests.count == 1 {
            let output: [[String: Any]] = [["type": "reasoning", "encrypted_content": "opaque-test-state"],
                ["type": "function_call", "name": "read_full_meeting", "call_id": "native-call-1", "arguments": #"{"meeting_id":1,"page":0}"#]]
            return .init(outputItems: try JSONSerialization.data(withJSONObject: output), calls: [.init(id: "native-call-1", name: "read_full_meeting", arguments: #"{"meeting_id":1,"page":0}"#)], text: "")
        }
        return .init(outputItems: Data("[]".utf8), calls: [], text: #"{"status":"answered","markdown":"Full meeting detail [[S2]]"}"#)
    }
}
