import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI
@testable import MuesliNativeApp

private final class CustomLLMHeaderPropagationURLProtocol: URLProtocol {
    struct Response {
        let data: Data
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
            statusCode: 200,
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

    @Test("CLI summary sends additional headers")
    func cliHeaders() async throws {
        CustomLLMHeaderPropagationURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "source") == "muesli")
            #expect(request.value(forHTTPHeaderField: "org-id") == "2")
            return .init(data: Data(#"{"choices":[{"message":{"content":"CLI notes"}}]}"#.utf8))
        }
        defer { CustomLLMHeaderPropagationURLProtocol.uninstall() }

        var config = CLISummaryConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMURL = "https://headers.example.test/v1"
        config.customLLMModel = "custom-model"
        config.customLLMHeaders = customHeaders()

        let result = try await CLISummaryClient.summarize(
            transcript: "Test transcript",
            title: "Test",
            config: config
        )
        #expect(result == "CLI notes")
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
