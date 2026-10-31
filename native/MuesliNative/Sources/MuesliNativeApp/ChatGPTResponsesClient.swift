import Foundation

enum ChatGPTResponsesError: LocalizedError {
    case backendFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(statusCode, message):
            return "ChatGPT failed with status \(statusCode). \(message)"
        }
    }
}

/// Shared request construction for ChatGPT-authenticated Responses calls.
///
/// Muesli routes its existing ChatGPT OAuth credentials to the Codex inference
/// lane. That direct third-party contract is compatibility-sensitive, so keep
/// request metadata centralized and the client identity honest: these headers
/// describe Muesli and never impersonate an official Codex client. WHAM remains
/// available only as an explicit, process-level emergency rollback.
enum ChatGPTResponsesTransport {
    enum Backend: Equatable {
        case codex
        case wham

        var responsesURL: URL {
            switch self {
            case .codex:
                return URL(string: "https://chatgpt.com/backend-api/codex/responses")!
            case .wham:
                return URL(string: "https://chatgpt.com/backend-api/wham/responses")!
            }
        }
    }

    static let environmentKey = "MUESLI_CHATGPT_TRANSPORT"
    static let requestTimeout: TimeInterval = 120
    static let resourceTimeout: TimeInterval = 180
    static let originator = "muesli"

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        // Request timeout alone resets as bytes arrive: SSE heartbeats can otherwise
        // hold a chat open for the system default resource timeout of seven days.
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func selectedBackend(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Backend {
        let requested = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return requested == "wham" ? .wham : .codex
    }

    static func makeRequest(
        body: [String: Any],
        token: String,
        accountId: String,
        appVersion: String = AppIdentity.marketingVersion,
        sessionID: UUID = UUID(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URLRequest {
        let backend = selectedBackend(environment: environment)
        var request = URLRequest(url: backend.responsesURL)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if backend == .codex {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(originator, forHTTPHeaderField: "originator")
            request.setValue("Muesli/\(appVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue(sessionID.uuidString.lowercased(), forHTTPHeaderField: "session_id")
        }
        var supportedBody = body
        if backend == .codex {
            // ChatGPT's Codex endpoint rejects this public Responses API field.
            supportedBody.removeValue(forKey: "max_output_tokens")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: supportedBody)
        return request
    }
}

/// Collect only provider-designated reasoning summaries. Raw reasoning text,
/// encrypted reasoning, and unrelated output events never enter this display channel.
struct ChatGPTReasoningSummaryAccumulator {
    private struct Key: Hashable {
        let itemID: String
        let summaryIndex: Int
    }
    private struct Part {
        let outputIndex: Int
        var text: String
        var isDone: Bool
    }
    private var parts: [Key: Part] = [:]
    private var completedItems: Set<String> = []
    private(set) var text = ""

    mutating func apply(_ payload: [String: Any]) -> Bool {
        guard let type = payload["type"] as? String,
              let outputIndex = payload["output_index"] as? Int, outputIndex >= 0 else { return false }
        if type == "response.output_item.done" {
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "reasoning",
                  let itemID = item["id"] as? String, !itemID.isEmpty,
                  let summary = item["summary"] as? [[String: Any]],
                  completedItems.contains(itemID) || completedItems.count < 32 else { return false }
            // The final item contains only public summary_text parts here. Never
            // consult content (raw reasoning) or encrypted_content.
            parts = parts.filter { $0.key.itemID != itemID }
            for (index, entry) in summary.prefix(32).enumerated() {
                guard entry["type"] as? String == "summary_text", let fragment = entry["text"] as? String else { continue }
                store(itemID: itemID, index: index, outputIndex: outputIndex, fragment: fragment, isDelta: false)
            }
            completedItems.insert(itemID)
        } else {
            guard let itemID = payload["item_id"] as? String, !itemID.isEmpty,
                  let index = payload["summary_index"] as? Int, (0..<32).contains(index),
                  !completedItems.contains(itemID) else { return false }
            let fragment: String
            let isDelta = type == "response.reasoning_summary_text.delta"
            switch type {
            case "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done":
                guard let value = payload[isDelta ? "delta" : "text"] as? String else { return false }
                fragment = value
            case "response.reasoning_summary_part.done":
                guard let part = payload["part"] as? [String: Any], part["type"] as? String == "summary_text",
                      let value = part["text"] as? String else { return false }
                fragment = value
            default: return false
            }
            store(itemID: itemID, index: index, outputIndex: outputIndex, fragment: fragment, isDelta: isDelta)
        }
        let updated = String(parts.sorted {
            if $0.value.outputIndex != $1.value.outputIndex { return $0.value.outputIndex < $1.value.outputIndex }
            if $0.key.summaryIndex != $1.key.summaryIndex { return $0.key.summaryIndex < $1.key.summaryIndex }
            return $0.key.itemID < $1.key.itemID
        }.map { $0.value.text }.filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(6_000))
        guard updated != text else { return false }
        text = updated
        return true
    }

    private mutating func store(itemID: String, index: Int, outputIndex: Int, fragment: String, isDelta: Bool) {
        let key = Key(itemID: itemID, summaryIndex: index)
        let previous = parts[key]
        guard previous != nil || parts.count < 32,
              previous == nil || previous?.outputIndex == outputIndex,
              !isDelta || previous?.isDone != true else { return }
        let bounded = String(fragment.prefix(6_000))
        let content = isDelta ? String(((previous?.text ?? "") + bounded).prefix(6_000)) : bounded
        parts[key] = Part(outputIndex: outputIndex, text: content, isDone: !isDelta)
    }
}

enum ChatGPTResponsesClient {
    static func respond(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxOutputTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        sessionID: UUID = UUID(),
        onReasoningSummary: (@Sendable (String) async -> Void)? = nil,
        logCategory: String
    ) async throws -> String {
        try Task.checkCancellation()
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        try Task.checkCancellation()
        let body = requestBody(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            maxOutputTokens: maxOutputTokens,
            reasoningEffort: reasoningEffort,
            includeReasoningSummary: onReasoningSummary != nil
        )

        let request = try ChatGPTResponsesTransport.makeRequest(
            body: body,
            token: token,
            accountId: accountId,
            sessionID: sessionID
        )

        let session = URLSession(configuration: ChatGPTResponsesTransport.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard errorData.count < 8_192 else { break }
                errorData.append(byte)
            }
            let message = extractErrorMessage(from: errorData)
                ?? String(data: errorData, encoding: .utf8)
                ?? "(unknown)"
            fputs("[\(logCategory)] ChatGPT Responses: HTTP \(httpStatus): \(String(message.prefix(500)))\n", stderr)
            throw ChatGPTResponsesError.backendFailed(statusCode: httpStatus, message: message)
        }

        var deltaText = ""
        var finalText = ""
        var reasoningSummary = ChatGPTReasoningSummaryAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let json = try decodeStreamPayload(jsonString, httpStatus: httpStatus) else { continue }

            try Task.checkCancellation()
            if reasoningSummary.apply(json) {
                await onReasoningSummary?(reasoningSummary.text)
            }
            applyStreamPayload(json, deltaText: &deltaText, finalText: &finalText)
            guard deltaText.utf8.count <= 256_000, finalText.utf8.count <= 256_000 else {
                throw ChatGPTResponsesError.backendFailed(statusCode: httpStatus, message: "ChatGPT response exceeded the supported size.")
            }
        }

        try Task.checkCancellation()
        let fullText = accumulatedOutputText(deltaText: deltaText, finalText: finalText)
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        fputs("[\(logCategory)] ChatGPT Responses: collected \(trimmed.count) chars\n", stderr)
        return trimmed
    }

    static func respondNative(_ input: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        try Task.checkCancellation()
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        try Task.checkCancellation()
        let body = try MeetingNativeToolTransport.requestBody(input, stream: true)
        let request = try ChatGPTResponsesTransport.makeRequest(body: body, token: token,
            accountId: accountId, sessionID: input.base.sessionID)
        let session = URLSession(configuration: ChatGPTResponsesTransport.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MeetingTextGenerationError.failed(status) }
        var summary = ChatGPTReasoningSummaryAccumulator()
        var output = MeetingNativeResponseAccumulator(maximumArgumentBytes: input.maximumArgumentBytes)
        var received = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            received += line.utf8.count
            guard received <= 8_388_608, line.utf8.count <= MeetingNativeToolTransport.maximumResponseBytes else {
                throw MeetingTextGenerationError.emptyResponse
            }
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if raw == "[DONE]" { break }
            guard let payload = try decodeStreamPayload(raw, httpStatus: status) else { continue }
            if summary.apply(payload) { await input.base.onReasoningSummary?(summary.text) }
            try Task.checkCancellation()
            if let completed = try output.apply(payload) { return completed }
        }
        // Partial deltas are never a completed native tool call or final answer.
        throw MeetingTextGenerationError.emptyResponse
    }

    static func requestBody(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxOutputTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        includeReasoningSummary: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "input": [[
                "role": "user",
                "content": [["type": "input_text", "text": userPrompt]],
            ] as [String: Any]],
        ]
        if let effort = ReasoningEffortPolicy.apiValue(for: model, preferred: reasoningEffort) {
            var reasoning = ["effort": effort]
            if includeReasoningSummary, effort != "none" { reasoning["summary"] = "auto" }
            body["reasoning"] = reasoning
        }
        if let maxOutputTokens, maxOutputTokens > 0 {
            body["max_output_tokens"] = maxOutputTokens
        }
        return body
    }

    static func applyStreamPayload(_ payload: [String: Any], deltaText: inout String, finalText: inout String) {
        if let delta = extractOutputTextDelta(from: payload) {
            deltaText += delta
            return
        }

        if let outputText = extractOutputText(from: payload), !outputText.isEmpty {
            finalText = outputText
        }
    }

    static func accumulatedOutputText(deltaText: String, finalText: String) -> String {
        finalText.isEmpty ? deltaText : finalText
    }

    static func decodeStreamPayload(_ jsonString: String, httpStatus: Int) throws -> [String: Any]? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if shouldIgnoreNonJSONStreamPayload(trimmed) { return nil }
        guard
            let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ChatGPTResponsesError.backendFailed(
                statusCode: httpStatus,
                message: "Malformed ChatGPT stream payload."
            )
        }
        return json
    }

    private static func shouldIgnoreNonJSONStreamPayload(_ payload: String) -> Bool {
        switch payload.lowercased() {
        case "ping", "heartbeat", "keep-alive":
            return true
        default:
            return false
        }
    }

    static func extractOutputText(from payload: [String: Any]) -> String? {
        // Codex may emit commentary before its terminal answer. Prefer the
        // declared final assistant message over convenience text that joins both.
        if let finalAnswer = extractFinalAssistantAnswer(from: payload) { return finalAnswer }
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }
        if let response = payload["response"] as? [String: Any],
           let responseText = extractOutputText(from: response) {
            return responseText
        }
        if let outputText = extractText(fromOutput: payload["output"]) {
            return outputText
        }
        if let contentText = extractText(fromContent: payload["content"]) {
            return contentText
        }
        return nil
    }

    static func extractOutputTextDelta(from payload: [String: Any]) -> String? {
        guard
            (payload["type"] as? String) == "response.output_text.delta",
            let delta = payload["delta"] as? String,
            !delta.isEmpty
        else {
            return nil
        }
        return delta
    }

    private static func extractFinalAssistantAnswer(from payload: [String: Any]) -> String? {
        if let response = payload["response"] as? [String: Any],
           let answer = extractFinalAssistantAnswer(from: response) { return answer }
        let items: [[String: Any]]
        if let output = payload["output"] as? [[String: Any]] { items = output }
        else if let output = payload["output"] as? [String: Any] { items = [output] }
        else { return nil }
        // `phase` is optional in the Codex Responses protocol. When absent,
        // extractOutputText retains the existing legacy response handling.
        guard let item = items.last(where: {
            $0["type"] as? String == "message" &&
            $0["role"] as? String == "assistant" &&
            $0["phase"] as? String == "final_answer"
        }) else { return nil }
        let text = extractText(fromContent: item["content"]) ?? (item["text"] as? String)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func extractText(fromOutput output: Any?) -> String? {
        guard let output else { return nil }
        if let outputText = output as? String, !outputText.isEmpty {
            return outputText
        }
        if let item = output as? [String: Any] {
            guard item["type"] as? String != "reasoning" else { return nil }
            return extractText(fromContent: item["content"]) ?? (item["text"] as? String)
        }
        if let items = output as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                guard item["type"] as? String != "reasoning" else { return nil }
                return extractText(fromContent: item["content"]) ?? (item["text"] as? String)
            }
            let joined = parts.joined(separator: "")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractText(fromContent content: Any?) -> String? {
        guard let content else { return nil }
        if let text = content as? String, !text.isEmpty {
            return text
        }
        if let item = content as? [String: Any] {
            if let text = item["text"] as? String, !text.isEmpty { return text }
            if let text = item["content"] as? String, !text.isEmpty { return text }
            if let nested = item["text"] as? [String: Any],
               let value = nested["value"] as? String,
               !value.isEmpty {
                return value
            }
        }
        if let items = content as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.isEmpty { return text }
                if let text = item["content"] as? String, !text.isEmpty { return text }
                if let nested = item["text"] as? [String: Any],
                   let value = nested["value"] as? String,
                   !value.isEmpty {
                    return value
                }
                return nil
            }
            let joined = parts.joined(separator: "")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let code = error["code"] as? String, !code.isEmpty { return code }
            return String(describing: error)
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
        return nil
    }
}
