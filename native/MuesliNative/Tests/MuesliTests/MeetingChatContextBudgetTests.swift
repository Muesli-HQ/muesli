import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting chat context budget")
struct MeetingChatContextBudgetTests {
    private func turn(_ ordinal: Int, answer: String) -> MeetingChatTurn {
        .init(id: UUID(), sessionID: UUID(), ordinal: ordinal, question: "Question",
              scope: .init(), state: .completed, originalAnswer: answer,
              citations: [], provider: "test", model: "test")
    }

    @Test func smallNativeWindowCapsActualOutputRequestAndCompaction() throws {
        var config = AppConfig(); config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIModel = "gpt-6-sol"
        let budget = MeetingChatContextBudget(config: config, contextWindowTokens: 16_384)
        #expect(budget.maximumInputTokens + budget.maximumOutputTokens <= 16_384)
        let base = MeetingTextGenerationRequest(system: "System", user: "Question", config: config,
            maxOutputTokens: 32_768, outputTokenLimit: budget.maximumOutputTokens)
        let body = try MeetingNativeToolTransport.requestBody(.init(base: base, inputItems: Data("[]".utf8), tools: Data("[]".utf8), allowTools: true), stream: false)
        #expect(body["max_output_tokens"] as? Int == budget.maximumOutputTokens)
        let request = try MeetingTextGenerationClient.makeRequest(base, credential: "synthetic")
        let data = try #require(request.httpBody)
        let textBody = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(textBody?["max_output_tokens"] as? Int == budget.maximumOutputTokens)
    }

    @Test func oversizedNewestTurnIsCompressedInsteadOfSkipped() {
        let policy = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 8_192)
        let older = turn(0, answer: "Short")
        let latest = turn(1, answer: String(repeating: "x", count: policy.historyTokens * 3 + 1))
        let plan = policy.plan(history: [older, latest])
        #expect(plan.recentTurns.isEmpty)
        #expect(plan.olderTurns.map(\.id) == [older.id, latest.id])
    }

    @Test func summaryBoundaryAndRecentSuffixPreserveChronology() {
        let policy = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 8_192)
        let first = turn(0, answer: "Already summarized")
        let middle = turn(1, answer: String(repeating: "x", count: policy.historyTokens * 3))
        let last = turn(2, answer: "Recent reply")
        let plan = policy.plan(history: [last, first, middle], existingSummaryThroughOrdinal: 0)
        #expect(plan.olderTurns.map(\.id) == [middle.id])
        #expect(plan.recentTurns.map(\.id) == [last.id])
    }

    @Test func byteEstimateAccountsForUnicodeAndEnvelope() {
        #expect(MeetingChatContextBudget.estimateTokens("🙂") == 36)
        let small = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 4_096)
        let large = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 65_536)
        #expect(small.maximumInputTokens < large.maximumInputTokens)
        #expect(small.historyTokens < large.historyTokens)
    }

    @Test func largeASCIIToolPacketFitsNativeOperationalBudget() {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend
        let policy = MeetingChatContextBudget(config: config)
        let toolPacket = String(repeating: "a", count: 40_000)
        let schemas = String(repeating: "s", count: 7_000)
        #expect(MeetingChatContextBudget.estimateTokens(toolPacket) + MeetingChatContextBudget.estimateTokens(schemas)
                + policy.historyTokens + policy.summaryTokens < policy.maximumInputTokens)
        #expect(MeetingChatContextBudget.estimateTokens("abc") == 33)
        #expect(MeetingChatContextBudget.estimateTokens("abcd") == 34)
        #expect(MeetingChatContextBudget.estimateTokens("abc🙂") == 37)
    }

    @Test func oversizedSummaryRetriesOriginalContextOnce() async throws {
        let generator = SummaryBudgetProbe(outputs: [String(repeating: "x", count: 10_000), "Short summary"])
        let policy = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 8_192)
        let result = try await policy.summarize(olderTurns: [], previousSummary: "Original context",
            config: AppConfig(), sessionID: UUID(), generator: generator)
        #expect(result == "Short summary")
        let requests = await generator.requests
        #expect(requests.count == 2)
        #expect(requests[0].user == requests[1].user)
        #expect(requests[1].system.contains("Regenerate a substantially shorter"))
    }

    @Test func repeatedlyOversizedSummaryFailsWithoutTruncation() async {
        let generator = SummaryBudgetProbe(outputs: [String(repeating: "x", count: 10_000), String(repeating: "x", count: 10_000)])
        let policy = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 8_192)
        do {
            _ = try await policy.summarize(olderTurns: [], previousSummary: "Context", config: AppConfig(), sessionID: UUID(), generator: generator)
            Issue.record("Expected oversized summary failure")
        } catch MeetingChatContextBudget.SummaryError.outputTooLarge {
            #expect(await generator.requests.count == 2)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func invalidatedContextStopsBeforeRetry() async {
        let generator = SummaryBudgetProbe(outputs: [String(repeating: "x", count: 10_000)])
        let validation = SummaryContextValidationProbe()
        let policy = MeetingChatContextBudget(config: AppConfig(), contextWindowTokens: 8_192)
        do {
            _ = try await policy.summarize(olderTurns: [], previousSummary: "Context", config: AppConfig(),
                sessionID: UUID(), generator: generator, validateContext: { try await validation.validate() })
            Issue.record("Expected invalidated context failure")
        } catch SummaryContextValidationProbe.Invalidated.changed {
            #expect(await generator.requests.count == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func existingSummaryCanBeRecompressedWithoutNewTurns() async throws {
        let generator = SummaryBudgetProbe()
        let config = AppConfig()
        let policy = MeetingChatContextBudget(config: config, contextWindowTokens: 8_192)
        let result = try await policy.summarize(olderTurns: [], previousSummary: "Previous conversation",
            config: config, sessionID: UUID(), generator: generator)
        #expect(result == "Compressed context")
        let requests = await generator.requests
        #expect(requests.count == 1)
        #expect(requests[0].user.contains("Previous conversation"))
        #expect(MeetingTextGenerationClient.model(requests[0].config) == MeetingTextGenerationClient.model(config))
        #expect(requests[0].config.meetingSummaryReasoningEffort == config.meetingSummaryReasoningEffort)
    }
    @Test @MainActor func localCompatibilityPacketsFitWithToolsAndUnicodeAcrossIterations() async throws {
        for provider in [MeetingSummaryBackendOption.ollama, .customLLM, .lmStudio] {
            for unicode in [false, true] {
                var config = AppConfig(); config.meetingSummaryBackend = provider.backend
                let budget = MeetingChatContextBudget(config: config)
                #expect(budget.maximumInputTokens == 4_096)
                #expect(budget.maximumOutputTokens == 4_096)
                let excerpt = String(repeating: unicode ? "計画🌻" : "plan ", count: 250)
                let passages = (1...9).map { index in
                    MeetingChatPassage(id: "p\(index)", sourceKey: "S\(index)", meetingID: 1, title: "Planning",
                        startDate: Date(timeIntervalSince1970: 1_000), kind: .transcript, excerpt: excerpt,
                        range: .init(location: index * 10_000, length: excerpt.utf16.count), revision: "r1")
                }
                let evidence = MeetingChatEvidence(scope: .init(selection: .meetings([1])), passages: passages,
                    dependencies: [.init(meetingID: 1, revision: "r1")],
                    coverage: .init(eligibleMeetingCount: 1, evidenceMeetingCount: 1, isPartialRecap: false))
                let probe = SmallContextCompatibilityProbe()
                let (_, fitted) = try await MeetingChatClient.run(question: "What is the plan?", evidence: evidence, history: [],
                    config: config, sessionID: UUID(), generator: probe,
                    execute: { _, _ in .init(evidence: evidence, matchedPassageCount: passages.count) }, activity: { _, _ in })
                let requests = await probe.requests
                #expect(requests.count == 2)
                for request in requests {
                    #expect(MeetingChatContextBudget.estimateTokens(request.system + request.user) <= budget.maximumInputTokens)
                    #expect(request.outputTokenLimit == 4_096)
                }
                #expect(!fitted.passages.isEmpty)
                #expect(fitted.coverage.isPartialRecap)
                #expect(fitted.dependencies == evidence.dependencies)
                for passage in fitted.passages {
                    #expect(excerpt.hasPrefix(passage.excerpt))
                    #expect(passage.range.length == passage.excerpt.utf16.count)
                }
            }
        }
    }

}

private actor SummaryBudgetProbe: MeetingTextGenerating {
    var requests: [MeetingTextGenerationRequest] = []
    private var outputs: [String]
    init(outputs: [String] = ["Compressed context"]) { self.outputs = outputs }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request)
        return outputs.removeFirst()
    }
}

private actor SummaryContextValidationProbe {
    enum Invalidated: Error { case changed }
    private var calls = 0
    func validate() throws {
        calls += 1
        if calls > 1 { throw Invalidated.changed }
    }
}

private actor SmallContextCompatibilityProbe: MeetingTextGenerating {
    private(set) var requests: [MeetingTextGenerationRequest] = []
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request)
        if requests.count == 1 { return #"{"tool":"browse_meeting_sources"}"# }
        return #"{"status":"answered","markdown":"The plan is recorded [[S1]]."}"#
    }
}
