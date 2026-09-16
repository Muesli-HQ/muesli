import AVFoundation
import Foundation
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
