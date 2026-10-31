import AVFoundation
import Foundation
import os

/// Shares dictation recognition, but owns no text target or partial-text UI.
/// Final reuse requires complete coverage of the recorder's authoritative WAV.
final class QuillQuestionRecognition: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    let session: BufferedTranscriptionSession?
    private let hostedSession: (any HostedDictationSession)?
    private let transcribeFile: @Sendable (URL) async throws -> String

    init(session: BufferedTranscriptionSession?, transcribeFile: @escaping @Sendable (URL) async throws -> String) {
        self.hostedSession = nil
        self.session = session
        self.transcribeFile = transcribeFile
    }

    init(hostedSession: any HostedDictationSession) {
        self.hostedSession = hostedSession
        session = nil
        // Hosted finalization uses the existing dictation session below.
        transcribeFile = { _ in throw CancellationError() }
    }

    func append(_ samples: [Float]) {
        guard !cancelled.withLock({ $0 }) else { return }
        session?.enqueue(samples)
        if let hostedSession, hostedSession.acceptsLiveAudio { hostedSession.append(samples) }
    }
    func cancel() {
        cancelled.withLock { $0 = true }
        session?.cancel()
        hostedSession?.cancel()
    }
    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }

    func finish(recordedURL: URL) async throws -> String {
        try checkCancellation()
        if let hostedSession {
            return try await withTaskCancellationHandler {
                let result = try await hostedSession.finish(recordedWAVURL: recordedURL)
                try checkCancellation()
                return result.text
            } onCancel: {
                self.cancel()
            }
        }
        if let session {
            let result = await session.finishForReuse()
            try checkCancellation()
            let file = try AVAudioFile(forReading: recordedURL)
            if result.canReuse, file.processingFormat.sampleRate == 16_000,
               file.processingFormat.channelCount == 1, file.length == Int64(result.receivedSamples) {
                return result.text
            }
        }
        try checkCancellation()
        return try await transcribeFile(recordedURL)
    }
}
