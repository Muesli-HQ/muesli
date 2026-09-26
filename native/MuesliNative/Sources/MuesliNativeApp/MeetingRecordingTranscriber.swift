import AVFoundation
import FluidAudio
import Foundation

/// Shared disk-backed reader for ASR and diarization. Only one window exists
/// at a time; the caller must finish inference before requesting the next one.
final class RecordingAudioWindowReader {
    struct Window {
        let url: URL
        let start: Double
        let end: Double
        let fraction: Double
    }

    private let file: AVAudioFile
    private let directory: URL
    private let capacity: AVAudioFrameCount
    private let overlap: AVAudioFramePosition
    private var finished = false

    init(url: URL, seconds: Double, overlapSeconds: Double) throws {
        file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0,
              seconds.isFinite, overlapSeconds.isFinite,
              seconds > 0, overlapSeconds >= 0, overlapSeconds < seconds,
              rate * seconds >= 1, rate * seconds < Double(UInt32.max) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        capacity = AVAudioFrameCount(rate * seconds)
        overlap = AVAudioFramePosition(rate * overlapSeconds)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
    deinit { close() }

    func next() throws -> Window? {
        try Task.checkCancellation()
        guard !finished else { return nil }
        let start = file.framePosition
        let rate = file.processingFormat.sampleRate
        let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), file.length - start))
        let url = directory.appendingPathComponent("chunk.wav")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try autoreleasepool {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                throw CocoaError(.fileReadTooLarge)
            }
            let writer = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings)
            // AVAudioFile can return a short read before EOF (including WAV).
            // Fill this window without accumulating another PCM buffer or
            // accidentally turning the final decoder tail into a tiny ASR chunk.
            var remaining = count
            while remaining > 0 {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                try writer.write(from: buffer)
                remaining -= buffer.frameLength
            }
        }
        let end = file.framePosition
        finished = end == file.length
        if !finished { file.framePosition = max(start + 1, end - overlap) }
        return Window(url: url, start: Double(start) / rate, end: Double(end) / rate,
                      fraction: Double(end) / Double(file.length))
    }
}

/// Reuses the loaded models, but never shares speaker identities across jobs.
/// PCM is bounded to the model's native ten-second window; only lightweight
/// speaker/timing output grows with the transcript, not audio or embeddings.
final class RecordedAudioDiarizationSession {
    static let windowSeconds: Double = 10
    static let maximumSpeakers = 128
    private let manager: DiarizerManager
    private var speakers: SpeakerManager

    init(manager: DiarizerManager) {
        self.manager = manager
        speakers = manager.speakerManager
        speakers.reset()
    }

    func process(_ window: RecordingAudioWindowReader.Window) throws -> [TimedSpeakerSegment] {
        try Task.checkCancellation()
        return try autoreleasepool {
            let samples = try AudioConverter().resampleAudioFile(window.url)
            let result = try withSpeakerState { model in
                try model.performCompleteDiarization(samples, sampleRate: 16_000, atTime: window.start)
            }
            return Self.clippedSegments(result.segments, start: window.start, end: window.end)
        }
    }

    func withSpeakerState<T>(_ infer: (DiarizerManager) throws -> T) throws -> T {
        // No await while swapping the model's speaker state. The coordinator
        // serializes inference; restore even on cancellation/model/limit failure.
        try Task.checkCancellation()
        let previous = manager.speakerManager
        manager.speakerManager = speakers
        defer { manager.speakerManager = previous }
        let result = try infer(manager)
        try Task.checkCancellation()
        try Self.validateSpeakerCount(manager.speakerManager.speakerCount)
        speakers = manager.speakerManager
        return result
    }

    static func validateSpeakerCount(_ count: Int) throws {
        // Fail explicitly rather than merging unrelated voices or allowing a
        // noisy recording to grow the embedding database indefinitely. FluidAudio
        // already limits each speaker's raw embedding history to 50 entries.
        guard count <= maximumSpeakers else {
            throw DiarizerError.processingFailed("Speaker tracking exceeded its safety limit.")
        }
    }

    static func clippedSegments(_ segments: [TimedSpeakerSegment], start: Double, end: Double) -> [TimedSpeakerSegment] {
        segments.compactMap { segment in
            let lower = max(Float(start), segment.startTimeSeconds)
            let upper = min(Float(end), segment.endTimeSeconds)
            guard !segment.speakerId.isEmpty, lower.isFinite, upper.isFinite, upper > lower else { return nil }
            let embedding = (try? OwnerVoiceProfile.normalized(segment.embedding)) ?? []
            return TimedSpeakerSegment(speakerId: segment.speakerId, embedding: embedding,
                                       startTimeSeconds: lower, endTimeSeconds: upper,
                                       qualityScore: segment.qualityScore)
        }
    }
}

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
        let reader = try RecordingAudioWindowReader(url: url, seconds: Self.windowSeconds, overlapSeconds: Self.overlapSeconds)
        defer { reader.close() }
        var transcript = ""
        var previousWindowText = ""
        var segments: [SpeechSegment] = []
        while let window = try reader.next() {
            let result = try await infer(window.url)
            try Task.checkCancellation()
            let addition = Self.removingOverlap(previous: previousWindowText, next: result.text)
            // A silent window breaks the shared-word boundary. Never match text
            // from an earlier, non-overlapping speech region.
            previousWindowText = String(result.text.suffix(400))
            if !addition.isEmpty {
                transcript += transcript.isEmpty ? addition : " " + addition
                segments.append(SpeechSegment(start: window.start, end: window.end, text: addition))
            }
            try FileManager.default.removeItem(at: window.url)
            await progress(window.fraction, String(transcript.suffix(2_000)))
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
    enum Phase: Equatable { case preparing, transcribing, diarizing, summarizing, completed, cancelled, failed }
    var phase: Phase = .preparing
    var fraction: Double = 0
    var preview: String = ""
    var message: String = "Preparing model…"
    var warning: String?
    var isRunning: Bool { phase == .preparing || phase == .transcribing || phase == .diarizing || phase == .summarizing }
}

enum RecordedTranscriptDiarization {
    struct Outcome: Sendable {
        let transcript: String
        let warning: String?
        var segments: [TimedSpeakerSegment] = []
    }

    /// Speaker identification enriches a successful ASR result; it must not
    /// prevent recovery. Cancellation is never treated as a successful fallback.
    static func apply(
        to transcription: SpeechTranscriptionResult,
        identify: @Sendable () async throws -> [TimedSpeakerSegment]
    ) async throws -> Outcome {
        try Task.checkCancellation()
        do {
            let segments = try await identify()
            try Task.checkCancellation()
            let text = AudioFileImportController.formatTranscriptWithSpeakers(
                transcription: transcription, diarizationSegments: segments,
                meetingStart: AudioFileImportController.importedTranscriptTimelineStart()
            )
            return Outcome(transcript: text, warning: nil, segments: segments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Backends may report cancellation as an ordinary model/network error.
            try Task.checkCancellation()
            fputs("[retranscription] speaker identification unavailable; keeping ASR transcript: \(error)\n", stderr)
            return Outcome(
                transcript: transcription.text.trimmingCharacters(in: .whitespacesAndNewlines),
                warning: "Speaker identification failed. Transcription continued without speaker labels."
            )
        }
    }
}
