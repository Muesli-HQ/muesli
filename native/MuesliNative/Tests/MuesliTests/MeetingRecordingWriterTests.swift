import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingWriter")
struct MeetingRecordingWriterTests {

    @Test("feedback narration is incremental, fills clock gaps and trims overlap")
    func incrementalNarration() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("narration.wav")
        let writer = try MeetingRecordingWriter(destination: url)
        try writer.appendMicrophone([100, 200, 300], startFrame: 1000)
        #expect(try Data(contentsOf: url).count == 50)
        try writer.appendMicrophone([400, 500], startFrame: 1005)
        try writer.appendMicrophone([600, 700, 800], startFrame: 1006)
        try writer.appendMicrophone([900], startFrame: 1000)
        #expect(try writer.finishMicrophone() == url)
        #expect(try readMonoPCM16WAVSamples(from: url) == [100, 200, 300, 0, 0, 400, 500, 700, 800])
        #expect(throws: (any Error).self) { try writer.appendMicrophone([1], startFrame: 1009) }
        let empty = try MeetingRecordingWriter(destination: url)
        #expect(try empty.finishMicrophone() == nil)
        #expect(try Data(contentsOf: url).count == 44, "Feedback keeps the empty header for recovery")
        let failed = try MeetingRecordingWriter(destination: url)
        try failed.appendMicrophone([100], startFrame: 0)
        #expect(throws: (any Error).self) { try failed.appendMicrophone([200], startFrame: 16_000 * 601) }
        #expect(throws: (any Error).self) { try failed.finishMicrophone() }
        #expect(try readMonoPCM16WAVSamples(from: url) == [100])
        let meeting = try MeetingRecordingWriter(destination: url)
        #expect(meeting.stop() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "Meeting stop deletes an empty recording")
    }

    @Test("meeting stop preserves audio and reports a final synchronization error")
    func stopPreservesRecordingWhenSynchronizationFails() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.wav")
        let writer = try MeetingRecordingWriter(destination: url, synchronize: { _ in
            throw NSError(domain: "MeetingRecordingWriterTests", code: 17)
        })
        writer.appendMic([1200, -800, 400])

        let result = writer.stopRecording()

        #expect(result.recordingURL == url)
        #expect((result.error as NSError?)?.domain == "MeetingRecordingWriterTests")
        #expect((result.error as NSError?)?.code == 17)
        #expect(try readMonoPCM16WAVSamples(from: url) == [1200, -800, 400])
    }

    @Test("WAV publication repairs stale headers and keeps unrepaired sources")
    func wavPublicationRepairsOrRetainsSource() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("stale-header.wav")
        let pcm = Data([0xB0, 0x04, 0xE0, 0xFC, 0x90, 0x01])
        var staleWAV = WavWriter.header(dataSize: 0)
        staleWAV.append(pcm)
        try staleWAV.write(to: source)
        let supportDirectory = root.appendingPathComponent("support", isDirectory: true)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: source,
            meetingTitle: "Header Repair",
            startedAt: Date(timeIntervalSince1970: 0),
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )
        let savedWAV = try Data(contentsOf: savedURL)
        #expect(Data(savedWAV.prefix(44)) == WavWriter.header(dataSize: UInt32(pcm.count)))
        #expect(Data(savedWAV.suffix(pcm.count)) == pcm)
        #expect(!FileManager.default.fileExists(atPath: source.path))

        let invalidSource = root.appendingPathComponent("invalid.wav")
        let invalidBytes = Data("not a WAV".utf8)
        try invalidBytes.write(to: invalidSource)
        let invalidSupportDirectory = root.appendingPathComponent("invalid-support", isDirectory: true)
        var didFail = false
        do {
            _ = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
                from: invalidSource,
                meetingTitle: "Invalid",
                startedAt: Date(timeIntervalSince1970: 0),
                supportDirectory: invalidSupportDirectory,
                fileFormat: .wav
            )
        } catch {
            didFail = true
        }
        #expect(didFail)
        #expect(FileManager.default.fileExists(atPath: invalidSource.path))
        #expect((try? Data(contentsOf: invalidSource)) == invalidBytes)
        let publishedFiles = (try? FileManager.default.contentsOfDirectory(
            atPath: invalidSupportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true).path
        )) ?? []
        #expect(publishedFiles.isEmpty)
    }

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
            ("func stop(template:", "retainedRecordingWriter?.stopRecording()")
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
