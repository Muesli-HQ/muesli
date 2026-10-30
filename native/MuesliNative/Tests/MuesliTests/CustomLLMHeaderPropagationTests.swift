import Darwin
import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI
@testable import MuesliNativeApp

private final class CustomLLMHeaderPropagationURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data

        init(statusCode: Int = 200, data: Data) {
            self.statusCode = statusCode
            self.data = data
        }
    }

    private static let lock = NSLock()
    private static var provider: ((URLRequest) -> Response)?

    static func install(_ provider: @escaping (URLRequest) -> Response) {
        lock.lock()
        self.provider = provider
        lock.unlock()
        URLProtocol.registerClass(Self.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(Self.self)
        lock.lock()
        provider = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if url.host == "headers.example.test" { return true }
        lock.lock()
        defer { lock.unlock() }
        guard provider != nil else { return false }
        return (url.host == "api.openai.com" && url.path == "/v1/responses")
            || (url.host == "openrouter.ai" && url.path == "/api/v1/chat/completions")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var body = Data()
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            body.append(contentsOf: buffer.prefix(bytesRead))
        }
        return body
    }

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

@Suite("Custom LLM header propagation", .serialized)
struct CustomLLMHeaderPropagationTests {
    @Test("meeting summary sends additional headers to Anthropic-compatible endpoint")
    func summaryHeaders() async throws {
        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "static-key")
            if request.httpMethod == "GET" { return .init(data: Data(#"{"max_tokens":64000}"#.utf8)) }
            return .init(data: Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        var config = customConfig(format: .anthropic)
        config.customLLMAPIKey = "static-key"
        let result = try await MeetingSummaryClient.summarize(
            transcript: "Test transcript",
            meetingTitle: "Test",
            config: config
        )
        #expect(result == "OK")
    }

    @Test("app and CLI summaries omit default caps and honor explicit limits", arguments: ["custom_llm", "custom_anthropic", "lmstudio", "ollama"], [0, 5_000])
    func summaryOutputLimits(backend: String, cap: Int) async throws {
        let limit: Int? = cap == 0 ? nil : cap
        CustomLLMHeaderPropagationURLProtocol.install { request in
            if request.httpMethod == "GET" { return .init(data: Data(#"{"max_tokens":96000}"#.utf8)) }
            let body = try? JSONSerialization.jsonObject(with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)) as? [String: Any]
            if backend == "custom_anthropic" {
                #expect(body?["max_tokens"] as? Int == (limit ?? 96_000))
                #expect(body?["stream"] as? Bool == (limit == nil))
                let stream = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Complete notes\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
                return .init(data: limit == nil ? Data(stream.utf8) : Data(#"{"content":[{"type":"text","text":"Complete notes"}]}"#.utf8))
            }
            if backend == "ollama" {
                #expect((body?["options"] as? [String: Int])?["num_predict"] == (limit ?? -1))
                return .init(data: Data(#"{"message":{"content":"Complete notes"}}"#.utf8))
            }
            #expect(body?["max_tokens"] as? Int == limit)
            #expect(body?["max_completion_tokens"] == nil)
            return .init(data: Data(#"{"choices":[{"message":{"content":"Complete notes"}}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }
        var config = customConfig()
        config.meetingSummaryBackend = backend == "custom_anthropic" ? "custom_llm" : backend
        if backend == "custom_anthropic" {
            config.customLLMFormat = "anthropic"
            config.customLLMAPIKey = "test-key"
        }
        config.meetingSummaryMaxOutputTokens = limit
        config.lmStudioURL = config.customLLMURL
        config.lmStudioModel = "local-model"
        config.ollamaURL = "https://headers.example.test"
        let appNotes = try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config)
        let cliConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(config))
        #expect(cliConfig.meetingSummaryMaxOutputTokens == limit)
        let cliNotes = try await CLISummaryClient.summarize(transcript: "Transcript", title: "Test", config: cliConfig)
        #expect(appNotes == "Complete notes")
        #expect(cliNotes == appNotes)
    }

    @Test("hosted OpenAI and OpenRouter app and CLI requests honor optional output limits",
          arguments: ["openai", "openrouter"], [0, 5_000])
    func hostedSummaryOutputLimits(backend: String, cap: Int) async throws {
        let limit: Int? = cap == 0 ? nil : cap
        var requests = 0
        CustomLLMHeaderPropagationURLProtocol.install { request in
            requests += 1
            #expect(request.httpMethod == "POST")
            let body = try? JSONSerialization.jsonObject(with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)) as? [String: Any]
            #expect(body?["max_completion_tokens"] == nil)
            if backend == "openai" {
                #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
                #expect(body?["model"] as? String == "gpt-6.1-sol")
                #expect(body?["input"] != nil)
                #expect(body?["max_output_tokens"] as? Int == limit)
                #expect(body?["max_tokens"] == nil)
                return .init(data: Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Complete notes"}]}]}"#.utf8))
            }
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
            #expect(body?["model"] as? String == "anthropic/claude-sonnet-5.5")
            #expect(body?["messages"] != nil)
            #expect(body?["max_tokens"] as? Int == limit)
            #expect(body?["max_output_tokens"] == nil)
            return .init(data: Data(#"{"choices":[{"message":{"content":"Complete notes"}}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }
        var config = AppConfig()
        config.meetingSummaryBackend = backend
        config.openAIAPIKey = "test-openai-key"
        config.openAIModel = "gpt-6.1-sol"
        config.openRouterAPIKey = "test-openrouter-key"
        config.openRouterModel = "anthropic/claude-sonnet-5.5"
        config.meetingSummaryMaxOutputTokens = limit
        #expect(try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config) == "Complete notes")
        #expect(requests == 1)
        let cliConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(config))
        #expect(try await CLISummaryClient.summarize(transcript: "Transcript", title: "Test", config: cliConfig) == "Complete notes")
        #expect(requests == 2)
    }

    @Test("Anthropic app and CLI requests stream above the SDK threshold",
          arguments: [21_333, 21_334, 32_000])
    func anthropicStreamingThreshold(cap: Int) async throws {
        var requests = 0
        CustomLLMHeaderPropagationURLProtocol.install { request in
            requests += 1
            #expect(request.httpMethod == "POST")
            let body = try? JSONSerialization.jsonObject(with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)) as? [String: Any]
            #expect(body?["max_tokens"] as? Int == cap)
            #expect(body?["stream"] as? Bool == (cap > 21_333))
            return .init(data: Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"Complete notes"}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }
        var config = customConfig(format: .anthropic)
        config.customLLMAPIKey = "test-key"
        config.meetingSummaryMaxOutputTokens = cap
        #expect(try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config) == "Complete notes")
        let cliConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(config))
        #expect(try await CLISummaryClient.summarize(transcript: "Transcript", title: "Test", config: cliConfig) == "Complete notes")
        #expect(requests == 2)
    }

    @Test("Anthropic app and CLI reject truncated summaries and allow a fresh manual retry",
          arguments: [false, true], ["max_tokens", "model_context_window_exceeded"])
    func truncatedAnthropicSummaries(stream: Bool, stopReason: String) async throws {
        var truncated = true
        var requests = 0
        CustomLLMHeaderPropagationURLProtocol.install { _ in
            requests += 1
            let reason = truncated ? stopReason : "end_turn"
            let notes = truncated ? "Partial notes" : "Complete notes"
            let response = stream
                ? "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\(notes)\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
                : #"{"stop_reason":"\#(reason)","content":[{"type":"text","text":"\#(notes)"}]}"#
            return .init(data: Data(response.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }
        var config = customConfig(format: .anthropic)
        config.customLLMAPIKey = "test-key"
        config.meetingSummaryMaxOutputTokens = stream ? 32_000 : 5_000
        config.meetingSummaryRetryCount = 3
        do {
            _ = try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config)
            Issue.record("App must not return partial notes as a completed summary")
        } catch {
            if stopReason == "model_context_window_exceeded" {
                #expect(error.localizedDescription.contains("context window before finishing"))
                #expect(error.localizedDescription.contains("shorten the transcript"))
            } else {
                #expect(error.localizedDescription.contains("output token limit before finishing"))
                #expect(error.localizedDescription.contains("Advanced"))
            }
            #expect(!error.localizedDescription.contains("could not be reached"))
        }
        #expect(requests == 1)
        let cliConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(config))
        await #expect(throws: MeetingSummaryOutputPolicy.OutputError.self) {
            try await CLISummaryClient.summarize(transcript: "Transcript", title: "Test", config: cliConfig)
        }
        #expect(requests == 2)

        // A new user-triggered request is independent of the failed automatic retry loop.
        truncated = false
        config.meetingSummaryMaxOutputTokens = 64_000
        config.customLLMModel = "larger-model"
        #expect(try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config) == "Complete notes")
        let retryConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(config))
        #expect(try await CLISummaryClient.summarize(transcript: "Transcript", title: "Test", config: retryConfig) == "Complete notes")
        #expect(requests == 4)
    }

    @Test("streamed summary errors preserve automatic and manual retry behavior",
          arguments: ["authentication_error", "overloaded_error"])
    func streamedSummaryErrorRetries(type: String) async throws {
        var requests = 0
        CustomLLMHeaderPropagationURLProtocol.install { _ in
            requests += 1
            if requests == 1 {
                return .init(data: Data("data: {\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"reflected secret\"}}\n\n".utf8))
            }
            let complete = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Complete notes\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            return .init(data: Data(complete.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }
        var config = customConfig(format: .anthropic)
        config.customLLMAPIKey = "test-key"
        config.meetingSummaryMaxOutputTokens = 64_000
        config.meetingSummaryRetryCount = 3
        do {
            let notes = try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config)
            #expect(type == "overloaded_error")
            #expect(notes == "Complete notes")
        } catch {
            #expect(type == "authentication_error")
            #expect(!error.localizedDescription.contains("reflected secret"))
        }
        #expect(requests == (type == "overloaded_error" ? 2 : 1))
        // Explicit user retries remain possible even after a permanent provider failure.
        #expect(try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config) == "Complete notes")
        #expect(requests == (type == "overloaded_error" ? 3 : 2))
    }

    @Test("generated title sends additional headers")
    func titleHeaders() async {
        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            let body = try? JSONSerialization.jsonObject(
                with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)
            ) as? [String: Any]
            #expect(body?["max_tokens"] as? Int == 100)
            #expect(body?["max_completion_tokens"] == nil)
            #expect(body?["reasoning_effort"] == nil)
            return .init(data: Data(#"{"choices":[{"message":{"content":"Test title"}}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Test transcript",
            config: customConfig()
        )
        #expect(title == "Test title")
    }

    @Test("cleanup and Quill shared path sends additional headers")
    func cleanupHeaders() async throws {
        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            let body = try? JSONSerialization.jsonObject(
                with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)
            ) as? [String: Any]
            #expect(body?["max_tokens"] as? Int == 1000)
            #expect(body?["max_completion_tokens"] == nil)
            #expect(body?["reasoning_effort"] == nil)
            return .init(data: Data(#"{"choices":[{"message":{"content":"Cleaned text"}}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        let result = try await TranscriptCleanupClient.generate(
            systemPrompt: "Clean the text.",
            userPrompt: "raw text",
            backend: .hosted(.customLLM),
            model: "custom-model",
            config: customConfig()
        )
        #expect(result == "Cleaned text")
    }

    @Test("CLI summary normalizes keys and sends headers in both API formats",
          arguments: ["openai", "anthropic"], ["environment-key", " \t environment-key \n", " \t\n"])
    func cliHeaders(format: String, environmentKey: String) async throws {
        let previousAPIKey = getenv("CUSTOM_LLM_API_KEY").map { String(cString: $0) }
        setenv("CUSTOM_LLM_API_KEY", environmentKey, 1)
        defer {
            if let previousAPIKey {
                setenv("CUSTOM_LLM_API_KEY", previousAPIKey, 1)
            } else {
                unsetenv("CUSTOM_LLM_API_KEY")
            }
        }

        let expectedKey = environmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "static-key" : "environment-key"
        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            if format == "anthropic" {
                #expect(request.value(forHTTPHeaderField: "x-api-key") == expectedKey)
            } else {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedKey)")
            }
            if request.httpMethod == "GET" { return .init(data: Data(#"{"max_tokens":64000}"#.utf8)) }
            let body = try? JSONSerialization.jsonObject(
                with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)
            ) as? [String: Any]
            #expect(body?["max_tokens"] as? Int == (format == "anthropic" ? 64_000 : nil))
            #expect(body?["max_completion_tokens"] == nil)
            let response = format == "anthropic"
                ? #"{"content":[{"type":"text","text":"CLI notes"}]}"#
                : #"{"choices":[{"message":{"content":"CLI notes"}}]}"#
            return .init(data: Data(response.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        var config = CLISummaryConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMURL = "https://headers.example.test/v1"
        config.customLLMAPIKey = " \t static-key \n"
        config.customLLMFormat = format
        config.customLLMModel = "custom-model"
        config.customLLMHeaders = customHeaders()

        let result = try await CLISummaryClient.summarize(
            transcript: "Test transcript",
            title: "Test",
            config: config
        )
        #expect(result == "CLI notes")
    }

    @Test("Custom LLM errors do not reflect credentials or additional headers")
    func reflectedSecretsAreRedacted() async {
        let previousAPIKey = getenv("CUSTOM_LLM_API_KEY").map { String(cString: $0) }
        unsetenv("CUSTOM_LLM_API_KEY")
        defer {
            if let previousAPIKey {
                setenv("CUSTOM_LLM_API_KEY", previousAPIKey, 1)
            }
        }

        let apiKey = "reflected-api-key"
        let headerValue = "reflected-header-value"
        let responseBody = Data(
            #"{"error":{"message":"reflected-error-body reflected-api-key reflected-header-value"}}"#.utf8
        )
        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
            let body = try? JSONSerialization.jsonObject(
                with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)
            ) as? [String: Any]
            #expect(body?["max_completion_tokens"] == nil)
            #expect(body?["reasoning_effort"] == nil)
            return .init(statusCode: 401, data: responseBody)
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        var config = customConfig()
        config.customLLMAPIKeyCommand = "printf \(apiKey)"
        config.customLLMHeaders = [
            CustomLLMRequestHeader(name: "source", value: headerValue),
        ]
        config.meetingSummaryRetryCount = 0

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "Test",
                config: config
            )
            Issue.record("Expected Custom LLM summary to fail")
        } catch {
            expectRedacted(error.localizedDescription, apiKey: apiKey, headerValue: headerValue)
            #expect(error.localizedDescription.contains("401"))
        }

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Test transcript",
            config: config
        )
        #expect(title == nil)

        do {
            _ = try await TranscriptCleanupClient.generate(
                systemPrompt: "Clean the text.",
                userPrompt: "raw text",
                backend: .hosted(.customLLM),
                model: "custom-model",
                config: config
            )
            Issue.record("Expected Custom LLM cleanup to fail")
        } catch {
            expectRedacted(error.localizedDescription, apiKey: apiKey, headerValue: headerValue)
            #expect(error.localizedDescription.contains("401"))
        }

        var cliConfig = CLISummaryConfig()
        cliConfig.meetingSummaryBackend = "custom_llm"
        cliConfig.customLLMURL = "https://headers.example.test/v1"
        cliConfig.customLLMAPIKey = apiKey
        cliConfig.customLLMModel = "custom-model"
        cliConfig.customLLMHeaders = config.customLLMHeaders

        do {
            _ = try await CLISummaryClient.summarize(
                transcript: "Test transcript",
                title: "Test",
                config: cliConfig
            )
            Issue.record("Expected Custom LLM CLI summary to fail")
        } catch {
            expectRedacted(error.localizedDescription, apiKey: apiKey, headerValue: headerValue)
            #expect(error.localizedDescription.contains("401"))
        }
    }

    private func expectRedacted(_ message: String, apiKey: String, headerValue: String) {
        #expect(!message.contains("reflected-error-body"))
        #expect(!message.contains(apiKey))
        #expect(!message.contains(headerValue))
    }

    private func customConfig(format: CustomLLMFormat = .openAI) -> AppConfig {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.customLLM.backend
        config.customLLMURL = "https://headers.example.test/v1"
        config.customLLMModel = "custom-model"
        config.customLLMFormat = format.rawValue
        config.customLLMHeaders = customHeaders()
        return config
    }

    private func customHeaders() -> [CustomLLMRequestHeader] {
        [
            CustomLLMRequestHeader(name: "source", value: "muesli"),
            CustomLLMRequestHeader(name: "org-id", value: "2"),
        ]
    }
}
