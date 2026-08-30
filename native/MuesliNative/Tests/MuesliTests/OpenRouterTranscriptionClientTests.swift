import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("OpenRouter dictation")
struct OpenRouterTranscriptionClientTests {
    @Test("request contains the documented endpoint, credential, headers, model, and raw WAV")
    func requestShape() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let request = try OpenRouterTranscriptionClient.request(
            audioData: audio,
            configuration: OpenRouterDictationConfiguration(
                apiKey: "  sk-or-test  ",
                model: "  provider/transcribe  "
            )
        )

        #expect(request.url == OpenRouterTranscriptionClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 65)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == AppIdentity.displayName)

        let httpBody = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
        )
        #expect(body["model"] as? String == "provider/transcribe")
        let inputAudio = try #require(body["input_audio"] as? [String: Any])
        #expect(inputAudio["format"] as? String == "wav")
        #expect(inputAudio["data"] as? String == audio.base64EncodedString())
    }

    @Test("request requires both a credential and an explicit model")
    func requiredConfiguration() {
        #expect(throws: OpenRouterTranscriptionError.self) {
            try OpenRouterTranscriptionClient.request(
                audioData: Data(),
                configuration: .init(apiKey: "", model: "provider/model")
            )
        }
        #expect(throws: OpenRouterTranscriptionError.self) {
            try OpenRouterTranscriptionClient.request(
                audioData: Data(),
                configuration: .init(apiKey: "key", model: "  ")
            )
        }
    }

    @Test("successful response decodes final text and generation ID")
    func success() async throws {
        let wavURL = try temporaryWAV(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let client = OpenRouterTranscriptionClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Generation-Id": "gen-123"]
            )!
            return (Data("{\"text\":\"  hello world  \"}".utf8), response)
        }

        let result = try await client.transcribe(
            wavURL: wavURL,
            configuration: .init(apiKey: "key", model: "provider/model")
        )
        #expect(result.text == "hello world")
        #expect(result.generationID == "gen-123")
    }

    @Test("hosted session snapshots the model before transcription starts")
    func sessionSnapshot() async throws {
        let wavURL = try temporaryWAV(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let recorder = OpenRouterRequestRecorder()
        let client = OpenRouterTranscriptionClient { request in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"text\":\"snapshot\"}".utf8), response)
        }
        var configuration = OpenRouterDictationConfiguration(apiKey: "old-key", model: "old/model")
        let session = OpenRouterHostedDictationSession(configuration: configuration, client: client)
        configuration = OpenRouterDictationConfiguration(apiKey: "new-key", model: "new/model")

        _ = try await session.finish(recordedWAVURL: wavURL)
        let recordedRequest = await recorder.request
        let request = try #require(recordedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-key")
        let requestBody = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        #expect(body["model"] as? String == "old/model")
        #expect(configuration.model == "new/model")
    }

    @Test("empty transcripts fail instead of being treated as successful dictation")
    func emptyTranscript() async throws {
        let wavURL = try temporaryWAV(Data([1]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let client = OpenRouterTranscriptionClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"text\":\"  \"}".utf8), response)
        }

        do {
            _ = try await client.transcribe(
                wavURL: wavURL,
                configuration: .init(apiKey: "key", model: "provider/model")
            )
            Issue.record("Expected an empty-transcript error")
        } catch OpenRouterTranscriptionError.emptyTranscript {
            // Expected.
        }
    }

    @Test("provider errors are sanitized before display")
    func sanitizedProviderError() async throws {
        let wavURL = try temporaryWAV(Data([1]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let client = OpenRouterTranscriptionClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"error\":{\"message\":\"rate\\nlimit\\tplease retry\"}}".utf8), response)
        }

        do {
            _ = try await client.transcribe(
                wavURL: wavURL,
                configuration: .init(apiKey: "key", model: "provider/model")
            )
            Issue.record("Expected an HTTP error")
        } catch OpenRouterTranscriptionError.server(let code, let message) {
            #expect(code == 429)
            #expect(message == "rate limit please retry")
        }
    }

    @Test("cancellation remains cancellation and does not qualify for fallback")
    func cancellation() async throws {
        let wavURL = try temporaryWAV(Data([1]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let client = OpenRouterTranscriptionClient { _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let task = Task {
            try await client.transcribe(
                wavURL: wavURL,
                configuration: .init(apiKey: "key", model: "provider/model")
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!HostedDictationFallbackPolicy.shouldFallback(after: CancellationError()))
            #expect(HostedDictationFallbackPolicy.shouldFallback(after: URLError(.timedOut)))
        }
    }

    @Test("a finalizing hosted session can still cancel its in-flight upload")
    func finalizingSessionCancellation() async throws {
        let wavURL = try temporaryWAV(Data([1]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let probe = OpenRouterCancellationProbe()
        let client = OpenRouterTranscriptionClient { _ in
            await probe.markStarted()
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let session = OpenRouterHostedDictationSession(
            configuration: .init(apiKey: "key", model: "provider/model"),
            client: client
        )
        let task = Task { try await session.finish(recordedWAVURL: wavURL) }

        await probe.waitUntilStarted()
        session.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("all non-cancellation hosted failures qualify for local fallback")
    func fallbackPolicy() {
        #expect(HostedDictationFallbackPolicy.shouldFallback(
            after: OpenRouterTranscriptionError.server(statusCode: 429, message: "rate limited")
        ))
        #expect(HostedDictationFallbackPolicy.shouldFallback(
            after: OpenRouterTranscriptionError.server(statusCode: 404, message: "unknown model")
        ))
        #expect(HostedDictationFallbackPolicy.shouldFallback(after: URLError(.timedOut)))
        #expect(HostedDictationFallbackPolicy.shouldFallback(after: URLError(.notConnectedToInternet)))
        #expect(!HostedDictationFallbackPolicy.shouldFallback(after: URLError(.cancelled)))
    }

    @Test("cancelled or stale hosted work cannot start local fallback")
    func staleCompletionDoesNotFallback() {
        let lateFailure = URLError(.timedOut)

        #expect(!HostedDictationFallbackPolicy.shouldFallback(
            after: lateFailure,
            taskIsCancelled: true,
            isCurrentSession: true
        ))
        #expect(!HostedDictationFallbackPolicy.shouldFallback(
            after: lateFailure,
            taskIsCancelled: false,
            isCurrentSession: false
        ))
    }

    @Test("catalog scopes use separate endpoint queries")
    func catalogScopes() {
        #expect(
            OpenRouterModelCatalogClient.request(.text).url?.query == "output_modalities=text"
        )
        #expect(
            OpenRouterModelCatalogClient.request(.transcription).url?.query
                == "output_modalities=transcription"
        )
    }

    @Test("malformed catalog responses fail without inventing models")
    func malformedCatalog() async {
        let client = OpenRouterModelCatalogClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{not-json".utf8), response)
        }
        await #expect(throws: DecodingError.self) {
            _ = try await client.load(.transcription)
        }
    }

    @Test("transport timeouts remain sanitized network errors")
    func timeout() async throws {
        let wavURL = try temporaryWAV(Data([1]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let client = OpenRouterTranscriptionClient { _ in throw URLError(.timedOut) }

        do {
            _ = try await client.transcribe(
                wavURL: wavURL,
                configuration: .init(apiKey: "key", model: "provider/model")
            )
            Issue.record("Expected a network error")
        } catch OpenRouterTranscriptionError.network(let underlying) {
            #expect((underlying as? URLError)?.code == .timedOut)
        }
    }

    @Test("transcription catalog filters, sorts, and retains custom selections")
    func catalogFilteringAndCustomRetention() throws {
        let data = Data("""
        {"data":[
          {"id":"z/model","name":"Zulu","pricing":{},"architecture":{"output_modalities":["transcription"]}},
          {"id":"a/model","name":"Alpha","pricing":{},"architecture":{"output_modalities":["text","transcription"]}},
          {"id":"text/model","name":"Text","pricing":{},"architecture":{"output_modalities":["text"]}}
        ]}
        """.utf8)
        let catalog = try JSONDecoder().decode(OpenRouterModelCatalog.self, from: data)
        let presets = OpenRouterModelCatalogFilter.transcriptionPresets(from: catalog.data)
        #expect(presets.map(\.id) == ["a/model", "z/model"])

        let retained = OpenRouterModelSelection.presetsIncludingConfiguredModel(
            presets,
            configuredModel: "custom/asr"
        )
        #expect(retained.map(\.id) == ["a/model", "z/model", "custom/asr"])
        #expect(retained.last?.label == "Custom: custom/asr")
        #expect(
            OpenRouterModelSelection.presetsIncludingConfiguredModel(
                presets,
                configuredModel: "a/model"
            ).count == presets.count
        )
    }

    @Test("activation requires OpenRouter authentication and an explicit model")
    func activationPolicy() {
        #expect(HostedDictationActivationPolicy.blockingMessage(
            provider: .local,
            openAIAPIKey: "",
            openRouterAPIKey: "",
            openRouterModel: ""
        ) == nil)
        #expect(HostedDictationActivationPolicy.blockingMessage(
            provider: .openRouter,
            openAIAPIKey: "",
            openRouterAPIKey: "",
            openRouterModel: "provider/model"
        )?.contains("not connected") == true)
        #expect(HostedDictationActivationPolicy.blockingMessage(
            provider: .openRouter,
            openAIAPIKey: "",
            openRouterAPIKey: "key",
            openRouterModel: ""
        )?.contains("Choose") == true)
        #expect(HostedDictationActivationPolicy.blockingMessage(
            provider: .openRouter,
            openAIAPIKey: "",
            openRouterAPIKey: "key",
            openRouterModel: "provider/model"
        ) == nil)
    }

    @Test("status menu selection changes provider and model atomically")
    func atomicStatusMenuSelection() {
        var config = AppConfig()
        OpenRouterDictationModelSelection.applyStatusMenuSelection("  provider/model  ", to: &config)
        #expect(config.resolvedDictationProvider == .openRouter)
        #expect(config.openRouterDictationModel == "provider/model")
    }

    private func temporaryWAV(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-openrouter-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}

private actor OpenRouterRequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

private actor OpenRouterCancellationProbe {
    private var hasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        hasStarted = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
