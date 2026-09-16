import AVFoundation
import Foundation

/// Reads only one bounded window at a time. Awaiting inference before the next
/// read provides backpressure even when decoding is much faster than ASR.
actor MeetingRecordingTranscriber {
    static let windowSeconds: Double = 5
    static let overlapSeconds: Double = 0.4

    func transcribe(
        url: URL,
        infer: @Sendable (URL) async throws -> SpeechTranscriptionResult,
        progress: @Sendable (Double, String) async -> Void
    ) async throws -> SpeechTranscriptionResult {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0 else {
            throw MeetingRetranscriptionError.emptyTranscript
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = AVAudioFrameCount(rate * Self.windowSeconds)
        let overlap = AVAudioFramePosition(rate * Self.overlapSeconds)
        var transcript = ""
        var previousWindowText = ""
        var segments: [SpeechSegment] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let start = file.framePosition
            let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), file.length - start))
            let chunkURL = directory.appendingPathComponent("chunk.wav")
            // Buffer and writer are released before inference, not after the full recording.
            try autoreleasepool {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                    throw CocoaError(.fileReadTooLarge)
                }
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let writer = try AVAudioFile(forWriting: chunkURL, settings: file.processingFormat.settings)
                try writer.write(from: buffer)
            }
            let end = file.framePosition
            let result = try await infer(chunkURL)
            try Task.checkCancellation()
            let addition = Self.removingOverlap(previous: previousWindowText, next: result.text)
            // A silent window breaks the shared-word boundary. Never match text
            // from an earlier, non-overlapping speech region.
            previousWindowText = String(result.text.suffix(400))
            if !addition.isEmpty {
                transcript += transcript.isEmpty ? addition : " " + addition
                segments.append(SpeechSegment(start: Double(start) / rate, end: Double(end) / rate, text: addition))
            }
            try FileManager.default.removeItem(at: chunkURL)
            await progress(Double(end) / Double(file.length), String(transcript.suffix(2_000)))
            if end == file.length { break }
            file.framePosition = max(start + 1, end - overlap)
        }
        return SpeechTranscriptionResult(text: transcript, segments: segments)
    }

    /// Only reconcile the short shared boundary; never deduplicate the body of a chunk.
    static func removingOverlap(previous: String, next: String) -> String {
        let old = previous.suffix(400).split(whereSeparator: \.isWhitespace)
        let new = next.split(whereSeparator: \.isWhitespace)
        func key(_ word: Substring) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let limit = min(8, old.count, new.count)
        if limit > 0 {
            for count in stride(from: limit, through: 1, by: -1) {
                if old.suffix(count).map(key) == new.prefix(count).map(key) {
                    return new.dropFirst(count).joined(separator: " ")
                }
            }
        }
        return next.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MeetingRetranscriptionProgress: Equatable {
    enum Phase: Equatable { case preparing, transcribing, summarizing, completed, cancelled, failed }
    var phase: Phase = .preparing
    var fraction: Double = 0
    var preview: String = ""
    var message: String = "Preparing model…"
    var isRunning: Bool { phase == .preparing || phase == .transcribing || phase == .summarizing }
}
