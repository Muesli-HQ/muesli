import Foundation
import MuesliCore

struct MeetingNativeToolRequest {
    let base: MeetingTextGenerationRequest
    let inputItems: Data
    let tools: Data
    let allowTools: Bool
    var requiresMeetingAnswerFormat: Bool = true
}

struct MeetingNativeToolCall: Sendable {
    let id: String
    let name: String
    let arguments: String
}

struct MeetingNativeToolResponse: Sendable {
    /// Complete provider output, including encrypted reasoning, for the next request.
    let outputItems: Data
    let calls: [MeetingNativeToolCall]
    let text: String
}

enum MeetingNativeToolTransportError: Error, LocalizedError {
    case invalidResponse, incompleteResponse, emptyOutput, malformedToolCall, responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Meeting AI returned an unreadable response. Please retry."
        case .incompleteResponse: "Meeting AI stopped before completing its response. Please retry."
        case .emptyOutput: "Meeting AI completed without an answer or retrieval request. Please retry."
        case .malformedToolCall: "Meeting AI returned an invalid retrieval request. Please retry."
        case .responseTooLarge: "Meeting AI returned more data than this chat can safely process. Try a narrower question."
        }
    }
}

enum MeetingNativeToolTransport {
    static let maximumResponseBytes = 2_097_152

    static func requestBody(_ request: MeetingNativeToolRequest, stream: Bool) throws -> [String: Any] {
        guard request.inputItems.count <= maximumResponseBytes,
              request.tools.count <= 32_768,
              let input = try JSONSerialization.jsonObject(with: request.inputItems) as? [[String: Any]],
              let tools = try JSONSerialization.jsonObject(with: request.tools) as? [[String: Any]] else {
            throw MeetingTextGenerationError.emptyResponse
        }
        let model = MeetingTextGenerationClient.model(request.base.config)
        guard !model.isEmpty else { throw MeetingTextGenerationError.missingConnection }
        // OpenRouter keeps its namespaced ID on the wire; only local reasoning
        // capability lookup uses the underlying OpenAI model name.
        let policyModel = MeetingSummaryBackendOption.resolved(request.base.config.meetingSummaryBackend) == .openRouter && model.lowercased().hasPrefix("openai/")
            ? String(model.dropFirst("openai/".count)) : model
        let effort = ReasoningEffortPolicy.apiValue(for: policyModel, preferred: request.base.config.meetingSummaryReasoningEffort)
        let requestedBudget = effort != nil && effort != "none" ? max(request.base.maxOutputTokens, 32_768) : request.base.maxOutputTokens
        let budget = min(requestedBudget, max(1, request.base.outputTokenLimit ?? requestedBudget))
        var body: [String: Any] = [
            "model": model, "instructions": request.base.system, "input": input,
            "tools": tools, "parallel_tool_calls": false,
            "tool_choice": request.allowTools ? "auto" : "none",
            "store": false, "stream": stream, "max_output_tokens": budget,
            "include": ["reasoning.encrypted_content"],
            "text": ["format": ["type": "json_schema", "name": "meeting_answer", "strict": true,
                "schema": ["type": "object", "properties": [
                    "status": ["type": "string", "enum": ["conversation", "answered", "insufficient_evidence"]],
                    "markdown": ["type": "string"]
                ], "required": ["status", "markdown"], "additionalProperties": false]]]
        ]
        if !request.requiresMeetingAnswerFormat { body.removeValue(forKey: "text") }
        if let effort {
            var reasoning = ["effort": effort]
            if request.base.onReasoningSummary != nil, effort != "none" { reasoning["summary"] = "auto" }
            body["reasoning"] = reasoning
        }
        return body
    }

    static func parseResponse(_ data: Data) throws -> MeetingNativeToolResponse {
        guard data.count <= maximumResponseBytes else { throw MeetingNativeToolTransportError.responseTooLarge }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingNativeToolTransportError.invalidResponse
        }
        return try parseResponse(payload)
    }

    static func parseResponse(_ payload: [String: Any]) throws -> MeetingNativeToolResponse {
        guard payload["status"] as? String == "completed",
              payload["error"] == nil || payload["error"] is NSNull else { throw MeetingNativeToolTransportError.incompleteResponse }
        guard let output = payload["output"] as? [[String: Any]] else { throw MeetingNativeToolTransportError.invalidResponse }
        let serialized = try JSONSerialization.data(withJSONObject: output)
        guard serialized.count <= maximumResponseBytes else { throw MeetingNativeToolTransportError.responseTooLarge }
        var calls: [MeetingNativeToolCall] = []
        var seen = Set<String>()
        for item in output {
            guard item["status"] as? String != "incomplete", item["status"] as? String != "failed" else { throw MeetingNativeToolTransportError.incompleteResponse }
            guard item["type"] as? String == "function_call" else { continue }
            guard let id = item["call_id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  let name = item["name"] as? String, !name.isEmpty, name.utf8.count <= 256,
                  let arguments = item["arguments"] as? String, arguments.utf8.count <= 16_384,
                  seen.insert(id).inserted else { throw MeetingNativeToolTransportError.malformedToolCall }
            calls.append(.init(id: id, name: name, arguments: arguments))
        }
        let text = ChatGPTResponsesClient.extractOutputText(from: payload) ?? ""
        guard !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingNativeToolTransportError.emptyOutput }
        return .init(outputItems: serialized, calls: calls, text: text)
    }
}

/// Only completed output items are replayable. Codex can omit the full output
/// array on its terminal event after sending these items individually.
struct MeetingNativeResponseAccumulator {
    private struct Item {
        let index: Int?
        var value: [String: Any]
    }
    private var items: [Item] = []

    mutating func apply(_ payload: [String: Any]) throws -> MeetingNativeToolResponse? {
        switch payload["type"] as? String {
        case "response.output_item.done":
            guard let value = payload["item"] as? [String: Any] else { throw MeetingNativeToolTransportError.invalidResponse }
            try merge(value, index: payload["output_index"] as? Int)
            return nil
        case "response.completed":
            guard var response = payload["response"] as? [String: Any] else { throw MeetingNativeToolTransportError.invalidResponse }
            if response["status"] == nil { response["status"] = "completed" }
            // A terminal snapshot may be absent, empty, or contain only a subset
            // of items already completed by the stream. Merge rather than erase.
            if let rawOutput = response["output"] {
                guard let output = rawOutput as? [[String: Any]] else { throw MeetingNativeToolTransportError.invalidResponse }
                for (index, item) in output.enumerated() { try merge(item, index: index) }
            }
            response["output"] = orderedOutput()
            return try MeetingNativeToolTransport.parseResponse(response)
        case "response.failed", "response.incomplete", "error":
            throw MeetingNativeToolTransportError.incompleteResponse
        default:
            return nil
        }
    }

    private mutating func merge(_ value: [String: Any], index: Int?) throws {
        if let index, !(0..<256).contains(index) { throw MeetingNativeToolTransportError.responseTooLarge }
        let id = value["id"] as? String
        let callID = value["call_id"] as? String
        let identityMatch = items.firstIndex {
            (id != nil && $0.value["id"] as? String == id) ||
            (callID != nil && $0.value["call_id"] as? String == callID)
        }
        let indexMatch = items.firstIndex {
            guard let index, $0.index == index,
                  $0.value["type"] as? String == value["type"] as? String else { return false }
            // Partial terminal arrays need not retain original positions. Never
            // replace a different explicitly identified item merely by position.
            if let id, let existing = $0.value["id"] as? String, id != existing { return false }
            if let callID, let existing = $0.value["call_id"] as? String, callID != existing { return false }
            return true
        }
        if let existing = identityMatch ?? indexMatch {
            guard items[existing].value["type"] as? String == value["type"] as? String else { throw MeetingNativeToolTransportError.invalidResponse }
            items[existing].value.merge(value) { _, latest in latest }
        } else {
            guard items.count < 256 else { throw MeetingNativeToolTransportError.responseTooLarge }
            items.append(.init(index: index, value: value))
        }
        guard try JSONSerialization.data(withJSONObject: orderedOutput()).count <= MeetingNativeToolTransport.maximumResponseBytes else {
            throw MeetingNativeToolTransportError.responseTooLarge
        }
    }

    private func orderedOutput() -> [[String: Any]] {
        items.enumerated().sorted {
            let left = $0.element.index ?? $0.offset
            let right = $1.element.index ?? $1.offset
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element.value)
    }
}
