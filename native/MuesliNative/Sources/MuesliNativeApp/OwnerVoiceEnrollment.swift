import Foundation

struct OwnerVoiceWindow: Sendable {
    let embedding: [Float]
    let speechSeconds: Double
    let hasOverlap: Bool
}

protocol OwnerVoiceExtracting: Sendable {
    func extract(samples: [Float]) async throws -> OwnerVoiceWindow
}

enum OwnerVoiceEnrollmentError: LocalizedError {
    case invalidWindow, insufficientSpeech, unavailable, invalidEmbedding
    var errorDescription: String? {
        switch self {
        case .invalidWindow: return "The voice sample could not be used. Please try again."
        case .insufficientSpeech: return "Not enough clear speech. Try again in a quiet room and speak for at least 20 seconds."
        case .unavailable: return "Voice enrollment is unavailable. Check microphone permission and try again after capture finishes."
        case .invalidEmbedding: return "The voice sample was inconsistent. Please try again with only your voice."
        }
    }
}

@MainActor
final class OwnerVoiceEnrollment {
    private let extractor: any OwnerVoiceExtracting
    private let modelIdentity: String
    private var generation = OwnerVoiceGeneration()
    private var token: UInt64?
    private var references: [[Float]] = []
    private(set) var acceptedSpeechSeconds: Double = 0
    private(set) var isRecording = false
    var pendingPublicationIsValid: Bool { token.map(generation.accepts) == true && isRecording }

    init(extractor: any OwnerVoiceExtracting, modelIdentity: String = "fixture") {
        self.extractor = extractor
        self.modelIdentity = modelIdentity
    }

    func begin() {
        token = generation.begin()
        references.removeAll()
        acceptedSpeechSeconds = 0
        isRecording = true
    }

    func cancelForCaptureStart() { cancel() }
    func cancel() {
        generation.invalidate()
        token = nil
        isRecording = false
        references.removeAll()
        acceptedSpeechSeconds = 0
    }

    func checkDeadline(elapsed: Double) throws {
        guard elapsed.isFinite, elapsed < 60 else { throw OwnerVoiceEnrollmentError.insufficientSpeech }
    }

    func accept(samples: [Float], elapsed: Double) async throws -> OwnerVoiceProfile? {
        guard let token, pendingPublicationIsValid else { throw CancellationError() }
        try checkDeadline(elapsed: elapsed)
        guard !samples.isEmpty, samples.count <= 160_000, samples.allSatisfy({ $0.isFinite }) else {
            throw OwnerVoiceEnrollmentError.invalidWindow
        }
        let rms = sqrt(samples.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(samples.count))
        let clipped = samples.filter { abs($0) >= 0.98 }.count
        guard rms >= 0.003, Double(clipped) / Double(samples.count) < 0.001 else { return nil }
        let window = try await extractor.extract(samples: samples)
        try Task.checkCancellation()
        guard generation.accepts(token), pendingPublicationIsValid else { throw CancellationError() }
        guard !window.hasOverlap, window.speechSeconds.isFinite,
              window.speechSeconds >= 2, window.speechSeconds <= Double(samples.count) / 16_000 else { return nil }
        guard let reference = try? OwnerVoiceProfile.normalized(window.embedding) else {
            throw OwnerVoiceEnrollmentError.invalidEmbedding
        }
        guard references.allSatisfy({ OwnerVoiceProfile.similarity($0, reference) >= 0.8 }) else { return nil }
        references.append(reference)
        acceptedSpeechSeconds += window.speechSeconds
        guard acceptedSpeechSeconds >= 20, references.count >= 2 else { return nil }
        return try OwnerVoiceProfile(modelIdentity: modelIdentity, references: references, acceptedSpeechSeconds: acceptedSpeechSeconds)
    }
}
