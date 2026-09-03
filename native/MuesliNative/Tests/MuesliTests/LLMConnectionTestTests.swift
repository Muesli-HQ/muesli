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
        let error: Error?

        init(statusCode: Int, data: Data) {
            self.statusCode = statusCode
            self.data = data
            error = nil
        }

        init(error: Error) {
            statusCode = 0
            data = Data()
            self.error = error
        }
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
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
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

private actor ChatGPTConnectionTestProbe {
    private(set) var firstStarted = false
    private(set) var secondStarted = false
    private(set) var secondEnteredResponder = false

    func markFirstStarted() {
        firstStarted = true
    }

    func markSecondStarted() {
        secondStarted = true
    }

    func markSecondEnteredResponder() {
        secondEnteredResponder = true
    }
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
            #expect(body?["input"] as? [[String: Any]] != nil)
            #expect(body?["instructions"] == nil)
            #expect(body?["max_output_tokens"] as? Int == 128)
            #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "high")
            #expect((body?["text"] as? [String: Any])?["verbosity"] as? String == "low")
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

    @Test("Hosted OpenAI test mirrors cleanup request and response contracts")
    func hostedOpenAIRequest() async throws {
        LLMConnectionURLProtocol.install { request in
            let body = connectionTestRequestBody(request)
            #expect(body?["model"] as? String == "gpt-5.6-sol")
            #expect(body?["instructions"] as? String == "Reply with OK.")
            #expect(body?["input"] as? String == "Connection test.")
            #expect(body?["text"] == nil)
            #expect(body?["max_output_tokens"] as? Int == 128)
            #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "high")
            return .init(
                statusCode: 200,
                data: Data(#"{"error":null,"output":[{"content":[{"text":"O"},{"text":"K"}]}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openAIAPIKey = "openai-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openAI,
            config: config,
            model: "gpt-5.6-sol",
            context: .hostedGeneration,
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

    @Test("Custom OpenAI-compatible test mirrors production token fields without reasoning effort")
    func customOpenAIProductionFields() async throws {
        LLMConnectionURLProtocol.install { request in
            let body = connectionTestRequestBody(request)
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            #expect(body?["max_completion_tokens"] as? Int == 256)
            #expect(body?["max_tokens"] == nil)
            #expect(body?["reasoning_effort"] == nil)
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.customLLMURL = "https://api.openai.com/v1"
        config.customLLMAPIKey = "static-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .customLLM,
            config: config,
            model: "gpt-5.6-sol",
            session: makeSession()
        )
    }

    @Test("Invalid Custom headers are rejected before running the API Key Command or sending")
    func invalidCustomHeadersPreflightCredentialCommand() async {
        let commandSentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-connection-command-\(UUID().uuidString)")
        let requestSentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-connection-request-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: commandSentinel)
            try? FileManager.default.removeItem(at: requestSentinel)
        }

        LLMConnectionURLProtocol.install { _ in
            _ = FileManager.default.createFile(atPath: requestSentinel.path, contents: Data())
            return .init(statusCode: 200, data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.customLLMURL = "https://gateway.example.com/v1"
        config.customLLMAPIKeyCommand = "printf ran > '\(commandSentinel.path)'"
        config.customLLMHeaders = [CustomLLMRequestHeader(name: "Authorization", value: "invalid")]

        await #expect(throws: CustomLLMRequestHeaderError.self) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .customLLM,
                config: config,
                model: "custom-model",
                session: makeSession()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: commandSentinel.path))
        #expect(!FileManager.default.fileExists(atPath: requestSentinel.path))
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

    @Test("ChatGPT connection-test error logging omits provider details while normal logging keeps them")
    func chatGPTErrorLoggingPrivacy() {
        let normalLog = ChatGPTResponsesClient.errorLogMessage(
            logCategory: "summary",
            statusCode: 401,
            message: "provider secret diagnostic",
            includeProviderDetails: true
        )
        #expect(normalLog.contains("HTTP 401"))
        #expect(normalLog.contains("provider secret diagnostic"))

        let connectionLog = ChatGPTResponsesClient.errorLogMessage(
            logCategory: "connection-test",
            statusCode: 401,
            message: "provider secret diagnostic",
            includeProviderDetails: false
        )
        #expect(connectionLog.contains("HTTP 401"))
        #expect(!connectionLog.contains("provider secret diagnostic"))
    }

    @Test("ChatGPT malformed HTTP 200 responses map to an incompatible response")
    func chatGPTMalformedSuccessResponse() async {
        await #expect(throws: LLMConnectionTestError.invalidResponse) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .chatGPT,
                config: AppConfig(),
                model: "gpt-5.4-mini",
                chatGPTResponder: { _, _, _, _ in
                    throw ChatGPTResponsesError.backendFailed(
                        statusCode: 200,
                        message: "Malformed ChatGPT stream payload."
                    )
                }
            )
        }
    }

    @Test("A waiting ChatGPT connection test can be cancelled without entering its responder")
    func chatGPTGateWaitingCancellation() async {
        let probe = ChatGPTConnectionTestProbe()
        let first = Task {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .chatGPT,
                config: AppConfig(),
                model: "gpt-5.4-mini",
                chatGPTResponder: { _, _, _, _ in
                    await probe.markFirstStarted()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "OK"
                }
            )
        }

        while !(await probe.firstStarted) {
            await Task.yield()
        }

        let second = Task {
            await probe.markSecondStarted()
            try await MeetingSummaryClient.testLLMConnection(
                backend: .chatGPT,
                config: AppConfig(),
                model: "gpt-5.4-mini",
                chatGPTResponder: { _, _, _, _ in
                    await probe.markSecondEnteredResponder()
                    return "OK"
                }
            )
        }

        while !(await probe.secondStarted) {
            await Task.yield()
        }
        for _ in 0..<100 {
            if await MeetingSummaryClient.chatGPTConnectionTestWaiterCount() == 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await MeetingSummaryClient.chatGPTConnectionTestWaiterCount() == 1)
        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(await MeetingSummaryClient.chatGPTConnectionTestWaiterCount() == 0)
        #expect(await probe.secondEnteredResponder == false)

        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
    }

    @Test("URLSession cancellation is preserved for non-ChatGPT connection tests")
    func urlSessionCancellation() async {
        LLMConnectionURLProtocol.install { _ in
            .init(error: URLError(.cancelled))
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = "openrouter-key"
        await #expect(throws: CancellationError.self) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .openRouter,
                config: config,
                model: "provider/model",
                session: makeSession(),
                environment: [:]
            )
        }
    }

    @Test("authentication failure is sanitized with provider-neutral recovery guidance")
    func authenticationFailure() async {
        #expect(LLMConnectionTestError.authenticationFailed.localizedDescription ==
            "Authentication failed. Reconnect the account or check the configured credentials.")
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

    @Test("cleanup and Quill contexts use configured credentials and hosted response parsing")
    func configurationFirstCredentialPrecedence() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer configured-key")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"text":"OK"}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = "configured-key"
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openRouter,
            config: config,
            model: "provider/model",
            context: .hostedGeneration,
            session: makeSession(),
            environment: ["OPENROUTER_API_KEY": "environment-key"]
        )
    }

    @Test("hosted OpenRouter trims the environment fallback credential in Authorization")
    func hostedOpenRouterTrimsEnvironmentFallbackCredential() async throws {
        LLMConnectionURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer environment-key")
            return .init(
                statusCode: 200,
                data: Data(#"{"choices":[{"text":"OK"}]}"#.utf8)
            )
        }
        defer { LLMConnectionURLProtocol.uninstall() }

        var config = AppConfig()
        config.openRouterAPIKey = ""
        try await MeetingSummaryClient.testLLMConnection(
            backend: .openRouter,
            config: config,
            model: "provider/model",
            context: .hostedGeneration,
            session: makeSession(),
            environment: ["OPENROUTER_API_KEY": "  \n environment-key \n  "]
        )
    }

    @Test("connection credentials preserve each production context's optional and whitespace semantics")
    func credentialBoundarySemantics() {
        #expect(MeetingSummaryClient.connectionTestAPIKey(
            configured: "  configured-key  ",
            environment: nil,
            context: .meetingSummary
        ) == "  configured-key  ")
        #expect(MeetingSummaryClient.connectionTestAPIKey(
            configured: "configured-key",
            environment: "",
            context: .meetingSummary
        ).isEmpty)
        #expect(MeetingSummaryClient.connectionTestAPIKey(
            configured: "configured-key",
            environment: "  environment-key  ",
            context: .meetingSummary
        ) == "  environment-key  ")
        #expect(MeetingSummaryClient.connectionTestAPIKey(
            configured: "  configured-key  ",
            environment: "environment-key",
            context: .hostedGeneration
        ) == "configured-key")
        #expect(MeetingSummaryClient.connectionTestAPIKey(
            configured: "   ",
            environment: "  environment-key  ",
            context: .hostedGeneration
        ) == "  environment-key  ")
    }

    @Test("summary treats an explicitly empty environment credential as present")
    func emptySummaryEnvironmentCredentialDoesNotFallBack() async {
        var config = AppConfig()
        config.openRouterAPIKey = "configured-key"
        await #expect(throws: LLMConnectionTestError.missingCredential) {
            try await MeetingSummaryClient.testLLMConnection(
                backend: .openRouter,
                config: config,
                model: "provider/model",
                session: makeSession(),
                environment: ["OPENROUTER_API_KEY": ""]
            )
        }
    }

    @Test("a non-null provider error in a successful HTTP response is rejected")
    func providerFailureResponse() async {
        LLMConnectionURLProtocol.install { _ in
            .init(
                statusCode: 200,
                data: Data(#"{"status":"completed","output":[{"type":"message","content":[{"text":"OK"}]}],"error":{"message":"provider failed"}}"#.utf8)
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
