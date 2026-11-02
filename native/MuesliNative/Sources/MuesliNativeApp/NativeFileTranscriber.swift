import FluidAudio
import Foundation
import MuesliCore

/// File-transcription models whose implementations live in the app library.
/// Stable command-line names are separate from provider repository identifiers.
public enum NativeFileTranscriptionModel: String, CaseIterable, Sendable {
    case appleSpeech = "apple-speech"
    case medASR = "medasr"
    case cohere = "cohere-transcribe"
    case bodhanCore = "bodhan-core"
    case bodhanFlex = "bodhan-flex"
    case bodhanCoreInt8 = "bodhan-core-int8"
    case bodhanFlexInt8 = "bodhan-flex-int8"
    case gemma4E2B = "gemma4-e2b"
    case gemma4E4B = "gemma4-e4b"

    var backend: BackendOption {
        switch self {
        case .appleSpeech: .appleSpeechAnalyzer
        case .medASR: .medASR
        case .cohere: .cohereTranscribe
        case .bodhanCore: .bodhanCore
        case .bodhanFlex: .bodhanFlex
        case .bodhanCoreInt8: .bodhanCoreInt8
        case .bodhanFlexInt8: .bodhanFlexInt8
        case .gemma4E2B: .gemma4E2BLiteRT
        case .gemma4E4B: .gemma4E4BLiteRT
        }
    }

    public var modelID: String { backend.model }

    public func unavailabilityReason(
        currentOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String? {
        backend.incompatibilityReason(currentOSVersion: currentOSVersion)
    }
}

/// Availability failures are distinct from inference, download and cancellation
/// errors so headless clients can provide actionable platform guidance.
public enum NativeFileTranscriptionError: LocalizedError, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self { case .unavailable(let reason): reason }
    }
}

/// Headless access to the app's existing inference runtimes. This does not start
/// the app, load user settings, or prepare optional meeting/cleanup models.
public enum NativeFileTranscriber {
    public static func transcribe(
        wavURL: URL,
        model: NativeFileTranscriptionModel,
        progress: @escaping (String) -> Void,
        medASRLicense: MedASRLicense = .shared
    ) async throws -> String {
        try Task.checkCancellation()
        if let reason = model.unavailabilityReason() {
            throw NativeFileTranscriptionError.unavailable(reason)
        }
        let report: (Double, String?) -> Void = { _, message in
            if let message { progress(message) }
        }
        switch model {
        case .appleSpeech:
            guard #available(macOS 26, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem else {
                throw NativeFileTranscriptionError.unavailable(AppleSpeechAnalyzerError.unavailable.localizedDescription)
            }
            let transcriber = AppleSpeechAnalyzerTranscriber.shared
            _ = try await transcriber.prepare(progress: report)
            try Task.checkCancellation()
            // SpeechAnalyzer streams the file directly; don't impose the small
            // replay windows required by fixed-context transcription engines.
            return try await transcriber.transcribe(wavURL: wavURL).text
        case .medASR:
            let transcriber = MedASRTranscriber(license: medASRLicense)
            do {
                try await transcriber.prepare(progress: report)
                let result = try await transcriber.transcribe(wavURL: wavURL)
                await transcriber.shutdown()
                return result.text
            } catch {
                await transcriber.shutdown()
                throw error
            }
        case .cohere:
            guard #available(macOS 15, *) else { throw unsupported(model) }
            return try await transcribeCohereRecording(wavURL: wavURL) { url in
                let transcriber = CohereTranscribeTranscriber()
                try await transcriber.prepare(progress: report)
                try Task.checkCancellation()
                return try await transcriber.transcribe(wavURL: url).text
            }
        case .bodhanCore, .bodhanFlex, .bodhanCoreInt8, .bodhanFlexInt8:
            guard #available(macOS 15, *) else { throw unsupported(model) }
            let transcriber = BodhanTranscriber()
            try await transcriber.prepare(modelID: model.modelID, progress: report)
            try Task.checkCancellation()
            return try await transcriber.transcribe(wavURL: wavURL, modelID: model.modelID).text
        case .gemma4E2B, .gemma4E4B:
            guard #available(macOS 15, *) else { throw unsupported(model) }
            let gemma = Gemma4LiteRTModel.resolved(model.modelID)
            try await Gemma4LiteRTTranscriber.shared.prepare(model: gemma, progress: report)
            try Task.checkCancellation()
            // The native encoder accepts at most 30 seconds. Reuse the app's
            // bounded recording replay and overlap reconciliation for long files.
            return try await transcribeGemmaRecording(wavURL: wavURL) { chunk in
                try await Gemma4LiteRTTranscriber.shared.transcribe(wavURL: chunk, model: gemma).text
            }
        }
    }

    /// Cohere can hallucinate on silence. Reject it before preparing the large
    /// ASR model; detector failures must not silently permit inference.
    static func transcribeCohereRecording(
        wavURL: URL,
        speechDetected: (URL) async throws -> Bool = containsCohereSpeech,
        infer: (URL) async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        let hasSpeech = try await speechDetected(wavURL)
        try Task.checkCancellation()
        guard hasSpeech else { return "" }
        return try await infer(wavURL)
    }

    private static func containsCohereSpeech(_ url: URL) async throws -> Bool {
        let vad = try await VadManager()
        // Reuse the bounded PCM reader so even long silent inputs don't need
        // to be loaded into a single in-memory sample array for this guard.
        let reader = try DiarizationPCMWindowReader(url: url)
        while let window = try reader.next() {
            if try await vad.process(window.samples).contains(where: { $0.probability > 0.5 }) {
                return true
            }
        }
        return false
    }

    /// Replay emits Float32 WAVs; Gemma's strict reader requires PCM16. Keep
    /// conversion bounded to one replay window and remove it on every exit path.
    static func transcribeGemmaRecording(
        wavURL: URL,
        infer: @escaping @Sendable (URL) async throws -> String
    ) async throws -> String {
        let result = try await MeetingRecordingTranscriber().transcribe(url: wavURL, infer: { chunk in
            let samples = try AudioConverter().resampleAudioFile(chunk)
            let pcmURL = try WavWriter.writeTemporaryWAV(samples: samples)
            defer { try? FileManager.default.removeItem(at: pcmURL) }
            try Task.checkCancellation()
            return SpeechTranscriptionResult(text: try await infer(pcmURL), segments: [])
        }, progress: { _, _ in })
        return result.text
    }

    private static func unsupported(_ model: NativeFileTranscriptionModel) -> NativeFileTranscriptionError {
        .unavailable("\(model.rawValue) requires macOS 15 or later.")
    }
}
