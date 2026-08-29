import Foundation

struct HostedDictationResult: Equatable, Sendable {
    let text: String
    let backend: String
}

protocol HostedDictationSession: AnyObject {
    var acceptsLiveAudio: Bool { get }
    func append(_ samples: [Float])
    func finish(recordedWAVURL: URL) async throws -> HostedDictationResult
    func cancel()
}

final class OpenAIHostedDictationSession: HostedDictationSession {
    private let stream: OpenAIRealtimeDictationStream

    let acceptsLiveAudio = true

    init(configuration: OpenAIDictationConfiguration) {
        stream = OpenAIRealtimeDictationStream(configuration: configuration)
    }

    func append(_ samples: [Float]) {
        stream.append(samples)
    }

    func finish(recordedWAVURL _: URL) async throws -> HostedDictationResult {
        HostedDictationResult(text: try await stream.finish(), backend: "openai-realtime")
    }

    func cancel() {
        stream.cancel()
    }
}

final class OpenRouterHostedDictationSession: HostedDictationSession, @unchecked Sendable {
    private let configuration: OpenRouterDictationConfiguration
    private let client: OpenRouterTranscriptionClient
    private let lock = NSLock()
    private var task: Task<OpenRouterTranscriptionResult, Error>?
    private var cancelled = false

    let acceptsLiveAudio = false

    init(
        configuration: OpenRouterDictationConfiguration,
        client: OpenRouterTranscriptionClient = OpenRouterTranscriptionClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    func append(_: [Float]) {}

    func finish(recordedWAVURL: URL) async throws -> HostedDictationResult {
        let task = Task { try await client.transcribe(wavURL: recordedWAVURL, configuration: configuration) }
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() }
        }
        defer { lock.withLock { self.task = nil } }
        let result = try await task.value
        return HostedDictationResult(text: result.text, backend: "openrouter-stt")
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }
}

enum HostedDictationFallbackPolicy {
    static func shouldFallback(
        after error: Error,
        taskIsCancelled: Bool = false,
        isCurrentSession: Bool = true
    ) -> Bool {
        guard !taskIsCancelled, isCurrentSession else { return false }
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }
}

enum HostedDictationActivationPolicy {
    static func blockingMessage(
        provider: DictationProvider,
        openAIAPIKey: String,
        openRouterAPIKey: String,
        openRouterModel: String
    ) -> String? {
        switch provider {
        case .local:
            return nil
        case .openAI:
            return openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenAI API key not configured. Add one in Settings → Dictation."
                : nil
        case .openRouter:
            if openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenRouter is not connected. Connect it in Settings → Dictation."
            }
            return OpenRouterTranscriptionClient.normalizedModel(openRouterModel).isEmpty
                ? "Choose an OpenRouter transcription model in Settings → Dictation."
                : nil
        }
    }
}
