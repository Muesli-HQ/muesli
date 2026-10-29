import AVFoundation
import Foundation

/// Recognition reuse is independent of whether the editor accepted live text.
/// All output still goes through the original target lease and cleanup pipeline.
@MainActor
enum BufferedDictationFinalizer {
    /// An incomplete stream is recoverable from its saved recording, never an
    /// invitation to silently run a second, whole-recording recognition pass.
    struct IncompleteStream: Error, LocalizedError {
        let reason: String
        let partialText: String
        var errorDescription: String? { "Live transcription could not finish (\(reason))." }
    }

    /// Arm correction observation only once cleanup has reached the original editor.
    /// Recheck session/settings after the asynchronous paste acknowledgment.
    static func deliver(
        text: String,
        target: LiveDictationTextTarget,
        isCurrent: () -> Bool,
        correctionMonitoringEnabled: () -> Bool,
        onDelivered: (String) -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let delivered = await target.finish(
            text: text + DictationPasteSpacing.trailingSeparator(after: text)
        )
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        if delivered && correctionMonitoringEnabled() {
            onDelivered(text)
        }
        return delivered
    }

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
        nonStreaming: () async throws -> SpeechTranscriptionResult
    ) async throws -> SpeechTranscriptionResult {
        defer { session?.cancel() }
        try Task.checkCancellation()
        guard let session else { return try await nonStreaming() }
        guard let recordedSampleCount, recordedSampleCount > 0,
              session.diagnostics.receivedSamples == recordedSampleCount else {
            session.cancel()
            onDecision("incomplete:recording_coverage_mismatch:recorded=\(recordedSampleCount ?? -1):streamed=\(session.diagnostics.receivedSamples)")
            try Task.checkCancellation()
            throw IncompleteStream(reason: "recording_coverage_mismatch", partialText: session.currentTranscript)
        }
        if let reason = session.knownReuseFallbackReason {
            session.cancel()
            onDecision("incomplete:\(reason.rawValue):committed_evidence \(session.reuseDiagnostics)")
            try Task.checkCancellation()
            throw IncompleteStream(reason: reason.rawValue, partialText: session.currentTranscript)
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
            let reason = timedOut ? "tail_drain_timeout"
                : result.fallbackReason?.rawValue ?? "incomplete_coverage"
            onDecision("incomplete:\(reason) \(result.diagnostics)")
            try Task.checkCancellation()
            throw IncompleteStream(reason: reason, partialText: result.text)
        }
        onDecision("reuse \(result.diagnostics)")
        // If cleanup fails/cancels, propagate normally; do not run ASR and cleanup
        // again as though the accepted recognition had failed.
        try Task.checkCancellation()
        return try await reuse(result.text)
    }
}
