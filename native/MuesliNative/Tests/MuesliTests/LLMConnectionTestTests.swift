import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

private func connectionTestRequestBody(_ request: URLRequest) -> [String: Any]? {
    let data: Data?
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            collected.append(buffer, count: count)
        }
        data = collected
    } else {
        data = nil
    }
    return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

private final class LLMConnectionURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    private static let lock = NSLock()
    private static var provider: ((URLRequest) -> Response)?

    static func install(_ provider: @escaping (URLRequest) -> Response) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    static func uninstall() {
        lock.lock()
        provider = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: Response? = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.provider?(request)
        }()
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("LLM connection test", .serialized)
struct LLMConnectionTests {
    @Test("OpenAI Responses test uses configured key and reasoning model")
    func openAIRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")
            let body = connectionTestRequestBody(request)
            #expect(body?["model"] as? String == "gpt-5.6-sol")
            #expect(body?["max_output_tokens"] as? Int == 128)
            #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "high")
            return .init(
                statusCode: 200,
                data: Data(#"{"status":"completed","output":[{"type":"message","content":[{"text":"OK"}]}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openAIAPIKey = "openai-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openAI,
            config: config,
            model: "gpt-5.6-sol",
            session: makeSession(),
            environment: [:]
        )
    }

    @Test("OpenRouter test uses configured key, model, and attribution header")
    func openRouterRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openrouter-key")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == AppIdentity.displayName)
            #expect(connectionTestRequestBody(request)?["model"] as? String == "provider/model")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = "openrouter-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openRouter,
            config: config,
            model: "provider/model",
            session: makeSession(),
            environment: [:]
        )
    }

    @Test("Ollama test uses local chat endpoint and model")
    func ollamaRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
            let body = connectionTestRequestBody(request)
            #expect(body?["model"] as? String == "qwen3.5")
            #expect((body?["options"] as? [String: Any])?["num_predict"] as? Int == 256)
            return .init(statusCode: 200, data: Data(#"{"message":{"content":"OK"}}"#.utf8))
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        try await MeetingSummaryClient.testLLMConnection(
            backend: .ollama,
            config: AppConfig(),
            model: "qwen3.5",
            session: makeSession()
        )
    }

    @Test("LM Studio test uses OpenAI-compatible endpoint")
    func lmStudioRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
            #expect(connectionTestRequestBody(request)?["model"] as? String == "loaded-model")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        try await MeetingSummaryClient.testLLMConnection(
            backend: .lmStudio,
            config: AppConfig(),
            model: "loaded-model",
            session: makeSession()
        )
    }

    @Test("Custom OpenAI-compatible test uses API Key Command credential")
    func customOpenAIRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.url?.absoluteString == "https://gateway.example.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dynamic-token")
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            #expect(connectionTestRequestBody(request)?["model"] as? String == "custom-model")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.customLLMURL = "https://gateway.example.com/v1"
        config.customLLMAPIKeyCommand = "printf dynamic-token"
        config.customLLMHeaders = customHeaders()
        try await MeetingSummaryClient.testLLMConnection(
            backend: .customLLM,
            config: config,
            model: "custom-model",
            session: makeSession()
        )
    }

    @Test("Custom gateway GPT model uses max completion tokens")
    func customGatewayGPTRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            let body = connectionTestRequestBody(request)
            #expect(body?["max_completion_tokens"] as? Int == 256)
            #expect(body?["max_tokens"] == nil)
            #expect(body?["reasoning_effort"] as? String == "low")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.customLLMURL = "https://gateway.example.com/v1"
        config.customLLMAPIKey = "static-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .customLLM,
            config: config,
            model: "gpt-5.6-sol",
            session: makeSession()
        )
    }

    @Test("Custom gateway reasoning model has enough output budget")
    func customGatewayReasoningModel() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(connectionTestRequestBody(request)?["max_tokens"] as? Int == 256)
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK","reasoning_content":"reasoning"},"finish_reason":"stop"}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.customLLMURL = "https://gateway.example.com/v1"
        config.customLLMAPIKey = "static-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .customLLM,
            config: config,
            model: "baseten/zai-org/GLM-5.2",
            session: makeSession()
        )
    }

    @Test("Custom Anthropic test uses static credential and Messages endpoint")
    func customAnthropicRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.url?.absoluteString == "https://gateway.example.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "static-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            return .init(
                statusCode: 200,
                data: Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.customLLMURL = "https://gateway.example.com"
        config.customLLMAPIKey = "static-key"
        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        config.customLLMHeaders = customHeaders()
        try await MeetingSummaryClient.testLLMConnection(
            backend: .customLLM,
            config: config,
            model: "claude-model",
            session: makeSession()
        )
    }

    @Test("ChatGPT test uses the OAuth-backed responder")
    func chatGPTRequest() async throws {
        try await MeetingSummaryClient.testLLMConnection(
            backend: .chatGPT,
            config: AppConfig(),
            model: "gpt-5.4-mini",
            chatGPTResponder: { systemPrompt, userPrompt, model, maxOutputTokens in
                #expect(systemPrompt == "Reply with OK.")
                #expect(userPrompt == "Connection test.")
                #expect(model == "gpt-5.4-mini")
                #expect(maxOutputTokens == 128)
                return "OK"
            }
        )
    }

    @Test("ChatGPT requires usable response text")
    func chatGPTEmptyResponse() async {
        await #expect(throws: LLMConnectionTestError.invalidResponse) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .chatGPT,
                config: AppConfig(),
                model: "gpt-5.4-mini",
                chatGPTResponder: { _, _, _, _ in "" }
            )
        }
    }

    @Test("authentication failure is sanitized")
    func authenticationFailure() async {
        LLMConnectionURLProtocol.install { _ in
            .init(statusCode: 401, data: Data(#"{"error":{"message":"secret diagnostic"}}"#.utf8))
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = "invalid-key"
        await #expect(throws: LLMConnectionTestError.authenticationFailed) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .openRouter,
                config: config,
                model: "provider/model",
                session: makeSession(),
                environment: [:]
            )
        }
    }

    @Test("summary context gives environment credentials precedence")
    func environmentFirstCredentialPrecedence() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer environment-key")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = "configured-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openRouter,
            config: config,
            model: "provider/model",
            session: makeSession(),
            environment: ["OPENROUTER_API_KEY": "environment-key"]
        )
    }

    @Test("cleanup and Quill contexts give configured credentials precedence")
    func configurationFirstCredentialPrecedence() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer configured-key")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = "configured-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openRouter,
            config: config,
            model: "provider/model",
            credentialPrecedence: .configurationFirst,
            session: makeSession(),
            environment: ["OPENROUTER_API_KEY": "environment-key"]
        )
    }

    @Test("provider failure in a successful HTTP response is rejected")
    func providerFailureResponse() async {
        LLMConnectionURLProtocol.install { _ in
            .init(
                statusCode: 200,
                data: Data(#"{"status":"failed","output":[],"error":{"message":"provider failed"}}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openAIAPIKey = "openai-key"
        await #expect(throws: LLMConnectionTestError.invalidResponse) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .openAI,
                config: config,
                model: "gpt-5.4-mini",
                session: makeSession(),
                environment: [:]
            )
        }
    }

    @Test("successful HTTP response must match the provider format", arguments: [Data(#"{"status":"ok"}"#.utf8), Data("not-json".utf8)])
    func invalidResponse(data: Data) async {
        LLMConnectionURLProtocol.install { _ in .init(statusCode: 200, data: data) }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openAIAPIKey = "openai-key"
        await #expect(throws: LLMConnectionTestError.invalidResponse) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .openAI,
                config: config,
                model: "gpt-5.4-mini",
                session: makeSession(),
                environment: [:]
            )
        }
    }

    @Test("Custom cleanup context requires an explicit endpoint")
    func explicitEndpointRequirement() async {
        await #expect(throws: LLMConnectionTestError.invalidEndpoint) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .customLLM,
                config: AppConfig(),
                model: "custom-model",
                requiresExplicitEndpoint: true
            )
        }
    }

    @Test("model and provider credentials are validated")
    func missingConfiguration() async {
        await #expect(throws: LLMConnectionTestError.missingModel) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .lmStudio,
                config: AppConfig(),
                model: ""
            )
        }
        await #expect(throws: LLMConnectionTestError.missingCredential) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .openAI,
                config: AppConfig(),
                model: "gpt-5.4-mini",
                environment: [:]
            )
        }
    }

    private func customHeaders() -> [CustomLLMRequestHeader] {
        [
            CustomLLMRequestHeader(name: "source", value: "muesli"),
            CustomLLMRequestHeader(name: "org-id", value: "2"),
        ]
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMConnectionURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
