import AVFoundation
import Foundation
import os

/// Shares dictation recognition, but owns no text target or partial-text UI.
/// Final reuse requires complete coverage of the recorder's authoritative WAV.
final class QuillQuestionRecognition: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    let session: BufferedTranscriptionSession?
    private let hostedSession: (any HostedDictationSession)?
    private let finalizeBuffered: @Sendable (String) async -> String
    private let transcribeFile: @Sendable (URL) async throws -> String

    init(session: BufferedTranscriptionSession?, finalizeBuffered: @escaping @Sendable (String) async -> String = { $0 }, transcribeFile: @escaping @Sendable (URL) async throws -> String) {
        self.finalizeBuffered = finalizeBuffered
        self.hostedSession = nil
        self.session = session
        self.transcribeFile = transcribeFile
    }

    init(hostedSession: any HostedDictationSession) {
        self.finalizeBuffered = { $0 }
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
                let text = await finalizeBuffered(result.text)
                try checkCancellation()
                return text
            }
        }
        try checkCancellation()
        return try await transcribeFile(recordedURL)
    }
}

/// Coalesced windows and file recovery share one preparation attempt per turn.
actor QuillRecognitionPreparation {
    private var task: Task<Void, Error>?
    func ensure(_ prepare: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        let work: Task<Void, Error>
        if let task { work = task }
        else { work = Task { try await prepare() }; task = work }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
    }
}
