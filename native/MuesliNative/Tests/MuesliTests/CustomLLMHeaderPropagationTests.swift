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
        request.url?.host == "headers.example.test"
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

    @Test("CLI summary sends additional headers and prefers its environment key")
    func cliHeaders() async throws {
        let previousAPIKey = getenv("CUSTOM_LLM_API_KEY").map { String(cString: $0) }
        setenv("CUSTOM_LLM_API_KEY", "environment-key", 1)
        defer {
            if let previousAPIKey {
                setenv("CUSTOM_LLM_API_KEY", previousAPIKey, 1)
            } else {
                unsetenv("CUSTOM_LLM_API_KEY")
            }
        }

        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer environment-key")
            let body = try? JSONSerialization.jsonObject(
                with: CustomLLMHeaderPropagationURLProtocol.bodyData(for: request)
            ) as? [String: Any]
            #expect(body?["max_tokens"] as? Int == 2500)
            #expect(body?["max_completion_tokens"] == nil)
            return .init(data: Data(#"{"choices":[{"message":{"content":"CLI notes"}}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        var config = CLISummaryConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMURL = "https://headers.example.test/v1"
        config.customLLMAPIKey = "static-key"
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
            #expect(body?["max_tokens"] as? Int != nil)
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
