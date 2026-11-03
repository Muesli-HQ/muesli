import Foundation
import CryptoKit
import MuesliCore

/// An attempt-owned capability snapshot. Never infer tool support from a model name.
struct LocalChatCapabilities: Sendable {
    enum Wire: String, Sendable { case ollama, openAI }
    let wire: Wire
    let provider: String
    let model: String
    let endpoint: URL
    let nativeTools: Bool
    let contextTokens: Int?
    let template: URLRequest
    let configuration: AppConfig

    func matches(_ config: AppConfig) -> Bool {
        configuration == config && provider == config.meetingSummaryBackend && model == MeetingTextGenerationClient.model(config)
            && endpoint == (try? LocalChatToolTransport.endpoint(config))
    }
}

/// Only synthetic probe verdicts are cached; live context metadata is refreshed
/// each turn. Keys include authorization/headers without retaining their plaintext.
actor LocalChatProbeCache {
    static let shared = LocalChatProbeCache()
    private var entries: [String: (Bool, Date)] = [:]
    func value(_ key: String, now: Date = Date()) -> Bool? {
        guard let entry = entries[key], entry.1 > now else { entries[key] = nil; return nil }
        return entry.0
    }
    func save(_ value: Bool, key: String, now: Date = Date()) {
        entries = entries.filter { $0.value.1 > now }
        if entries.count >= 32, let oldest = entries.min(by: { $0.value.1 < $1.value.1 })?.key { entries[oldest] = nil }
        entries[key] = (value, now.addingTimeInterval(value ? 300 : 30))
    }
}

enum LocalChatToolTransport {
    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func supportsProvider(_ config: AppConfig) -> Bool {
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        return provider == .ollama || provider == .lmStudio
            || (provider == .customLLM && config.customLLMFormat == CustomLLMFormat.openAI.rawValue)
    }

    static func endpoint(_ config: AppConfig) throws -> URL {
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        let url: URL?
        switch provider {
        case .ollama:
            url = URL(string: config.ollamaURL.isEmpty ? "http://localhost:11434" : config.ollamaURL)?.appendingPathComponent("api/chat")
        case .lmStudio: url = MeetingSummaryClient.resolveLMStudioURL(config: config)
        case .customLLM where config.customLLMFormat == CustomLLMFormat.openAI.rawValue:
            url = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)
        default: throw MeetingTextGenerationError.invalidEndpoint
        }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw MeetingTextGenerationError.invalidEndpoint }
        return url
    }

    static func sibling(_ url: URL, removing suffix: String, adding path: String) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.hasSuffix(suffix) else { throw MeetingTextGenerationError.invalidEndpoint }
        parts.path = String(parts.path.dropLast(suffix.count)) + path
        guard let result = parts.url else { throw MeetingTextGenerationError.invalidEndpoint }
        return result
    }

    static func checked(_ request: URLRequest, load: Load) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let (data, response) = try await load(request)
        try Task.checkCancellation()
        guard data.count <= MeetingNativeToolTransport.maximumResponseBytes else { throw MeetingNativeToolTransportError.responseTooLarge }
        guard let response = response as? HTTPURLResponse else { throw MeetingNativeToolTransportError.invalidResponse }
        return (data, response.statusCode)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue), (1...1_048_576).contains(n.intValue) else { return nil }
        return n.intValue
    }

    static func detect(config: AppConfig, credential: String, load: Load, cache: LocalChatProbeCache) async throws -> LocalChatCapabilities {
        let endpoint = try endpoint(config)
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        let wire: LocalChatCapabilities.Wire = provider == .ollama ? .ollama : .openAI
        let model = MeetingTextGenerationClient.model(config)
        let template = try MeetingTextGenerationClient.makeRequest(.init(system: "", user: "", config: config), credential: credential)
        var metadata = template
        metadata.httpBody = nil; metadata.timeoutInterval = 15
        if wire == .ollama {
            metadata.url = try sibling(endpoint, removing: "api/chat", adding: "api/show")
            metadata.httpBody = try ChatFileReader.requestData(["model": model, "verbose": false])
        } else {
            metadata.httpMethod = "GET"
            if provider == .lmStudio {
                let suffix = endpoint.path.hasSuffix("/v1/chat/completions") ? "v1/chat/completions" : "chat/completions"
                metadata.url = try sibling(endpoint, removing: suffix, adding: "api/v1/models")
            } else {
                metadata.url = try sibling(endpoint, removing: "chat/completions", adding: "models")
            }
        }
        let (data, status) = try await checked(metadata, load: load)
        var tools: Bool?; var context: Int?
        if (200..<300).contains(status) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MeetingNativeToolTransportError.invalidResponse }
            if wire == .ollama {
                if let capabilities = object["capabilities"] as? [String] { tools = capabilities.contains("tools") }
                let info = object["model_info"] as? [String: Any] ?? [:]
                let ceiling = (info["general.architecture"] as? String).flatMap { integer(info[$0 + ".context_length"]) }
                    ?? info.filter { $0.key.hasSuffix(".context_length") }.values.compactMap(integer).min()
                let parameters = (object["parameters"] as? String ?? "").split(separator: "\n")
                let configured = parameters.compactMap { line -> Int? in
                    let words = line.split(whereSeparator: \.isWhitespace)
                    return words.count == 2 && words[0] == "num_ctx" ? integer(Int(words[1])) : nil
                }.last ?? 8_192
                // Pin num_ctx on inference too: architecture maximum alone does
                // not describe the server's effective allocated context window.
                context = min(configured, ceiling ?? configured)
            } else {
                let models = object["models"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
                let matches = models.filter { entry in
                    entry["id"] as? String == model || entry["key"] as? String == model
                        || (entry["loaded_instances"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == model }
                }
                if matches.count == 1, let entry = matches.first {
                    if let cap = entry["capabilities"] as? [String: Any] {
                        tools = cap["trained_for_tool_use"] as? Bool ?? cap["tool_calling"] as? Bool ?? cap["tools"] as? Bool
                    } else if let cap = entry["capabilities"] as? [String] { tools = cap.contains("tools") || cap.contains("tool_calling") }
                    let instances = entry["loaded_instances"] as? [[String: Any]] ?? []
                    let selected = instances.contains { $0["id"] as? String == model } ? instances.filter { $0["id"] as? String == model } : instances
                    context = selected.compactMap { integer(($0["config"] as? [String: Any])?["context_length"]) }.min()
                        ?? integer(entry["context_length"])
                    // An unloaded LM Studio model's architecture maximum is not
                    // its future load configuration. Retain the conservative default.
                    if provider != .lmStudio { context = context ?? integer(entry["max_context_length"]) }
                }
            }
        } else if ![404, 405, 501].contains(status) { throw MeetingTextGenerationError.failed(status) }
        if tools == nil {
            let headers = template.allHTTPHeaderFields ?? [:]
            let identity = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint.absoluteString, "model": model, "headers": headers], options: [.sortedKeys])
            let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            if let cached = await cache.value(key) { tools = cached }
            else {
                tools = try await probe(template: template, model: model, wire: wire, load: load)
                await cache.save(tools!, key: key)
            }
        }
        return .init(wire: wire, provider: config.meetingSummaryBackend, model: model, endpoint: endpoint,
                     nativeTools: tools == true, contextTokens: context, template: template, configuration: config)
    }

    private static func probe(template: URLRequest, model: String, wire: LocalChatCapabilities.Wire, load: Load) async throws -> Bool {
        let nonce = UUID().uuidString
        var request = template; request.timeoutInterval = 90
        var body: [String: Any] = ["model": model, "stream": false,
            "messages": [["role": "user", "content": "Call muesli_capability_probe with token \(nonce). This is a synthetic capability check; do not answer in prose."]],
            "tools": [["type": "function", "function": ["name": "muesli_capability_probe", "description": "Synthetic API capability check; no action is executed.",
                "parameters": ["type": "object", "properties": ["token": ["type": "string", "enum": [nonce]]], "required": ["token"], "additionalProperties": false]]]]]
        if wire == .openAI {
            body["max_tokens"] = 128
            body["tool_choice"] = ["type": "function", "function": ["name": "muesli_capability_probe"]]
        } else { body["options"] = ["num_predict": 128] }
        request.httpBody = try ChatFileReader.requestData(body)
        let (data, status) = try await checked(request, load: load)
        if [400, 422].contains(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = object["error"] as? [String: Any]
            let text = ((error?["message"] as? String) ?? (object["error"] as? String) ?? "").lowercased()
            if (text.contains("tool") || text.contains("function")),
               ["not support", "unsupported", "not implemented", "unknown", "unrecognized"].contains(where: text.contains) { return false }
        }
        guard (200..<300).contains(status) else { throw MeetingTextGenerationError.failed(status) }
        let response = try parse(data, wire: wire)
        guard response.calls.count == 1, let call = response.calls.first, call.name == "muesli_capability_probe",
              let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String], args == ["token": nonce] else { return false }
        return true
    }

    static func body(_ request: MeetingNativeToolRequest, capabilities: LocalChatCapabilities) throws -> [String: Any] {
        guard request.base.images.isEmpty, request.inputItems.count <= ChatFileReader.maximumRequestBytes,
              request.tools.count <= 32_768,
              let input = try JSONSerialization.jsonObject(with: request.inputItems) as? [[String: Any]],
              let definitions = try JSONSerialization.jsonObject(with: request.tools) as? [[String: Any]] else { throw MeetingChatHarnessError.toolProtocol }
        var messages: [[String: Any]] = [["role": "system", "content": request.base.system]]
        var names: [String: String] = [:]; var waiting = Set<String>()
        for item in input {
            if item["type"] as? String == "local_chat_assistant" {
                guard waiting.isEmpty, item["wire"] as? String == capabilities.wire.rawValue,
                      let message = item["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let ids = item["call_ids"] as? [String], let calls = message["tool_calls"] as? [[String: Any]], ids.count == calls.count else { throw MeetingChatHarnessError.toolProtocol }
                for (id, call) in zip(ids, calls) {
                    guard names[id] == nil, let fn = call["function"] as? [String: Any], let name = fn["name"] as? String else { throw MeetingChatHarnessError.toolProtocol }
                    names[id] = name; waiting.insert(id)
                }
                messages.append(message)
            } else if item["type"] as? String == "function_call_output" {
                guard let id = item["call_id"] as? String, waiting.remove(id) != nil, let name = names[id], let output = item["output"] as? String else { throw MeetingChatHarnessError.toolProtocol }
                if capabilities.wire == .ollama { messages.append(["role": "tool", "tool_name": name, "content": output]) }
                else { messages.append(["role": "tool", "tool_call_id": id, "content": output]) }
            } else {
                guard waiting.isEmpty, item["role"] as? String == "user", let blocks = item["content"] as? [[String: Any]], blocks.allSatisfy({ $0["type"] as? String == "input_text" }) else { throw MeetingChatHarnessError.toolProtocol }
                messages.append(["role": "user", "content": blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")])
            }
        }
        guard waiting.isEmpty else { throw MeetingChatHarnessError.toolProtocol }
        var body: [String: Any] = ["model": capabilities.model, "messages": messages, "stream": false]
        if request.allowTools {
            body["tools"] = try definitions.map { tool -> [String: Any] in
                guard let name = tool["name"] as? String, let parameters = tool["parameters"] as? [String: Any] else { throw MeetingChatHarnessError.toolProtocol }
                return ["type": "function", "function": ["name": name, "description": tool["description"] as? String ?? "", "parameters": parameters]]
            }
        }
        let limit = min(request.base.maxOutputTokens, request.base.outputTokenLimit ?? request.base.maxOutputTokens)
        if capabilities.wire == .ollama {
            var options = ["num_predict": limit]
            if let context = capabilities.contextTokens { options["num_ctx"] = context }
            body["options"] = options
        } else {
            body["max_tokens"] = limit
            if request.allowTools { body["tool_choice"] = "auto" }
        }
        return body
    }

    static func parse(_ data: Data, wire: LocalChatCapabilities.Wire, maximumArgumentBytes: Int = MeetingNativeToolTransport.defaultMaximumArgumentBytes) throws -> MeetingNativeToolResponse {
        guard data.count <= MeetingNativeToolTransport.maximumResponseBytes else { throw MeetingNativeToolTransportError.responseTooLarge }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any], payload["error"] == nil || payload["error"] is NSNull else { throw MeetingNativeToolTransportError.invalidResponse }
        let message: [String: Any]
        if wire == .ollama {
            guard payload["done"] as? Bool == true, let value = payload["message"] as? [String: Any] else { throw MeetingNativeToolTransportError.incompleteResponse }
            guard payload["done_reason"] as? String != "length" else { throw MeetingNativeToolTransportError.incompleteResponse }
            message = value
        } else {
            guard let choices = payload["choices"] as? [[String: Any]], choices.count == 1, let choice = choices.first,
                  let finish = choice["finish_reason"] as? String, ["stop", "tool_calls"].contains(finish),
                  let value = choice["message"] as? [String: Any] else { throw MeetingNativeToolTransportError.incompleteResponse }
            message = value
        }
        guard message["role"] as? String == "assistant", message["refusal"] == nil || message["refusal"] is NSNull else { throw MeetingNativeToolTransportError.invalidResponse }
        let rawCalls: [[String: Any]]
        if let raw = message["tool_calls"], !(raw is NSNull) {
            guard let value = raw as? [[String: Any]], value.count <= MeetingChatNativeHarness.maximumToolCalls else { throw MeetingNativeToolTransportError.malformedToolCall }
            rawCalls = value
        } else { rawCalls = [] }
        var calls: [MeetingNativeToolCall] = []; var normalized: [[String: Any]] = []; var seen = Set<String>()
        for raw in rawCalls {
            guard raw["type"] == nil || raw["type"] as? String == "function", let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String, name.range(of: "^[a-z_][a-z0-9_]{0,127}$", options: .regularExpression) != nil else { throw MeetingNativeToolTransportError.malformedToolCall }
            let arguments: String; let argumentObject: [String: Any]
            if wire == .ollama, let object = function["arguments"] as? [String: Any] {
                argumentObject = object; arguments = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            } else {
                guard let text = function["arguments"] as? String, text.utf8.count <= maximumArgumentBytes,
                      let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw MeetingNativeToolTransportError.malformedToolCall }
                arguments = text; argumentObject = object
            }
            guard arguments.utf8.count <= maximumArgumentBytes else { throw MeetingNativeToolTransportError.malformedToolCall }
            let id = raw["id"] as? String ?? (wire == .ollama ? UUID().uuidString : "")
            guard !id.isEmpty, id.utf8.count <= 256, seen.insert(id).inserted else { throw MeetingNativeToolTransportError.malformedToolCall }
            calls.append(.init(id: id, name: name, arguments: arguments))
            if wire == .ollama {
                var fn: [String: Any] = ["name": name, "arguments": argumentObject]
                if let index = function["index"] as? Int { fn["index"] = index }
                normalized.append(["type": "function", "function": fn])
            } else { normalized.append(["type": "function", "id": id, "function": ["name": name, "arguments": arguments]]) }
        }
        let text = message["content"] as? String ?? ""
        guard !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingNativeToolTransportError.emptyOutput }
        var replay: [String: Any] = ["role": "assistant", "content": text, "tool_calls": normalized]
        // Opaque reasoning is needed by some local parsers during native replay.
        // It stays in bounded attempt memory, never in UI/history/persistence.
        for key in ["thinking", "reasoning_content"] { if let value = message[key] as? String { replay[key] = value } }
        let output: [[String: Any]] = calls.isEmpty ? [] : [["type": "local_chat_assistant", "wire": wire.rawValue, "message": replay, "call_ids": calls.map(\.id)]]
        return .init(outputItems: try JSONSerialization.data(withJSONObject: output), calls: calls, text: text)
    }
}
