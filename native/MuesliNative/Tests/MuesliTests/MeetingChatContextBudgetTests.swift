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
