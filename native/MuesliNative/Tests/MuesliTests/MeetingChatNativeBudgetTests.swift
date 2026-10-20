import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Native meeting chat request budgets")
struct MeetingChatNativeBudgetTests {
    private func initialEvidence() -> MeetingChatEvidence {
        let passage = MeetingChatPassage(id: "p1", sourceKey: "S1", meetingID: 1, title: "Planning",
            startDate: Date(timeIntervalSince1970: 1_000), kind: .transcript, excerpt: "Ship Friday.",
            range: .init(location: 0, length: 12), timestamp: nil, revision: "r1")
        return .init(scope: .init(), passages: [passage], dependencies: [.init(meetingID: 1, revision: "r1")],
                     coverage: .init(eligibleMeetingCount: 1, evidenceMeetingCount: 1, isPartialRecap: true))
    }

    @Test @MainActor func multipleLargePagesFinalizeFromDeliveredEvidence() async throws {
        let probe = NativeBudgetProbe(mode: .pages)
        var config = AppConfig(); config.meetingSummaryBackend = "chatgpt"
        let policy = MeetingChatContextBudget(config: config)
        var executed = 0
        let (answer, evidence) = try await MeetingChatNativeHarness.run(question: "Read all pages", evidence: initialEvidence(),
            history: [], config: config, sessionID: UUID(), generator: probe, execute: { _, current in
                executed += 1
                var next = current
                var passage = current.passages[0]
                passage.id = "page\(executed)"; passage.sourceKey = "S\(executed + 1)"
                passage.excerpt = String(repeating: "Page detail. ", count: 3_200)
                passage.range = .init(location: 0, length: passage.excerpt.utf16.count)
                next.passages.append(passage)
                next.dependencies.append(.init(meetingID: Int64(100 + executed), revision: "r1"))
                return .init(evidence: next, matchedPassageCount: 1, nextPage: executed)
            }, activity: { _, _ in }, progress: { _ in }, reasoningSummary: { _, _ in })
        #expect(executed >= 2)
        #expect(answer.coverage.isPartialRecap)
        #expect(answer.citations.map(\.sourceKey) == ["S2"])
        #expect(!evidence.passages.contains { $0.sourceKey == "S\(executed + 1)" })
        #expect(evidence.dependencies.contains { $0.meetingID == Int64(100 + executed) })
        let requests = await probe.requests
        #expect(requests.last?.allowTools == false)
        #expect(String(decoding: requests.last!.inputItems, as: UTF8.self).contains("budget_exhausted"))
        for request in requests {
            let text = request.base.system + String(decoding: request.inputItems, as: UTF8.self) + String(decoding: request.tools, as: UTF8.self)
            #expect(MeetingChatContextBudget.estimateTokens(text) <= policy.maximumInputTokens)
        }
    }

    @Test @MainActor func oversizedReplayFallsBackWithoutExecutingOrDanglingCalls() async throws {
        let probe = NativeBudgetProbe(mode: .oversizedReplay)
        var config = AppConfig(); config.meetingSummaryBackend = "chatgpt"
        let (answer, _) = try await MeetingChatNativeHarness.run(question: "Read all pages", evidence: initialEvidence(),
            history: [], config: config, sessionID: UUID(), generator: probe,
            execute: { _, current in Issue.record("Oversized replay must not execute tools"); return .init(evidence: current) },
            activity: { _, _ in }, progress: { _ in }, reasoningSummary: { _, _ in })
        #expect(answer.citations.map(\.sourceKey) == ["S1"])
        #expect(answer.coverage.isPartialRecap)
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(!requests[1].allowTools)
        let replay = try #require(JSONSerialization.jsonObject(with: requests[1].inputItems) as? [[String: Any]])
        #expect(!replay.contains { $0["type"] as? String == "function_call" })
    }

    @Test @MainActor func repairProgressSurvivesNextInference() async throws {
        let probe = NativeBudgetProbe(mode: .repair)
        var config = AppConfig(); config.meetingSummaryBackend = "chatgpt"
        var phases: [String] = []
        _ = try await MeetingChatNativeHarness.run(question: "What was agreed?", evidence: initialEvidence(),
            history: [], config: config, sessionID: UUID(), generator: probe,
            execute: { _, current in .init(evidence: current) }, activity: { _, _ in },
            progress: { phases.append($0) }, reasoningSummary: { _, _ in })
        #expect(phases.filter { $0 == "Preparing answer" }.count == 1)
        #expect(phases.count >= 4)
        #expect(phases[2] == phases[3])
    }
}

private actor NativeBudgetProbe: MeetingTextGenerating {
    enum Mode { case pages, oversizedReplay, repair }
    let mode: Mode
    private(set) var requests: [MeetingNativeToolRequest] = []
    init(mode: Mode) { self.mode = mode }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String { "" }
    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        requests.append(request)
        if mode == .repair {
            return .init(outputItems: Data("[]".utf8), calls: [],
                text: requests.count == 1 ? #"{"status":"answered","markdown":"Uncited answer"}"# : #"{"status":"answered","markdown":"Ship Friday [[S1]]"}"#)
        }
        if !request.allowTools {
            let text = mode == .pages ? #"{"status":"answered","markdown":"Available detail [[S2]]. Additional pages remain unread."}"# : #"{"status":"answered","markdown":"Ship Friday [[S1]]. Additional pages remain unread."}"#
            return .init(outputItems: Data("[]".utf8), calls: [], text: text)
        }
        let id = "call-\(requests.count)"
        let arguments = "{\"meeting_id\":1,\"page\":\(requests.count - 1)}"
        var output: [[String: Any]] = [["type": "function_call", "name": "read_full_meeting", "call_id": id, "arguments": arguments]]
        if mode == .oversizedReplay { output.insert(["type": "reasoning", "encrypted_content": String(repeating: "x", count: 400_000)], at: 0) }
        return .init(outputItems: try JSONSerialization.data(withJSONObject: output),
            calls: [.init(id: id, name: "read_full_meeting", arguments: arguments)], text: "")
    }
}
