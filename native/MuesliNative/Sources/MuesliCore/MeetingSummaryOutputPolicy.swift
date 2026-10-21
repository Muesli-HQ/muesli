import Foundation

/// Summary output is provider-controlled unless the user explicitly requests a cap.
public enum MeetingSummaryOutputPolicy {
    public static let presets = [2_500, 5_000, 10_000, 20_000, 64_000, 128_000]

    /// Match Anthropic's SDK threshold for avoiding long-request HTTP timeouts:
    /// https://platform.claude.com/docs/en/build-with-claude/thinking#long-requests
    public static func anthropicRequiresStreaming(outputLimit: Int) -> Bool {
        outputLimit > 21_333
    }

    public static func normalizedLimit(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Published limits: https://platform.claude.com/docs/en/models/overview
    /// and https://platform.claude.com/docs/en/models/haiku-4-5/overview.
    /// Unknown models use the
    /// endpoint's Models API instead of inheriting an arbitrary summary budget.
    public static func anthropicModelMaximum(_ model: String) -> Int? {
        switch model {
        case "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-haiku-5-5":
            return 128_000
        case "claude-haiku-4-5", "claude-haiku-4-5-20251001":
            return 64_000
        default: return nil
        }
    }

    public static func anthropicLimit(
        model: String, requested: Int?, messagesURL: URL, apiKey: String,
        workspaceID: String = "", extraHeaders: [String: String] = [:],
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Int {
        if let requested = normalizedLimit(requested) {
            return min(requested, anthropicModelMaximum(model) ?? requested)
        }
        if let maximum = anthropicModelMaximum(model) { return maximum }

        guard var components = URLComponents(url: messagesURL.deletingLastPathComponent().appendingPathComponent("models"), resolvingAgainstBaseURL: false) else {
            throw OutputError.modelLimitUnavailable
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        components.percentEncodedPath += "/" + (model.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        guard let url = components.url else { throw OutputError.modelLimitUnavailable }
        var request = try AnthropicAPIRequest.make(url: url, apiKey: apiKey, workspaceID: workspaceID, body: [:], timeout: 30)
        request.httpMethod = "GET"
        request.httpBody = nil
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await send(request)
        if let status = (response as? HTTPURLResponse)?.statusCode,
           status != 200, ![404, 405, 501].contains(status) {
            throw OutputError.modelLimitRequestFailed(statusCode: status)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let maximum = json["max_tokens"] as? Int, maximum > 0 else {
            throw OutputError.modelLimitUnavailable
        }
        return maximum
    }

    public enum OutputError: LocalizedError {
        case modelLimitUnavailable
        case modelLimitRequestFailed(statusCode: Int)
        case incompleteStream
        case outputLimitReached
        case contextWindowExceeded
        case provider(type: String?, message: String)

        public var errorDescription: String? {
            switch self {
            case .modelLimitUnavailable:
                return "This Anthropic-compatible endpoint requires an output limit but did not report the model's maximum. Set an output token limit in Meetings → Meeting Summaries → Advanced and try again."
            case .modelLimitRequestFailed(let status):
                return "The summary provider could not report the model's output limit (HTTP \(status)). Check the connection and API credentials, then try again."
            case .incompleteStream:
                return "The summary response ended before the model finished. Try again."
            case .outputLimitReached:
                return "The summary reached its output token limit before finishing. Increase or remove the output token limit in Meetings → Meeting Summaries → Advanced, or choose a model with a larger output allowance, then try again."
            case .contextWindowExceeded:
                return "The summary filled the model's context window before finishing. Use a model with a larger context window or shorten the transcript and notes, then try again."
            case .provider(_, let message): return message
            }
        }
    }

    /// Large Anthropic budgets use SSE. Collect only text blocks and require the
    /// stop reason followed by the terminal event, rejecting token-limit stops.
    public static func anthropicText(from data: Data, redactProviderErrors: Bool = false) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try validateAnthropicStopReason(json["stop_reason"] as? String)
            let content = json["content"] as? [[String: Any]] ?? []
            return content.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var textBlocks: [Int: String] = [:]
        var finished = false
        var sawStopReason = false
        var eventData: [String] = []
        func consume() throws {
            guard !eventData.isEmpty else { return }
            let bytes = Data(eventData.joined(separator: "\n").utf8)
            eventData.removeAll()
            guard let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw OutputError.incompleteStream
            }
            switch event["type"] as? String {
            case "content_block_start":
                if let index = event["index"] as? Int,
                   let block = event["content_block"] as? [String: Any], block["type"] as? String == "text" {
                    textBlocks[index] = block["text"] as? String ?? ""
                }
            case "content_block_delta":
                if let index = event["index"] as? Int,
                   let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String, textBlocks[index] != nil {
                    textBlocks[index, default: ""] += text
                }
            case "message_delta":
                guard let delta = event["delta"] as? [String: Any] else {
                    throw OutputError.incompleteStream
                }
                if let reason = delta["stop_reason"] as? String, !reason.isEmpty {
                    sawStopReason = true
                }
                try validateAnthropicStopReason(delta["stop_reason"] as? String)
            case "message_stop":
                guard sawStopReason else { throw OutputError.incompleteStream }
                finished = true
            case "error":
                let error = event["error"] as? [String: Any]
                let message = redactProviderErrors ? "The custom summary provider reported an error."
                    : (error?["message"] as? String ?? "The summary provider reported an error.")
                throw OutputError.provider(type: error?["type"] as? String, message: String(message.prefix(1200)))
            default: break
            }
        }
        for line in String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { try consume() }
            else if line.hasPrefix("data:") {
                eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        try consume()
        guard finished else { throw OutputError.incompleteStream }
        return textBlocks.keys.sorted().compactMap { textBlocks[$0] }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both token and context-window exhaustion indicate truncated output:
    /// https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons
    private static func validateAnthropicStopReason(_ reason: String?) throws {
        switch reason {
        case "max_tokens": throw OutputError.outputLimitReached
        case "model_context_window_exceeded": throw OutputError.contextWindowExceeded
        default: break
        }
    }
}
