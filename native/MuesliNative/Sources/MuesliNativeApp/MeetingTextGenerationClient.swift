import Foundation

struct MeetingTextGenerationRequest {
    let system: String
    let user: String
    let config: AppConfig
    var maxOutputTokens: Int = 1_500
}

protocol MeetingTextGenerating: Sendable {
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String
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
    var credentialResolver: @Sendable (AppConfig) -> String = { Self.credential($0) }
    var load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    var chatGPT: @Sendable (MeetingTextGenerationRequest) async throws -> String = { request in
        try await ChatGPTResponsesClient.respond(systemPrompt: request.system, userPrompt: request.user,
            model: Self.model(request.config), maxOutputTokens: request.maxOutputTokens,
            reasoningEffort: request.config.meetingSummaryReasoningEffort, logCategory: "meeting-chat")
    }

    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        try Task.checkCancellation()
        if MeetingSummaryBackendOption.resolved(request.config.meetingSummaryBackend) == .chatGPT {
            return try await chatGPT(request)
        }
        let urlRequest = try Self.makeRequest(request, credential: credentialResolver(request.config))
        let (data, response) = try await load(urlRequest)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MeetingTextGenerationError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else { throw MeetingTextGenerationError.failed(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MeetingTextGenerationError.emptyResponse }
        let text: String?
        switch MeetingSummaryBackendOption.resolved(request.config.meetingSummaryBackend) {
        case .openAI: text = MeetingSummaryClient.extractOpenAIText(from: json)
        case .ollama: text = (json["message"] as? [String: Any])?["content"] as? String
        case .customLLM where request.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue:
            text = MeetingSummaryClient.extractAnthropicText(from: json)
        default: text = MeetingSummaryClient.extractOpenRouterText(from: json)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingTextGenerationError.emptyResponse }
        return text
    }

    static func model(_ config: AppConfig) -> String {
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        let configured = config[keyPath: provider.modelKeyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        switch provider { case .chatGPT, .openAI: return "gpt-5.4-mini"; case .openRouter: return "openrouter/free"; case .ollama: return "qwen3.5"; default: return "" }
    }
    static func fastConfiguration(_ original: AppConfig) -> AppConfig {
        var config = original
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        if provider == .chatGPT || provider == .openAI {
            config[keyPath: provider.modelKeyPath] = "gpt-5.4-mini"
            config.meetingSummaryReasoningEffort = .off
        }
        return config
    }
    private static func credential(_ config: AppConfig) -> String {
        switch MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend) {
        case .openAI: return ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
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
            body = ["model": model, "instructions": input.system, "input": input.user, "store": false, "max_output_tokens": input.maxOutputTokens]
            if let effort = ReasoningEffortPolicy.apiValue(for: model, preferred: config.meetingSummaryReasoningEffort) { body["reasoning"] = ["effort": effort] }
        case .openRouter:
            guard !credential.isEmpty else { throw MeetingTextGenerationError.missingConnection }
            url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .ollama:
            guard let base = URL(string: config.ollamaURL.isEmpty ? "http://localhost:11434" : config.ollamaURL), ["http", "https"].contains(base.scheme ?? "") else { throw MeetingTextGenerationError.invalidEndpoint }
            url = base.appendingPathComponent("api/chat")
            body.removeValue(forKey: "max_tokens"); body["stream"] = false; body["options"] = ["num_predict": input.maxOutputTokens]
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
        return request
    }
}
