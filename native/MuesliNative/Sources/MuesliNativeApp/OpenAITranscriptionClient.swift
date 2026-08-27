import Foundation

struct OpenAIDictationConfiguration: Sendable {
    let apiKey: String
    let model: String
}

enum OpenAITranscriptionError: LocalizedError, @unchecked Sendable {
    case missingAPIKey
    case emptyTranscript
    case timedOut
    case audioBackpressure
    case server(message: String)
    case network(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key is configured. Add one in Settings → Dictation."
        case .emptyTranscript:
            return "OpenAI returned an empty transcript."
        case .timedOut:
            return "OpenAI did not finish the transcript in time."
        case .audioBackpressure:
            return "The network could not keep up with microphone audio."
        case .server(let message):
            return "OpenAI transcription failed: \(message)"
        case .network(let underlying):
            return "Could not reach OpenAI: \(underlying.localizedDescription)"
        }
    }
}

enum OpenAIRealtimeProtocol {
    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    static func request(apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAITranscriptionError.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func sessionUpdate(model: String) throws -> String {
        let normalized = OpenAITranscriptionClient.normalizeModel(model)
        return try encode([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": normalized],
                        "turn_detection": NSNull(),
                    ] as [String: Any],
                ],
            ],
        ])
    }

    static func append(_ pcmData: Data) throws -> String {
        try encode([
            "type": "input_audio_buffer.append",
            "audio": pcmData.base64EncodedString(),
        ])
    }

    static let commit = #"{"type":"input_audio_buffer.commit"}"#

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw OpenAITranscriptionError.network(underlying: URLError(.cannotDecodeContentData))
        }
        return string
    }
}

/// Stateful 16 kHz Float32 -> 24 kHz signed PCM16 encoder. Keeping the last
/// source sample and fractional position avoids clicks or drift at callback
/// boundaries.
struct OpenAIRealtimePCMEncoder: Sendable {
    private var previousSample: Float?
    /// The next output position in thirds of a source sample. A 16 -> 24 kHz
    /// conversion advances by 2/3 per output, so integer phase arithmetic keeps
    /// callback boundaries bit-for-bit identical to one continuous buffer.
    private var nextSourcePositionThirds = 0

    mutating func encode(_ samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }
        var source = samples
        if let previousSample { source.insert(previousSample, at: 0) }
        var positionThirds = nextSourcePositionThirds
        var output = Data()
        output.reserveCapacity(Int(Double(samples.count) * 1.5 + 2) * 2)

        let endPositionThirds = (source.count - 1) * 3
        while positionThirds < endPositionThirds {
            let lower = positionThirds / 3
            let fraction = Float(positionThirds % 3) / 3
            let sample = source[lower] + (source[lower + 1] - source[lower]) * fraction
            let scaled = max(-1, min(1, sample)) * (sample < 0 ? 32_768 : 32_767)
            var pcm = Int16(scaled.rounded()).littleEndian
            withUnsafeBytes(of: &pcm) { output.append(contentsOf: $0) }
            positionThirds += 2
        }

        nextSourcePositionThirds = positionThirds - endPositionThirds
        previousSample = samples.last
        return output
    }
}

private struct OpenAIRealtimeServerEvent {
    let type: String
    let itemID: String?
    let transcript: String?
    let errorMessage: String?

    init(_ string: String) throws {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw OpenAITranscriptionError.network(underlying: URLError(.cannotParseResponse))
        }
        self.type = type
        itemID = json["item_id"] as? String
        transcript = (json["transcript"] as? String) ?? (json["delta"] as? String)
        if let error = json["error"] as? [String: Any] {
            errorMessage = (error["message"] as? String) ?? (error["code"] as? String)
        } else {
            errorMessage = nil
        }
    }
}

actor OpenAIRealtimeTranscriptionSession {
    private let configuration: OpenAIDictationConfiguration
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var finalTimeoutTask: Task<Void, Never>?
    private var isReady = false
    private var transcriptByItem: [String: String] = [:]
    private var completedItemIDs: [String] = []
    private var commitRequested = false
    private var terminalError: Error?

    init(configuration: OpenAIDictationConfiguration) {
        self.configuration = configuration
    }

    func start(timeout: Duration = .seconds(30)) async throws {
        let request = try OpenAIRealtimeProtocol.request(apiKey: configuration.apiKey)
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            socket.resume()
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutReady()
            }
        }
    }

    func append(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }
        if let terminalError { throw terminalError }
        guard let socket else {
            throw OpenAITranscriptionError.network(underlying: URLError(.notConnectedToInternet))
        }
        try await socket.send(.string(try OpenAIRealtimeProtocol.append(pcmData)))
    }

    func finish(timeout: Duration = .seconds(30)) async throws -> String {
        if let terminalError { throw terminalError }
        guard let socket else {
            throw OpenAITranscriptionError.network(underlying: URLError(.notConnectedToInternet))
        }
        commitRequested = true
        try await socket.send(.string(OpenAIRealtimeProtocol.commit))
        return try await waitForFinalTranscript(timeout: timeout)
    }

    func cancel() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        readyTimeoutTask?.cancel()
        finalTimeoutTask?.cancel()
        let error = CancellationError()
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        finalContinuation?.resume(throwing: error)
        finalContinuation = nil
    }

    private func waitForFinalTranscript(timeout: Duration) async throws -> String {
        if let terminalError { throw terminalError }
        if let transcript = resolvedTranscript() {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw OpenAITranscriptionError.emptyTranscript }
            return trimmed
        }
        return try await withCheckedThrowingContinuation { continuation in
            finalContinuation = continuation
            finalTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutFinal()
            }
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let string: String
                switch message {
                case .string(let value): string = value
                case .data(let data): string = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                try await handle(OpenAIRealtimeServerEvent(string))
            }
        } catch is CancellationError {
            return
        } catch {
            fail(OpenAITranscriptionError.network(underlying: error))
        }
    }

    private func handle(_ event: OpenAIRealtimeServerEvent) async throws {
        switch event.type {
        case "session.created":
            guard let socket else { return }
            try await socket.send(.string(try OpenAIRealtimeProtocol.sessionUpdate(model: configuration.model)))
        case "session.updated":
            isReady = true
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            readyContinuation?.resume()
            readyContinuation = nil
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = event.itemID, let delta = event.transcript else { return }
            transcriptByItem[itemID, default: ""] += delta
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = event.itemID else { return }
            if let transcript = event.transcript { transcriptByItem[itemID] = transcript }
            if !completedItemIDs.contains(itemID) { completedItemIDs.append(itemID) }
            resolveFinalIfPossible()
        case "conversation.item.input_audio_transcription.failed":
            fail(OpenAITranscriptionError.server(message: event.errorMessage ?? "Audio transcription failed"))
        case "error":
            fail(OpenAITranscriptionError.server(message: event.errorMessage ?? "Unknown server error"))
        default:
            break
        }
    }

    private func resolveFinalIfPossible() {
        guard commitRequested, let continuation = finalContinuation,
              let transcript = resolvedTranscript() else { return }
        finalContinuation = nil
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            continuation.resume(throwing: OpenAITranscriptionError.emptyTranscript)
        } else {
            continuation.resume(returning: trimmed)
        }
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func resolvedTranscript() -> String? {
        guard !completedItemIDs.isEmpty else { return nil }
        return completedItemIDs.compactMap { transcriptByItem[$0] }.joined(separator: " ")
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        readyTimeoutTask?.cancel()
        finalTimeoutTask?.cancel()
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        finalContinuation?.resume(throwing: error)
        finalContinuation = nil
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func timeoutReady() {
        guard !isReady else { return }
        fail(OpenAITranscriptionError.timedOut)
    }

    private func timeoutFinal() {
        guard finalContinuation != nil else { return }
        fail(OpenAITranscriptionError.timedOut)
    }
}

/// Synchronous producer facade for CoreAudio callbacks. AsyncStream preserves
/// callback ordering while WebSocket work stays off the audio thread.
final class OpenAIRealtimeDictationStream: @unchecked Sendable {
    private let session: OpenAIRealtimeTranscriptionSession
    private let continuation: AsyncStream<[Float]>.Continuation
    private let readyTask: Task<Void, Error>
    private let uploadTask: Task<Void, Error>
    private let lock = NSLock()
    private var overflowed = false

    init(configuration: OpenAIDictationConfiguration) {
        let session = OpenAIRealtimeTranscriptionSession(configuration: configuration)
        self.session = session
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = pair.continuation
        let readyTask = Task { try await session.start() }
        self.readyTask = readyTask
        uploadTask = Task {
            try await readyTask.value
            var encoder = OpenAIRealtimePCMEncoder()
            for await samples in pair.stream {
                try Task.checkCancellation()
                try await session.append(encoder.encode(samples))
            }
        }
    }

    func start() async throws { try await readyTask.value }

    func append(_ samples: [Float]) {
        if case .dropped(_) = continuation.yield(samples) {
            lock.withLock { overflowed = true }
        }
    }

    func finish() async throws -> String {
        continuation.finish()
        try await uploadTask.value
        guard !lock.withLock({ overflowed }) else { throw OpenAITranscriptionError.audioBackpressure }
        return try await session.finish()
    }

    func cancel() {
        continuation.finish()
        readyTask.cancel()
        uploadTask.cancel()
        Task { await session.cancel() }
    }
}

enum OpenAITranscriptionClient {
    static let modelPresets = ["gpt-live-transcribe", "gpt-transcribe"]
    static let defaultModel = "gpt-live-transcribe"

    static func normalizeModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    static func testConnection(configuration: OpenAIDictationConfiguration) async throws {
        let session = OpenAIRealtimeTranscriptionSession(configuration: configuration)
        try await session.start()
        await session.cancel()
    }
}
