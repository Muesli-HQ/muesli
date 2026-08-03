import Foundation

/// Runtime configuration needed to transcribe a dictation with OpenAI.
struct OpenAIDictationConfiguration: Sendable {
    let apiKey: String
    let model: String
}

enum OpenAITranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidModel
    case emptyTranscript
    case server(statusCode: Int, message: String?)
    case network(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key is configured. Add one in Settings → Dictation → OpenAI."
        case .invalidModel:
            return "The OpenAI transcription model is not configured. Pick a model in Settings → Dictation → OpenAI."
        case .emptyTranscript:
            return "OpenAI returned an empty transcript."
        case .server(let statusCode, let message):
            if let message, !message.isEmpty {
                return "OpenAI transcription failed (\(statusCode)): \(message)"
            }
            return "OpenAI transcription failed with status \(statusCode)."
        case .network(let underlying):
            return "Could not reach OpenAI: \(underlying.localizedDescription)"
        }
    }
}

/// Thin client for OpenAI's audio transcriptions API
/// (`POST /v1/audio/transcriptions`). Deliberately self-contained so it can be
/// reused by any future OpenAI speech feature without touching the dictation
/// pipeline.
enum OpenAITranscriptionClient {
    static let transcriptionsURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    /// Model presets offered in Settings. Configurable so future OpenAI speech
    /// models can be adopted without code changes.
    static let modelPresets: [String] = [
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
        "whisper-1",
    ]

    static let defaultModel = "gpt-4o-mini-transcribe"

    static func normalizeModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// Transcribes a WAV/audio file and returns the plain transcript text.
    static func transcribe(
        audioURL: URL,
        configuration: OpenAIDictationConfiguration
    ) async throws -> String {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw OpenAITranscriptionError.missingAPIKey }
        let model = normalizeModel(configuration.model)
        guard !model.isEmpty else { throw OpenAITranscriptionError.invalidModel }

        let boundary = "muesli-boundary-\(UUID().uuidString)"
        var request = URLRequest(url: transcriptionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let filename = audioURL.lastPathComponent.isEmpty ? "audio.wav" : audioURL.lastPathComponent
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw OpenAITranscriptionError.network(underlying: error)
        }
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            filename: filename,
            fileData: audioData,
            model: model
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAITranscriptionError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.network(underlying: URLError(.badServerResponse))
        }

        guard (200..<300).contains(http.statusCode) else {
            throw OpenAITranscriptionError.server(
                statusCode: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenAITranscriptionError.emptyTranscript
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validates an API key by hitting the models endpoint. Used by the
    /// "Test connection" affordance in Settings.
    static func testConnection(apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAITranscriptionError.missingAPIKey }

        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAITranscriptionError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.network(underlying: URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAITranscriptionError.server(
                statusCode: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
    }

    static func makeMultipartBody(
        boundary: String,
        filename: String,
        fileData: Data,
        model: String
    ) -> Data {
        var body = Data()
        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", value: model)
        appendField("response_format", value: "json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func errorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let message = json["message"] as? String {
            return message
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return nil
    }
}
