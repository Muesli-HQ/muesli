import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingWriter")
struct MeetingRecordingWriterTests {

    @Test("retained mic is wired only to the cleaned stream, before pause and stop finalization")
    func sessionRetainsCleanedMicAndFlushesBeforeFinalization() throws {
        // Guard the session wiring without starting hardware capture or loading models.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/MeetingSession.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.components(separatedBy: "retainedRecordingWriter?.appendMic(").count == 2)
        let funnel = try #require(source.range(of: "private func appendCleanedMicSamplesOnQueue"))
        let append = try #require(source.range(of: "retainedRecordingWriter?.appendMic(cleanedInt16)"))
        let recorder = try #require(source.range(of: "rawMicChunkRecorder?.append(cleanedInt16)"))
        #expect(funnel.lowerBound < append.lowerBound && append.lowerBound < recorder.lowerBound)
        for (start, finish) in [
            ("func pause()", "retainedRecordingWriter?.markPauseBoundary()"),
            ("func stop(onRecordingReady:", "retainedRecordingWriter?.stop()")
        ] {
            let startRange = try #require(source.range(of: start))
            let body = source[startRange.upperBound...]
            let flush = try #require(body.range(of: "appendFlushedStreamingMicOnQueue()"))
            let finalization = try #require(body.range(of: finish))
            #expect(flush.lowerBound < finalization.lowerBound)
        }
    }

    @Test("recording mixes delayed cleaned mic and retains partial AEC frames across pause and stop")
    func writerConsumesBufferedAECOutput() throws {
        let writer = try MeetingRecordingWriter()
        defer { writer.cancel() }
        let aec = MeetingNeuralAec(preloadedProcessor: SubtractingRecordingAecProcessor())
        func appendCleaned(_ samples: [Float]) {
            writer.appendMic(samples.map { Int16(max(-1, min(1, $0)) * 32767) })
        }
        // Mic includes local speech (0.125) and speaker bleed (0.25).
        // Reference arrives later; no raw mic should reach the recording.
        for pauseAfter in [true, false] {
            #expect(aec.processStreamingMic(Array(repeating: 0.375, count: 6)).isEmpty)
            writer.appendSystem(Array(repeating: 8191, count: 6))
            aec.feedSystemSamples(Array(repeating: 0.25, count: 6))
            let cleaned = aec.processStreamingMic([])
            #expect(cleaned == Array(repeating: Float(0.125), count: 4))
            appendCleaned(cleaned)
            let tail = aec.flushStreamingMic()
            #expect(tail == Array(repeating: Float(0.125), count: 2))
            appendCleaned(tail)
            if pauseAfter {
                writer.markPauseBoundary()
                aec.resetForStreaming()
            }
        }
        let url = try #require(writer.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        // Each sample mixes only local speech and system audio, not the bleed.
        #expect(try readMonoPCM16WAVSamples(from: url) == Array(repeating: Int16(6143), count: 12))
    }

    @Test("streaming writer merges mic and system samples incrementally")
    func writerMergesIncrementally() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000, 4000])
        writer.appendSystem([3000, -2000])
        writer.appendSystem([500, 1500])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2000, 0, 1750, 2750])
    }

    @Test("streaming writer flushes single-track tail on stop")
    func writerFlushesSingleTrackTail() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1200, -800, 400])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1200, -800, 400])
    }

    @Test("pause boundary prevents unmatched samples from mixing across pause")
    func pauseBoundaryFlushesPendingSamples() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 3000])
        writer.markPauseBoundary()
        writer.appendSystem([5000, 7000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1000, 3000, 5000, 7000])
    }

    @Test("persistTemporaryRecording moves the temp wav when WAV is selected")
    func persistTemporaryRecordingMovesWAVFile() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400])
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav"))
        #expect(try readMonoPCM16WAVSamples(from: savedURL) == [1200, -800, 400])
    }

    @Test("persistTemporaryRecording transcodes to M4A by default")
    func persistTemporaryRecordingTranscodesToM4AByDefault() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: Int16(1200), count: 16_000))
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.pathExtension == "m4a")
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync.m4a"))

        let file = try AVAudioFile(forReading: savedURL)
        #expect(file.length > 0)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }
}

private final class SubtractingRecordingAecProcessor: MeetingAecProcessor {
    let name = "localvqe"
    let frameSize = 4
    let sampleRate = 16_000
    func reset() {}
    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        zip(mic, reference).map { $0 - $1 }
    }
}
