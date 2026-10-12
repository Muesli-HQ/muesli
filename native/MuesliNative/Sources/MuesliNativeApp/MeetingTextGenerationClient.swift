import Foundation
import MuesliCore

struct MeetingTextGenerationRequest {
    let system: String
    let user: String
    let config: AppConfig
    var maxOutputTokens: Int = 1_500
    var sessionID: UUID = UUID()
    var onReasoningSummary: (@Sendable (String) async -> Void)? = nil
}

protocol MeetingTextGenerating: Sendable {
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String
    func generateConversationTitle(_ request: MeetingTextGenerationRequest) async throws -> String?
    func supportsNativeTools(config: AppConfig) -> Bool
    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse
}

extension MeetingTextGenerating {
    func supportsNativeTools(config: AppConfig) -> Bool { false }
    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        throw MeetingTextGenerationError.invalidEndpoint
    }
    // Test/custom generators can opt out of background metadata generation.
    func generateConversationTitle(_ request: MeetingTextGenerationRequest) async throws -> String? { nil }
}

enum MeetingTextGenerationError: Error, LocalizedError {
    case missingConnection, invalidEndpoint, failed(Int), emptyResponse
    var errorDescription: String? {
        switch self {
        case .missingConnection: "Configure your meeting AI connection and model in Settings."
        case .invalidEndpoint: "Check the meeting AI endpoint in Settings."
        case .failed(let code): "Meeting AI returned HTTP \(code). Retry or check your connection settings."
        case .emptyResponse: "Meeting AI returned an empty or incomplete response. Please retry."
        }
    }
}

struct MeetingTextGenerationClient: MeetingTextGenerating {
    var credentialResolver: @Sendable (AppConfig) async throws -> String = { config in
        if MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend) == .customLLM {
            return try await MeetingSummaryClient.resolveCustomLLMAPIKey(config: config)
        }
        return Self.credential(config)
    }
    var load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    var chatGPT: @Sendable (MeetingTextGenerationRequest) async throws -> String = { request in
        try await ChatGPTResponsesClient.respond(systemPrompt: request.system, userPrompt: request.user,
            model: Self.model(request.config), maxOutputTokens: request.maxOutputTokens,
            reasoningEffort: request.config.meetingSummaryReasoningEffort, sessionID: request.sessionID, onReasoningSummary: request.onReasoningSummary, logCategory: "meeting-chat")
    }
    var claudeCode: @Sendable (MeetingTextGenerationRequest) async throws -> String = { request in
        try await ClaudeCodeSummarizer.run(instructions: request.system, input: request.user,
            model: request.config.claudeCodeModel, executablePath: request.config.claudeCodeExecutablePath)
    }

    func supportsNativeTools(config: AppConfig) -> Bool {
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        if provider == .chatGPT || provider == .openAI { return true }
        guard provider == .openRouter else { return false }
        let model = Self.model(config).lowercased()
        if model.hasPrefix("openai/gpt-") { return true }
        return ["openai/o1", "openai/o3", "openai/o4"].contains { family in
            model == family || model.hasPrefix(family + "-") || model.hasPrefix(family + ":")
        }
    }

    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        try Task.checkCancellation()
        let provider = MeetingSummaryBackendOption.resolved(request.base.config.meetingSummaryBackend)
        if provider == .chatGPT { return try await ChatGPTResponsesClient.respondNative(request) }
        guard supportsNativeTools(config: request.base.config) else { throw MeetingTextGenerationError.invalidEndpoint }
        let credential = try await credentialResolver(request.base.config)
        try Task.checkCancellation()
        var urlRequest = try Self.makeRequest(request.base, credential: credential)
        if provider == .openRouter { urlRequest.url = URL(string: "https://openrouter.ai/api/v1/responses")! }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: MeetingNativeToolTransport.requestBody(request, stream: false))
        let (data, response) = try await load(urlRequest)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MeetingTextGenerationError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else { throw MeetingTextGenerationError.failed(http.statusCode) }
        return try MeetingNativeToolTransport.parseResponse(data)
    }

    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        try Task.checkCancellation()
        if MeetingSummaryBackendOption.resolved(request.config.meetingSummaryBackend) == .chatGPT {
            return try await chatGPT(request)
        }
        if MeetingSummaryBackendOption.resolved(request.config.meetingSummaryBackend) == .claudeCode {
            return try await claudeCode(request)
        }
        if MeetingSummaryBackendOption.resolved(request.config.meetingSummaryBackend) == .customLLM {
            _ = try CustomLLMRequestHeaders.validated(request.config.customLLMHeaders)
        }
        let urlRequest = try Self.makeRequest(request, credential: await credentialResolver(request.config))
        let (data, response) = try await load(urlRequest)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MeetingTextGenerationError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else { throw MeetingTextGenerationError.failed(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MeetingTextGenerationError.emptyResponse }
        let text: String?
        switch MeetingSummaryBackendOption.resolved(request.config.meetingSummaryBackend) {
        case .openAI: text = MeetingSummaryClient.extractOpenAIText(from: json)
        case .ollama: text = (json["message"] as? [String: Any])?["content"] as? String
        case .anthropic: text = MeetingSummaryClient.extractAnthropicText(from: json)
        case .customLLM where request.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue:
            text = MeetingSummaryClient.extractAnthropicText(from: json)
        default: text = MeetingSummaryClient.extractOpenRouterText(from: json)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingTextGenerationError.emptyResponse }
        return text
    }

    func generateConversationTitle(_ request: MeetingTextGenerationRequest) async throws -> String? {
        try await generate(request)
    }

    static func model(_ config: AppConfig) -> String {
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        let configured = config[keyPath: provider.modelKeyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        switch provider {
        case .chatGPT: return SummaryModelPreset.chatGPTModels.first?.id ?? "gpt-5.4-mini"
        case .openAI: return SummaryModelPreset.openAIModels.first?.id ?? "gpt-5.4-mini"
        case .anthropic: return SummaryModelPreset.anthropicModels.first?.id ?? "claude-sonnet-5-5"
        case .claudeCode: return "CLI default"
        case .openRouter: return "openrouter/free"
        case .ollama: return "qwen3.5"
        default: return ""
        }
    }
    private static func credential(_ config: AppConfig) -> String {
        switch MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend) {
        case .openAI: return MeetingSummaryClient.resolvedOpenAIAPIKey(config: config)
        case .anthropic: return MeetingSummaryClient.resolvedAnthropicAPIKey(config: config)
        case .openRouter: return OpenRouterCredentialResolver.resolvedAPIKey(legacyAPIKey: config.openRouterAPIKey)
        case .customLLM: return config.customLLMAPIKey
        default: return ""
        }
    }

    static func makeRequest(_ input: MeetingTextGenerationRequest, credential: String) throws -> URLRequest {
        let config = input.config
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        let model = model(config)
        guard !model.isEmpty else { throw MeetingTextGenerationError.missingConnection }
        let messages = [["role": "system", "content": input.system], ["role": "user", "content": input.user]]
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": input.maxOutputTokens]
        let url: URL
        var anthropic = false
        switch provider {
        case .openAI:
            guard !credential.isEmpty else { throw MeetingTextGenerationError.missingConnection }
            url = URL(string: "https://api.openai.com/v1/responses")!
            let effort = ReasoningEffortPolicy.apiValue(for: model, preferred: config.meetingSummaryReasoningEffort)
            // Responses counts reasoning and visible text against the same limit.
            // Reserve space for reasoning plus the complete structured answer.
            // https://developers.openai.com/api/docs/guides/reasoning
            let budget = effort != nil && effort != "none" ? max(input.maxOutputTokens, 32_768) : input.maxOutputTokens
            body = ["model": model, "instructions": input.system, "input": input.user, "store": false, "max_output_tokens": budget]
            if let effort { body["reasoning"] = ["effort": effort] }
        case .openRouter:
            guard !credential.isEmpty else { throw MeetingTextGenerationError.missingConnection }
            url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .anthropic:
            guard !credential.isEmpty else { throw MeetingTextGenerationError.missingConnection }
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            anthropic = true
            body = ["model": model, "system": input.system, "messages": [["role": "user", "content": input.user]], "max_tokens": input.maxOutputTokens]
        case .ollama:
            guard let base = URL(string: config.ollamaURL.isEmpty ? "http://localhost:11434" : config.ollamaURL), ["http", "https"].contains(base.scheme ?? "") else { throw MeetingTextGenerationError.invalidEndpoint }
            url = base.appendingPathComponent("api/chat")
            body.removeValue(forKey: "max_tokens"); body["stream"] = false
            // Local models may think by default without a request-level flag.
            // Keep a bounded allowance for both thinking and the answer envelope.
            body["options"] = ["num_predict": max(input.maxOutputTokens, 8_192)]
        case .lmStudio:
            guard let resolved = MeetingSummaryClient.resolveLMStudioURL(config: config) else { throw MeetingTextGenerationError.invalidEndpoint }
            url = resolved
        case .customLLM:
            let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
            guard let resolved = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: format) else { throw MeetingTextGenerationError.invalidEndpoint }
            url = resolved; anthropic = format == .anthropic
            if anthropic {
                guard !credential.isEmpty else { throw MeetingTextGenerationError.missingConnection }
                body = ["model": model, "system": input.system, "messages": [["role": "user", "content": input.user]], "max_tokens": input.maxOutputTokens]
            } else if url.host == "api.openai.com" {
                body["max_completion_tokens"] = body.removeValue(forKey: "max_tokens")
            }
        default: throw MeetingTextGenerationError.invalidEndpoint
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = provider == .ollama || provider == .lmStudio || provider == .customLLM ? 300 : 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if !credential.isEmpty { request.setValue(anthropic ? credential : "Bearer \(credential)", forHTTPHeaderField: anthropic ? "x-api-key" : "Authorization") }
        if provider == .openRouter { request.setValue(AppIdentity.displayName, forHTTPHeaderField: "X-OpenRouter-Title") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if provider == .anthropic {
            return try AnthropicAPIRequest.make(url: url, apiKey: credential,
                workspaceID: MeetingSummaryClient.resolvedAnthropicWorkspaceID(config: config), body: body, timeout: request.timeoutInterval)
        }
        if provider == .customLLM { try CustomLLMRequestHeaders.apply(config.customLLMHeaders, to: &request) }
        return request
    }
}
