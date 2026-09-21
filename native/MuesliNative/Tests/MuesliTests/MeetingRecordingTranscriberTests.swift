import AVFoundation
import Foundation
import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("Bounded meeting recording transcription")
struct MeetingRecordingTranscriberTests {
    private func recording(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retry-test-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<seconds { try writer.write(from: buffer) }
        return url
    }

    @Test("an hour recording is decoded sequentially into bounded temporary windows")
    func hourRecording() async throws {
        let url = try recording(seconds: 3_600)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = RecordingWindowProbe()
        let result = try await MeetingRecordingTranscriber().transcribe(url: url, infer: { chunk in
            try await probe.infer(chunk)
        }, progress: { value, preview in
            await probe.progress(value, preview: preview)
        })
        #expect(await probe.count > 720)
        #expect(await probe.maximumDuration <= 5.001)
        #expect(await probe.maximumFiles == 1)
        #expect(await probe.fraction == 1)
        #expect(await probe.maximumPreview <= 2_000)
        #expect(result.segments.last?.end == 3_600)
        let directory = try #require(await probe.directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("inference failure cleans temporary windows and keeps source audio")
    func failureCleanup() async throws {
        let url = try recording(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = RecordingWindowProbe()
        do {
            _ = try await MeetingRecordingTranscriber().transcribe(url: url, infer: { chunk in
                _ = try await probe.infer(chunk)
                throw CocoaError(.fileReadUnknown)
            }, progress: { _, _ in })
            Issue.record("Expected injected inference failure")
        } catch {}
        #expect(await probe.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let directory = try #require(await probe.directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("cancellation stops before another window is decoded")
    func cancellation() async throws {
        let url = try recording(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = RecordingWindowProbe()
        let task = Task {
            try await MeetingRecordingTranscriber().transcribe(url: url, infer: { chunk in
                _ = try await probe.infer(chunk)
                try await Task.sleep(for: .seconds(30))
                return SpeechTranscriptionResult(text: "unexpected", segments: [])
            }, progress: { _, _ in })
        }
        for _ in 0..<200 {
            if await probe.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(await probe.count == 1)
        let directory = try #require(await probe.directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("overlap joins shared boundary words without removing a later repetition")
    func overlap() {
        #expect(MeetingRecordingTranscriber.removingOverlap(previous: "we will review this tomorrow.", next: "this tomorrow and review this tomorrow again") == "and review this tomorrow again")
        #expect(MeetingRecordingTranscriber.removingOverlap(previous: "first topic", next: "second topic") == "second topic")
    }

    @Test("diarization reads an hour in ten-second windows without overlap or retained PCM")
    func diarizationWindows() throws {
        let url = try recording(seconds: 3_601)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try RecordingAudioWindowReader(url: url, seconds: RecordedAudioDiarizationSession.windowSeconds, overlapSeconds: 0)
        var end: Double = 0
        var count = 0
        var directory: URL?
        while let window = try reader.next() {
            #expect(window.start == end)
            #expect(window.end - window.start <= 10)
            let chunk = try AVAudioFile(forReading: window.url)
            #expect(chunk.length <= 160_000)
            directory = window.url.deletingLastPathComponent()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory!.path).count == 1)
            end = window.end
            count += 1
        }
        #expect(count == 361)
        #expect(end == 3_601)
        reader.close()
        #expect(!FileManager.default.fileExists(atPath: try #require(directory).path))
    }

    @Test("diarization clips padded tail, drops embeddings and bounds speaker tracking")
    func diarizationBounds() throws {
        let segments = [
            TimedSpeakerSegment(speakerId: "1", embedding: [1, 2], startTimeSeconds: 9, endTimeSeconds: 20, qualityScore: 1),
            TimedSpeakerSegment(speakerId: "2", embedding: [3, 4], startTimeSeconds: 15, endTimeSeconds: 20, qualityScore: 1),
        ]
        let result = RecordedAudioDiarizationSession.clippedSegments(segments, start: 10, end: 11)
        #expect(result.count == 1)
        #expect(result.first?.startTimeSeconds == 10)
        #expect(result.first?.endTimeSeconds == 11)
        #expect(result.first?.embedding.isEmpty == true)
        try RecordedAudioDiarizationSession.validateSpeakerCount(128)
        #expect(throws: (any Error).self) { try RecordedAudioDiarizationSession.validateSpeakerCount(129) }
        #expect(MeetingRetranscriptionProgress(phase: .diarizing).isRunning)
    }

    @Test("mixed-speaker ASR windows are not attributed entirely to one voice")
    func mixedSpeakerWindow() {
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: SpeechTranscriptionResult(text: "hello goodbye", segments: [
                SpeechSegment(start: 0, end: 5, text: "hello goodbye"),
            ]),
            diarizationSegments: [
                TimedSpeakerSegment(speakerId: "1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 1),
                TimedSpeakerSegment(speakerId: "2", embedding: [], startTimeSeconds: 2, endTimeSeconds: 5, qualityScore: 1),
            ], meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.contains("Multiple speakers: hello goodbye"))
        #expect(!result.contains("Speaker 1: hello goodbye"))
    }

    @Test("speaker identities persist within replay but are isolated from other recordings")
    func speakerIsolation() throws {
        let manager = DiarizerManager()
        let embedding = [Float](repeating: 1, count: 256)
        manager.speakerManager.upsertSpeaker(id: "existing", currentEmbedding: embedding, duration: 10)
        let first = RecordedAudioDiarizationSession(manager: manager)
        let id = try first.withSpeakerState { model in
            #expect(model.speakerManager.speakerCount == 0)
            return try #require(model.speakerManager.assignSpeaker(embedding, speechDuration: 3)?.id)
        }
        #expect(manager.speakerManager.speakerIds == ["existing"])
        try first.withSpeakerState { model in
            #expect(model.speakerManager.assignSpeaker(embedding, speechDuration: 3)?.id == id)
            #expect(model.speakerManager.speakerCount == 1)
        }
        let second = RecordedAudioDiarizationSession(manager: manager)
        try second.withSpeakerState { model in #expect(model.speakerManager.speakerCount == 0) }
        #expect(throws: (any Error).self) {
            try first.withSpeakerState { model in
                model.speakerManager.reset()
                throw CocoaError(.fileReadUnknown)
            }
        }
        #expect(manager.speakerManager.speakerIds == ["existing"])
        try first.withSpeakerState { model in #expect(model.speakerManager.speakerIds == [id]) }
    }

    @Test("diarizer limit and cancellation restore shared model state")
    func speakerStateFailure() throws {
        let manager = DiarizerManager()
        let session = RecordedAudioDiarizationSession(manager: manager)
        #expect(throws: (any Error).self) {
            try session.withSpeakerState { model in
                for index in 0...RecordedAudioDiarizationSession.maximumSpeakers {
                    model.speakerManager.upsertSpeaker(id: String(index), currentEmbedding: [Float](repeating: 1, count: 256), duration: 2)
                }
            }
        }
        #expect(manager.speakerManager.speakerCount == 0)
        #expect(throws: CancellationError.self) {
            try session.withSpeakerState { _ in throw CancellationError() }
        }
        try session.withSpeakerState { model in #expect(model.speakerManager.speakerCount == 0) }
    }

    @Test("retained M4A replay fills bounded windows and preserves its final tail")
    func compressedReplay() async throws {
        let source = try recording(seconds: 23)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diarization-m4a-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        let compressed = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: source, meetingTitle: "Test", startedAt: Date(), supportDirectory: directory, fileFormat: .m4a
        )
        let reader = try RecordingAudioWindowReader(url: compressed, seconds: 10, overlapSeconds: 0)
        defer { reader.close() }
        var end: Double = 0
        var count = 0
        while let window = try reader.next() {
            #expect(window.start == end)
            #expect(window.end - window.start <= 10)
            end = window.end
            count += 1
        }
        #expect(count == 3)
        #expect(abs(end - 23) < 0.1)
    }
}

private actor RecordingWindowProbe {
    var count = 0
    var maximumDuration: Double = 0
    var maximumFiles = 0
    var maximumPreview = 0
    var fraction: Double = 0
    var directory: URL?

    func infer(_ url: URL) throws -> SpeechTranscriptionResult {
        let file = try AVAudioFile(forReading: url)
        count += 1
        maximumDuration = max(maximumDuration, Double(file.length) / file.processingFormat.sampleRate)
        directory = url.deletingLastPathComponent()
        maximumFiles = max(maximumFiles, try FileManager.default.contentsOfDirectory(atPath: directory!.path).count)
        return SpeechTranscriptionResult(text: "window \(count)", segments: [])
    }

    func progress(_ value: Double, preview: String) {
        #expect(value >= fraction)
        fraction = value
        maximumPreview = max(maximumPreview, preview.count)
    }
}
