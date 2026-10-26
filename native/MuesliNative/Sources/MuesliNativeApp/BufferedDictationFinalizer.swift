import AVFoundation
import Foundation

/// Recognition reuse is independent of whether the editor accepted live text.
/// All output still goes through the original target lease and cleanup pipeline.
@MainActor
enum BufferedDictationFinalizer {
    static func recordedSampleCount(at url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate == 16_000,
              file.fileFormat.channelCount == 1,
              file.length > 0, file.length <= Int64(Int.max) else { return nil }
        return Int(file.length)
    }

    static func transcribe(
        session: BufferedTranscriptionSession?,
        recordedSampleCount: Int?,
        drainTimeout: Duration = .seconds(10),
        onDecision: (String) -> Void = { _ in },
        reuse: (String) async throws -> SpeechTranscriptionResult,
        fallback: () async throws -> SpeechTranscriptionResult
    ) async throws -> SpeechTranscriptionResult {
        defer { session?.cancel() }
        try Task.checkCancellation()
        guard let session else { return try await fallback() }
        guard let recordedSampleCount, recordedSampleCount > 0,
              session.diagnostics.receivedSamples == recordedSampleCount else {
            session.cancel()
            onDecision("fallback:recording_coverage_mismatch:recorded=\(recordedSampleCount ?? -1):streamed=\(session.diagnostics.receivedSamples)")
            try Task.checkCancellation()
            return try await fallback()
        }
        if let reason = session.knownReuseFallbackReason {
            session.cancel()
            onDecision("fallback:\(reason.rawValue):committed_evidence \(session.reuseDiagnostics)")
            try Task.checkCancellation()
            return try await fallback()
        }
        var timedOut = false
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: drainTimeout) } catch { return }
            timedOut = true
            session.cancel()
        }
        defer { deadline.cancel() }
        let result = await session.finishForReuse()
        deadline.cancel()
        try Task.checkCancellation()
        guard result.canReuse,
              result.receivedSamples == recordedSampleCount,
              result.decodedThroughSample == recordedSampleCount else {
            if timedOut { onDecision("fallback:tail_drain_timeout") }
            onDecision("fallback:\(result.fallbackReason.map { String(describing: $0) } ?? "incomplete_coverage") \(result.diagnostics)")
            try Task.checkCancellation()
            return try await fallback()
        }
        onDecision("reuse \(result.diagnostics)")
        // If cleanup fails/cancels, propagate normally; do not run ASR and cleanup
        // again as though the accepted recognition had failed.
        try Task.checkCancellation()
        return try await reuse(result.text)
    }
}
