import Foundation

/// Reuses credentials and wire adapters, with an ephemeral Quill-specific config snapshot.
/// No meeting settings or provider selections are mutated.
enum QuillAssistantClient {
    static func generate(_ request: QuillAssistantRequest, config: AppConfig, model: String) async throws -> QuillAssistantAction {
        let backend = TranscriptCleanupBackendOption.resolved(config.quilBackend)
        guard let llm = backend.llmBackend else { throw QuilTransformationError.unsupportedModel }
        var providerConfig = config
        let provider = MeetingSummaryBackendOption.resolved(llm.backend)
        providerConfig.meetingSummaryBackend = llm.backend
        providerConfig[keyPath: provider.modelKeyPath] = model
        providerConfig.meetingSummaryReasoningEffort = config.transcriptCleanupReasoningEffort
        let client = MeetingTextGenerationClient()
        let prompt = try request.prompt()
        let base = MeetingTextGenerationRequest(system: QuillAssistantRequest.system, user: prompt,
            config: providerConfig, maxOutputTokens: request.hostedMaximumOutputTokens)
        if client.supportsNativeTools(config: providerConfig) {
            let response = try await client.generateNative(.init(base: base,
                inputItems: JSONSerialization.data(withJSONObject: [["role": "user", "content": prompt]]),
                tools: JSONSerialization.data(withJSONObject: request.tools), allowTools: true,
                requiresMeetingAnswerFormat: false, maximumArgumentBytes: QuillAssistantRequest.maximumArgumentBytes))
            try Task.checkCancellation()
            if response.calls.isEmpty {
                return try request.decode(name: "reply", arguments: encodeText(response.text))
            }
            guard response.calls.count == 1 else { throw QuillAssistantError.invalidResponse }
            return try request.decode(name: response.calls[0].name, arguments: response.calls[0].arguments)
        }
        let credential = try await client.credentialResolver(providerConfig)
        var wire = try MeetingTextGenerationClient.makeRequest(base, credential: credential)
        guard let data = wire.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuillAssistantError.invalidResponse }
        let anthropic = provider == .anthropic || (provider == .customLLM && config.customLLMFormat == CustomLLMFormat.anthropic.rawValue)
        if anthropic {
            body["tools"] = request.tools.map { ["name": $0["name"]!, "description": $0["description"]!, "input_schema": $0["parameters"]!] }
            body["tool_choice"] = ["type": "auto", "disable_parallel_tool_use": true] as [String: Any]
        } else {
            body["tools"] = request.tools.map { ["type": "function", "function": $0.filter { ["name", "description", "parameters"].contains($0.key) }] as [String: Any] }
            if provider != .ollama { body["parallel_tool_calls"] = false; body["tool_choice"] = "auto" }
        }
        wire.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await client.load(wire)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranscriptCleanupError.backendFailed("Quill's provider rejected the tool request. Check the selected model's tool support and connection.")
        }
        return try decode(responseData, request: request, anthropic: anthropic, ollama: provider == .ollama)
    }

    static func encodeText(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
    }
    static func decode(_ data: Data, request: QuillAssistantRequest, anthropic: Bool, ollama: Bool) throws -> QuillAssistantAction {
        guard data.count <= 2_097_152,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuillAssistantError.invalidResponse }
        if anthropic {
            guard ["end_turn", "tool_use"].contains(json["stop_reason"] as? String ?? ""),
                  let content = json["content"] as? [[String: Any]] else { throw QuillAssistantError.invalidResponse }
            let calls = content.filter { $0["type"] as? String == "tool_use" }
            if calls.isEmpty {
                return try request.decode(name: "reply", arguments: encodeText(content.compactMap { $0["text"] as? String }.joined(separator: "\n")))
            }
            guard calls.count == 1, let name = calls[0]["name"] as? String, let input = calls[0]["input"] as? [String: Any] else { throw QuillAssistantError.invalidResponse }
            return try request.decode(name: name, arguments: String(decoding: JSONSerialization.data(withJSONObject: input), as: UTF8.self))
        }
        let message: [String: Any]
        if ollama {
            guard json["done"] as? Bool == true, json["done_reason"] as? String != "length",
                  let value = json["message"] as? [String: Any] else { throw QuillAssistantError.invalidResponse }
            message = value
        } else {
            guard let choices = json["choices"] as? [[String: Any]], choices.count == 1,
                  ["stop", "tool_calls"].contains(choices[0]["finish_reason"] as? String ?? ""),
                  let value = choices[0]["message"] as? [String: Any] else { throw QuillAssistantError.invalidResponse }
            message = value
        }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            return try request.decodeNative(String(decoding: JSONSerialization.data(withJSONObject: ["tool_calls": calls]), as: UTF8.self))
        }
        return try request.decode(name: "reply", arguments: encodeText(message["content"] as? String ?? ""))
    }
}
