import Foundation
import MuesliCore

/// A task supplies policy and source operations; the runner owns provider execution.
/// Closures are attempt-local. Persistence and navigation remain with the caller.
@MainActor
struct MuesliNativeTask<Call, Output> {
    let instructions: String
    let user: String
    let tools: [[String: Any]]
    var images: [ChatImageInput] = []
    var maximumOutputTokens: Int? = nil
    var requiresMeetingAnswerFormat = true
    var allowedAnswerStatuses: () -> [String] = { ["conversation", "answered", "insufficient_evidence"] }
    let parse: (String, String) throws -> Call
    let execute: (Call) async throws -> MuesliTaskToolOutput
    var accept: (Call, Bool) -> Void = { _, _ in }
    var exhausted: () -> Void = {}
    let validate: (String) throws -> Output
    var repair: (MeetingChatHarnessError) -> String = {
        $0.correction + " Return a corrected final answer using the response schema and valid supplied source markers. Retrieval is complete for this request."
    }
    var validateContext: () async throws -> Void = {}
}

struct MuesliTaskToolOutput {
    let text: String
    var images: [ChatImageInput] = []
}

enum MuesliTaskStep<Output> {
    case next
    case finished(Output)
}

/// Shared execution engine for interactive and button-triggered tasks. Source
/// scope, evidence validation and final output shape belong to their adapters.
@MainActor
enum MuesliTaskRunner {
    nonisolated static let maximumToolCalls = 12
    nonisolated static let maximumOutputItemBytes = 512_000
    nonisolated static let maximumInputBytes = ChatFileReader.maximumRequestBytes

    struct Runtime {
        let generator: any MeetingTextGenerating
        let budget: MeetingChatContextBudget
    }

    static func prepare(config: AppConfig, generator: any MeetingTextGenerating,
                        budget: MeetingChatContextBudget? = nil, imageCount: Int = 0) async throws -> Runtime {
        try Task.checkCancellation()
        let prepared = try await generator.preparedForChat(config: config)
        try Task.checkCancellation()
        return Runtime(generator: prepared, budget: (budget ?? MeetingChatContextBudget(config: config,
            contextWindowTokens: prepared.chatContextTokens(config: config))).reservingImageTokens(imageCount))
    }

    /// Compatibility adapters retain their prompt fitting and source packet policy,
    /// while sharing the same bounded loop, cancellation and one final-only repair.
    static func runCompatibility<Output>(maximumToolCalls: Int,
        step: (Int, MeetingChatHarnessError?, Bool) async throws -> MuesliTaskStep<Output>
    ) async throws -> Output {
        precondition((0...self.maximumToolCalls).contains(maximumToolCalls))
        var correction: MeetingChatHarnessError?
        for iteration in 0..<(maximumToolCalls + 2) {
            try Task.checkCancellation()
            do {
                let toolsAllowed = correction == nil && iteration < maximumToolCalls
                let result = try await step(iteration, correction, toolsAllowed)
                try Task.checkCancellation()
                switch result {
                case .finished(let output): return output
                case .next:
                    guard toolsAllowed else { throw MeetingChatHarnessError.toolProtocol }
                }
            } catch let issue as MeetingChatHarnessError {
                if correction != nil { throw issue }
                correction = issue
            }
        }
        throw correction ?? MeetingChatHarnessError.toolProtocol
    }

    static func runNative<Call, Output>(_ task: MuesliNativeTask<Call, Output>,
        config: AppConfig, sessionID: UUID, generator: any MeetingTextGenerating,
        budget: MeetingChatContextBudget,
        activity: (Call, Bool) -> Void = { _, _ in }, progress: (String) -> Void = { _ in },
        reasoningSummary: @escaping @MainActor @Sendable (Int, String) async -> Void = { _, _ in }
    ) async throws -> Output {
        var input: [[String: Any]] = [["role": "user", "content": [["type": "input_text", "text": task.user]]]]
        var calls = 0
        var seenCallIDs = Set<String>()
        var corrected = false
        var repairProgress: String?
        var budgetExhausted = false
        let definitions = task.tools
        let registeredNames = Set(definitions.compactMap { $0["name"] as? String })
        let registeredTools = try JSONSerialization.data(withJSONObject: definitions, options: [.sortedKeys])
        func inputTokens(_ items: [[String: Any]]) throws -> Int {
            var images = 0
            let textual = items.map { item -> [String: Any] in
                var item = item
                if let content = item["content"] as? [[String: Any]] {
                    item["content"] = content.map { block -> [String: Any] in
                        if block["type"] as? String == "input_image" { images += 1; return ["type": "input_text", "text": "[PDF page image]"] }
                        return block
                    }
                }
                return item
            }
            let data = try JSONSerialization.data(withJSONObject: textual, options: [.sortedKeys])
            return MeetingChatContextBudget.estimateTokens(task.instructions + String(decoding: data, as: UTF8.self) + String(decoding: registeredTools, as: UTF8.self)) + images * 4_096
        }
        func fits(_ items: [[String: Any]], reserve: Int = 0) throws -> Bool {
            let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
            return try data.count <= maximumInputBytes - reserve * 3 &&
                inputTokens(items) <= budget.maximumInputTokens - reserve
        }
        let exhaustedOutput = #"{"error":"budget_exhausted","partial_coverage":true,"note":"This result was not supplied because the request context budget is full. Further retrieval is disabled. Answer only from already supplied passages and state that unread pages remain."}"#
        for iteration in 0..<(maximumToolCalls + 3) {
            try Task.checkCancellation()
            let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            guard inputData.count <= maximumInputBytes,
                  (try inputTokens(input)) <= budget.maximumInputTokens else { throw MeetingChatError.promptTooLarge }
            let allowTools = !corrected && !budgetExhausted && calls < maximumToolCalls && !definitions.isEmpty
            progress(repairProgress ?? "Preparing answer")
            try await task.validateContext()
            try Task.checkCancellation()
            let response = try await generator.generateNative(.init(
                base: .init(system: task.instructions, user: "", config: config, maxOutputTokens: min(task.maximumOutputTokens ?? budget.maximumOutputTokens, budget.maximumOutputTokens),
                    sessionID: sessionID, onReasoningSummary: { await reasoningSummary(iteration, $0) }, outputTokenLimit: budget.maximumOutputTokens, images: task.images),
                inputItems: inputData, tools: registeredTools, allowTools: allowTools,
                requiresMeetingAnswerFormat: task.requiresMeetingAnswerFormat,
                allowedAnswerStatuses: task.allowedAnswerStatuses()))
            try Task.checkCancellation()
            try await task.validateContext()
            try Task.checkCancellation()
            guard response.outputItems.count <= maximumOutputItemBytes,
                  let output = try JSONSerialization.jsonObject(with: response.outputItems) as? [[String: Any]] else {
                throw MeetingChatHarnessError.invalidFormat
            }
            // Includes encrypted reasoning items needed by stateless Responses.
            // It is ephemeral request state, never UI content or persisted history.
            if !response.calls.isEmpty {
                guard allowTools, response.calls.count <= maximumToolCalls - calls else { throw MeetingChatHarnessError.toolProtocol }
                // Reserve enough room to close every requested call with a small
                // budget result. Never send a dangling function-call sequence.
                let fallbackOutputs: [[String: Any]] = response.calls.map {
                    ["type": "function_call_output", "call_id": $0.id, "output": exhaustedOutput]
                }
                guard try fits(input + output + fallbackOutputs, reserve: 512) else {
                    budgetExhausted = true
                    task.exhausted()
                    // Restart final-only from the previous complete request, without
                    // partial reasoning/call replay or unavailable source markers.
                    continue
                }
                input += output
                for (callIndex, requested) in response.calls.enumerated() {
                    guard !requested.id.isEmpty, seenCallIDs.insert(requested.id).inserted else { throw MeetingChatHarnessError.toolProtocol }
                    calls += 1
                    if budgetExhausted {
                        input.append(fallbackOutputs[callIndex])
                        continue
                    }
                    let tool: Call
                    do {
                        guard registeredNames.contains(requested.name) else { throw MeetingChatHarnessError.toolProtocol }
                        tool = try task.parse(requested.name, requested.arguments)
                    } catch {
                        input.append(["type": "function_call_output", "call_id": requested.id,
                                      "output": "{\"error\":\"Invalid function or arguments. Use a registered tool and currently supplied source IDs.\"}"])
                        continue
                    }
                    activity(tool, false)
                    let result = try await task.execute(tool)
                    try Task.checkCancellation()
                    activity(tool, true)
                    let resultItem: [String: Any] = ["type": "function_call_output", "call_id": requested.id,
                                                   "output": result.text]
                    let imageItems: [[String: Any]] = result.images.map { image in
                        ["role": "user", "content": [["type": "input_text", "text": "Quoted page image: " + image.name], image.responsesContent]]
                    }
                    let remainingFallbacks = Array(fallbackOutputs.dropFirst(callIndex + 1))
                    if try fits(input + [resultItem] + imageItems + remainingFallbacks, reserve: 512) {
                        input.append(resultItem)
                        input += imageItems
                        task.accept(tool, true)
                    } else {
                        input.append(fallbackOutputs[callIndex])
                        budgetExhausted = true
                        // Retain read dependencies for deletion/privacy guards, but
                        // never expose withheld passages as usable citation sources.
                        task.accept(tool, false)
                        task.exhausted()
                    }
                }
                continue
            }
            progress("Checking source references")
            do {
                guard response.text.utf8.count <= 64_000 else { throw MeetingChatHarnessError.oversizedResponse }
                return try task.validate(response.text)
            } catch let issue as MeetingChatHarnessError {
                guard !corrected else { throw issue }
                corrected = true
                repairProgress = issue.progressLabel
                progress(issue.progressLabel)
                let correction: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": task.repair(issue)]]]
                guard try fits(input + [correction]) else { throw issue }
                input.append(correction)
            }
        }
        throw MeetingChatHarnessError.toolProtocol
    }
}
