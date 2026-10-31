import AVFoundation
import Foundation
import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("Bounded meeting recording transcription")
struct MeetingRecordingTranscriberTests {
    @Test("direct diarization PCM preserves mono samples and converts stereo bounded windows",
          arguments: [16_000.0, 44_100.0, 48_000.0])
    func directPCM(rate: Double) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-pcm-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let channels: AVAudioChannelCount = rate == 16_000 ? 1 : 2
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = Int(rate * 20.25)
        func sample(_ i: Int) -> Float { Float(sin(Double(i) * 2 * .pi * 200 / rate) * 0.25) }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            var offset = 0
            while offset < frames {
                let count = min(4096, frames - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<Int(channels) {
                    for i in 0..<count { buffer.floatChannelData![channel][i] = sample(offset + i) }
                }
                try writer.write(from: buffer)
                offset += count
            }
        }
        let reader = try DiarizationPCMWindowReader(url: url)
        var end = 0.0
        var count = 0
        while let window = try reader.next() {
            #expect(window.start == end)
            #expect(window.samples.count <= 160_000)
            #expect(abs(Double(window.samples.count) / 16_000 - (window.end - window.start)) < 0.01)
            #expect(window.samples.allSatisfy { $0.isFinite })
            if rate == 16_000 {
                let start = Int((window.start * rate).rounded())
                #expect(window.samples.enumerated().allSatisfy { $0.element == sample(start + $0.offset) })
            }
            end = window.end
            count += 1
        }
        #expect(count == 3)
        #expect(abs(end - 20.25) < 0.0001)
        #expect(try reader.next() == nil)
    }

    @Test("direct PCM reader honors cancellation before reading")
    func directPCMCancellation() async throws {
        let url = try recording(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            let reader = try DiarizationPCMWindowReader(url: url)
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try reader.next() }
        }
        try await task.value
    }

    @Test("replay windows preserve every PCM sample without duplication", arguments: [5.0, 10.0])
    func windowSampleIntegrity(seconds: Double) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-integrity-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        func sample(_ index: Int) -> Float { Float(index % 8191) / 8192 }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            for second in 0..<21 {
                for i in 0..<16_000 { buffer.floatChannelData![0][i] = sample(second * 16_000 + i) }
                try writer.write(from: buffer)
            }
        }
        let reader = try RecordingAudioWindowReader(url: url, seconds: seconds, overlapSeconds: seconds == 5 ? 0.4 : 0)
        defer { reader.close() }
        while let window = try reader.next() {
            let file = try AVAudioFile(forReading: window.url)
            let start = Int((window.start * 16_000).rounded())
            #expect(file.length == AVAudioFramePosition(((window.end - window.start) * 16_000).rounded()))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            while file.framePosition < file.length {
                let offset = Int(file.framePosition)
                try file.read(into: buffer, frameCount: 4096)
                try #require(buffer.frameLength > 0)
                #expect((0..<Int(buffer.frameLength)).allSatisfy { buffer.floatChannelData![0][$0] == sample(start + offset + $0) })
            }
        }
    }

    @Test("optional diarization failures preserve successful ASR with a warning")
    func optionalDiarizationFallback() async throws {
        let transcription = SpeechTranscriptionResult(text: "Recovered transcript", segments: [])
        for error in [DiarizerError.notInitialized, .processingFailed("timeout"), .memoryAllocationFailed] {
            let result = try await RecordedTranscriptDiarization.apply(to: transcription) { throw error }
            #expect(result.transcript == transcription.text)
            #expect(result.warning?.contains("without speaker labels") == true)
        }
    }

    @Test("diarization cancellation never becomes successful raw-text fallback")
    func optionalDiarizationCancellation() async {
        let transcription = SpeechTranscriptionResult(text: "Do not save", segments: [])
        do {
            _ = try await RecordedTranscriptDiarization.apply(to: transcription) { throw CancellationError() }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        let task = Task {
            try await RecordedTranscriptDiarization.apply(to: transcription) {
                withUnsafeCurrentTask { $0?.cancel() }
                throw DiarizerError.processingFailed("cancelled backend operation")
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected wrapped cancellation")
        } catch { #expect(error is CancellationError) }
    }

    @Test("successful speaker identification returns labelled text without a warning")
    func optionalDiarizationSuccess() async throws {
        let transcription = SpeechTranscriptionResult(text: "Hello Goodbye", segments: [
            SpeechSegment(start: 0, end: 2, text: "Hello"),
            SpeechSegment(start: 3, end: 5, text: "Goodbye"),
        ])
        let result = try await RecordedTranscriptDiarization.apply(to: transcription) {
            [
                TimedSpeakerSegment(speakerId: "1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 1),
                TimedSpeakerSegment(speakerId: "2", embedding: [], startTimeSeconds: 3, endTimeSeconds: 5, qualityScore: 1),
            ]
        }
        #expect(result.transcript.contains("Speaker 1: Hello"))
        #expect(result.transcript.contains("Speaker 2: Goodbye"))
        #expect(result.warning == nil)
    }

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

    @Test("replay keeps trimmed token timings on the recording timeline with word starts restored")
    func replayKeepsTokenTimings() async throws {
        let url = try recording(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = TokenWindowProbe()
        let result = try await MeetingRecordingTranscriber().transcribe(url: url, infer: { _ in
            await probe.next()
        }, progress: { _, _ in })

        #expect(result.text == "How are you? Fine thanks")
        #expect(result.hasTokenTimedSegments)
        #expect(result.segments.map(\.text) == [" H", "ow", " are", " you", "?", " Fine", " thanks"])
        // The second window starts 0.4s before the first ends and repeats "you?".
        #expect(abs(result.segments[5].start - 4.8) < 0.001)
        let formatted = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: result,
            diarizationSegments: [
                TimedSpeakerSegment(speakerId: "1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 1),
                TimedSpeakerSegment(speakerId: "2", embedding: [], startTimeSeconds: 1, endTimeSeconds: 8, qualityScore: 1),
            ],
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(formatted.contains("Speaker 1: How"))
        #expect(formatted.contains("Speaker 2: are\n"))
        #expect(formatted.contains("Speaker 2: you? Fine thanks"))
    }

    @Test("token alignment drops words the transcript text removed")
    func tokenAlignmentFollowsText() throws {
        let tokens = [
            SpeechSegment(start: 0.0, end: 0.2, text: "this"),
            SpeechSegment(start: 0.2, end: 0.4, text: "um"),
            SpeechSegment(start: 0.4, end: 0.6, text: ","),
            SpeechSegment(start: 0.6, end: 0.8, text: "account"),
            SpeechSegment(start: 0.8, end: 1.0, text: "ing"),
            SpeechSegment(start: 1.0, end: 1.2, text: "works"),
        ]
        let aligned = try #require(MeetingRecordingTranscriber.alignedTokens(tokens, to: "accounting works", offset: 10))
        #expect(aligned.map(\.text) == [" account", "ing", " works"])
        #expect(aligned.first?.start == 10.6)
    }

    @Test("segments that are not tokens of the text keep the window fallback")
    func tokenAlignmentRejectsOtherSegments() async throws {
        let phrases = [SpeechSegment(start: 0, end: 2, text: "hello there")]
        #expect(MeetingRecordingTranscriber.alignedTokens(phrases, to: "hello there", offset: 0) == nil)
        let placeholder = [SpeechSegment(start: 0, end: 0, text: "hello")]
        #expect(MeetingRecordingTranscriber.alignedTokens(placeholder, to: "hello", offset: 0) == nil)
        let mismatch = [SpeechSegment(start: 0, end: 1, text: "goodbye")]
        #expect(MeetingRecordingTranscriber.alignedTokens(mismatch, to: "hello", offset: 0) == nil)

        let url = try recording(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await MeetingRecordingTranscriber().transcribe(url: url, infer: { _ in
            SpeechTranscriptionResult(text: "hello there", segments: phrases)
        }, progress: { _, _ in })
        #expect(!result.hasTokenTimedSegments)
        #expect(result.segments.map(\.text) == ["hello there"])
        #expect(result.segments.first?.end == 4)
    }

    @Test("diarization reads an hour in ten-second windows without overlap or retained PCM")
    func diarizationWindows() throws {
        let url = try recording(seconds: 3_601)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DiarizationPCMWindowReader(url: url)
        var end: Double = 0
        var count = 0
        while let window = try reader.next() {
            #expect(window.start == end)
            #expect(window.end - window.start <= 10)
            #expect(window.samples.count <= 160_000)
            #expect(window.samples.count == Int(((window.end - window.start) * 16_000).rounded()))
            end = window.end
            count += 1
        }
        #expect(count == 361)
        #expect(end == 3_601)
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
        let reader = try DiarizationPCMWindowReader(url: compressed)
        var end: Double = 0
        var count = 0
        while let window = try reader.next() {
            #expect(window.start == end)
            #expect(window.end - window.start <= 10)
            #expect(!window.samples.isEmpty && window.samples.count <= 160_000)
            end = window.end
            count += 1
        }
        #expect(count == 3)
        #expect(abs(end - 23) < 0.1)
    }
}

/// Two overlapping windows of trimmed tokens, as meeting cleanup leaves them.
private actor TokenWindowProbe {
    private var windows = [
        SpeechTranscriptionResult(text: "How are you?", segments: [
            SpeechSegment(start: 0.7, end: 1.0, text: "H"),
            SpeechSegment(start: 1.0, end: 1.2, text: "ow"),
            SpeechSegment(start: 1.2, end: 1.4, text: "are"),
            SpeechSegment(start: 4.2, end: 4.4, text: "you"),
            SpeechSegment(start: 4.4, end: 4.5, text: "?"),
        ]),
        SpeechTranscriptionResult(text: "you? Fine thanks", segments: [
            SpeechSegment(start: 0.0, end: 0.1, text: "you"),
            SpeechSegment(start: 0.1, end: 0.2, text: "?"),
            SpeechSegment(start: 0.2, end: 0.5, text: "Fine"),
            SpeechSegment(start: 0.5, end: 0.9, text: "thanks"),
        ]),
    ]

    func next() -> SpeechTranscriptionResult {
        windows.removeFirst()
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
