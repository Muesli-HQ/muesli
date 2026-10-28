import Foundation

/// File-transcription models whose implementations live in the app library.
/// Stable command-line names are separate from provider repository identifiers.
public enum NativeFileTranscriptionModel: String, CaseIterable, Sendable {
    case appleSpeech = "apple-speech"
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

/// Headless access to the app's existing inference runtimes. This does not start
/// the app, load user settings, or prepare optional meeting/cleanup models.
public enum NativeFileTranscriber {
    public static func transcribe(
        wavURL: URL,
        model: NativeFileTranscriptionModel,
        progress: @escaping (String) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        if let reason = model.unavailabilityReason() {
            throw NSError(domain: "MuesliFileTranscription", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        let report: (Double, String?) -> Void = { _, message in
            if let message { progress(message) }
        }
        switch model {
        case .appleSpeech:
            guard #available(macOS 26, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem else {
                throw AppleSpeechAnalyzerError.unavailable
            }
            let transcriber = AppleSpeechAnalyzerTranscriber.shared
            _ = try await transcriber.prepare(progress: report)
            try Task.checkCancellation()
            // SpeechAnalyzer streams the file directly; don't impose the small
            // replay windows required by fixed-context transcription engines.
            return try await transcriber.transcribe(wavURL: wavURL).text
        case .cohere:
            guard #available(macOS 15, *) else { throw unsupported(model) }
            let transcriber = CohereTranscribeTranscriber()
            try await transcriber.prepare(progress: report)
            try Task.checkCancellation()
            return try await transcriber.transcribe(wavURL: wavURL).text
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
            let result = try await MeetingRecordingTranscriber().transcribe(url: wavURL, infer: { chunk in
                let result = try await Gemma4LiteRTTranscriber.shared.transcribe(wavURL: chunk, model: gemma)
                return SpeechTranscriptionResult(text: result.text, segments: [])
            }, progress: { _, _ in })
            return result.text
        }
    }

    private static func unsupported(_ model: NativeFileTranscriptionModel) -> NSError {
        NSError(domain: "MuesliFileTranscription", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(model.rawValue) requires macOS 15 or later."])
    }
}
