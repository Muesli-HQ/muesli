import FluidAudio
import Foundation
import os

struct AudioSampleStatsSnapshot: Codable {
    let sampleCount: Int
    let zeroSampleCount: Int
    let rms: Double
    let peak: Double
}

struct AudioSampleStats: Codable {
    private(set) var sampleCount = 0
    private(set) var zeroSampleCount = 0
    private(set) var sumSquares: Double = 0
    private(set) var peak: Double = 0

    mutating func addInt16(_ samples: [Int16]) {
        for sample in samples {
            addInt16Sample(sample)
        }
    }

    mutating func addInt16Sample(_ sample: Int16) {
        let value = Double(sample) / 32768.0
        addNormalizedSample(value)
    }

    mutating func addFloats(_ samples: [Float]) {
        for sample in samples {
            addNormalizedSample(Double(sample))
        }
    }

    private mutating func addNormalizedSample(_ sample: Double) {
        sampleCount += 1
        if sample == 0 {
            zeroSampleCount += 1
        }
        sumSquares += sample * sample
        peak = max(peak, abs(sample))
    }

    func snapshot() -> AudioSampleStatsSnapshot {
        AudioSampleStatsSnapshot(
            sampleCount: sampleCount,
            zeroSampleCount: zeroSampleCount,
            rms: sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0,
            peak: peak
        )
    }
}

struct SystemAudioCaptureDiagnosticsSnapshot: Codable {
    let backend: String
    let callbackCount: Int
    let bufferCount: Int
    let emptyBufferCount: Int
    let unsupportedFormatCount: Int
    let inputByteCount: Int
    let bytesWritten: Int
    let sourceSampleRate: Double
    let sourceChannels: UInt32
    let preConversion: AudioSampleStatsSnapshot
    let postConversion: AudioSampleStatsSnapshot
}

protocol SystemAudioDiagnosticsProviding {
    var diagnosticsSnapshot: SystemAudioCaptureDiagnosticsSnapshot { get }
}

struct MeetingAecDiagnosticsSnapshot: Codable {
    let ready: Bool
    let processedFrames: Int
    let fullReferenceFrames: Int
    let partialReferenceFrames: Int
    let missingReferenceFrames: Int
    let systemSamplesReceived: Int
    let micSamplesReceived: Int
    let bufferedSystemSamples: Int
    let bufferedMicSamples: Int
    let currentDelayMs: Int
    let delayHistory: [MeetingAecDelayObservation]
    let delaySkipHistory: [MeetingAecDelaySkip]
}

struct MeetingAecDelayObservation: Codable {
    let delayMs: Int
    let appliedDelayMs: Int
    let score: Double
    let confidence: Double
    let comparedFrames: Int
    let decision: String
    let candidateScores: [MeetingAecDelayCandidateScore]
}

struct MeetingAecDelayCandidateScore: Codable {
    let delayMs: Int
    let score: Double
    let comparedFrames: Int
}

struct MeetingAecDelaySkip: Codable {
    let reason: String
    let micSamplesReceived: Int
    let systemSamplesReceived: Int
    let micHistoryStartSample: Int
    let systemHistoryStartSample: Int
    let comparableEndSample: Int?
    let validCandidateCount: Int
    let missingCandidateCount: Int
    let lowActiveCandidateCount: Int
    let systemWindowSamples: Int
    let systemPeak: Double?
}

final class MeetingSessionDiagnostics {
    struct ChunkStats: Codable {
        let successful: Int
        let empty: Int
        let failed: Int
    }

    struct Summary: Codable {
        let meetingTitle: String
        let startedAt: String
        let endedAt: String
        let durationSeconds: Double
        let systemCapture: SystemAudioCaptureDiagnosticsSnapshot?
        let aec: MeetingAecDiagnosticsSnapshot
        let micChunks: ChunkStats
        let systemChunks: ChunkStats
        let diarizationSegments: Int
        let diarizationSpeakers: Int
        let protectedSystemSegments: Int
        let rawMic: AudioSampleStatsSnapshot?
        let cleanedMicAec: AudioSampleStatsSnapshot?
        let systemAudio: AudioSampleStatsSnapshot?
        let aecDelayEstimate: AecDelayEstimate?
    }

    struct AecDelayEstimate: Codable {
        let bestDelayMs: Int?
        let confidence: Double
        let scores: [DelayScore]
    }

    struct DelayScore: Codable {
        let delayMs: Int
        let score: Double
        let comparedFrames: Int
    }

    private let outputDirectory: URL?
    private let cleanedMicURL: URL?
    private let cleanedMicFile: FileHandle?
    private let lock = OSAllocatedUnfairLock(initialState: CleanedMicState())
    private let enabled: Bool

    private struct CleanedMicState {
        var bytesWritten = 0
        var stats = AudioSampleStats()
        var isClosed = false
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: enabledFlagURL.path)
    }

    private static var enabledFlagURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("MeetingDiagnostics.enabled")
    }

    init(title: String, startedAt: Date) {
        enabled = Self.isEnabled
        guard enabled else {
            outputDirectory = nil
            cleanedMicURL = nil
            cleanedMicFile = nil
            return
        }

        let timestamp = Self.fileTimestamp.string(from: startedAt)
        let safeTitle = Self.safePathComponent(title)
        let runDirectory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("MeetingDiagnostics", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(safeTitle)-\(UUID().uuidString.prefix(8))", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let cleanedURL = runDirectory.appendingPathComponent("cleaned-mic-aec.wav")
            FileManager.default.createFile(atPath: cleanedURL.path, contents: nil)
            let file = FileHandle(forWritingAtPath: cleanedURL.path)
            file?.write(WavWriter.header(dataSize: 0))
            outputDirectory = runDirectory
            cleanedMicURL = cleanedURL
            cleanedMicFile = file
            fputs("[meeting-diagnostics] enabled: \(runDirectory.path)\n", stderr)
        } catch {
            outputDirectory = nil
            cleanedMicURL = nil
            cleanedMicFile = nil
            fputs("[meeting-diagnostics] failed to create diagnostics directory: \(error)\n", stderr)
        }
    }

    func appendCleanedMicSamples(_ samples: [Int16]) {
        guard enabled, !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock { state in
            guard !state.isClosed else { return }
            cleanedMicFile?.write(data)
            state.bytesWritten += data.count
            state.stats.addInt16(samples)
        }
    }

    func writeFinalReport(
        title: String,
        startedAt: Date,
        endedAt: Date,
        rawTranscript: String,
        rawMicURL: URL?,
        systemAudioURL: URL?,
        systemCapture: SystemAudioCaptureDiagnosticsSnapshot?,
        aec: MeetingAecDiagnosticsSnapshot,
        micChunks: MeetingTranscriptChunkHealthSnapshot,
        systemChunks: MeetingTranscriptChunkHealthSnapshot,
        diarizationSegments: [TimedSpeakerSegment]?,
        protectedSystemSegmentCount: Int
    ) {
        guard enabled, let outputDirectory else { return }

        let cleanedMicStats = finalizeCleanedMic()
        let rawMicDiagnosticsURL = outputDirectory.appendingPathComponent("raw-mic-full-session.wav")
        let systemDiagnosticsURL = outputDirectory.appendingPathComponent("system-audio.wav")
        let rawMicStats = copyAudioFileAndMeasure(from: rawMicURL, to: rawMicDiagnosticsURL)
        let systemStats = copyAudioFileAndMeasure(from: systemAudioURL, to: systemDiagnosticsURL)
        let delayEstimate = Self.estimateAecDelay(
            rawMicURL: rawMicDiagnosticsURL,
            systemAudioURL: systemDiagnosticsURL
        )

        writeText(rawTranscript, to: outputDirectory.appendingPathComponent("raw-transcript.txt"))

        let speakerCount = Set((diarizationSegments ?? []).map(\.speakerId)).count
        let summary = Summary(
            meetingTitle: title,
            startedAt: Self.iso8601.string(from: startedAt),
            endedAt: Self.iso8601.string(from: endedAt),
            durationSeconds: max(endedAt.timeIntervalSince(startedAt), 0),
            systemCapture: systemCapture,
            aec: aec,
            micChunks: ChunkStats(
                successful: micChunks.successfulChunkCount,
                empty: micChunks.emptyChunkCount,
                failed: micChunks.failedChunkCount
            ),
            systemChunks: ChunkStats(
                successful: systemChunks.successfulChunkCount,
                empty: systemChunks.emptyChunkCount,
                failed: systemChunks.failedChunkCount
            ),
            diarizationSegments: diarizationSegments?.count ?? 0,
            diarizationSpeakers: speakerCount,
            protectedSystemSegments: protectedSystemSegmentCount,
            rawMic: rawMicStats,
            cleanedMicAec: cleanedMicStats,
            systemAudio: systemStats,
            aecDelayEstimate: delayEstimate
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summary)
            try data.write(
                to: outputDirectory.appendingPathComponent("diagnostics.json"),
                options: Data.WritingOptions.atomic
            )
        } catch {
            fputs("[meeting-diagnostics] failed to write diagnostics.json: \(error)\n", stderr)
        }
    }

    private func finalizeCleanedMic() -> AudioSampleStatsSnapshot? {
        guard let cleanedMicFile else { return nil }
        let finalState = lock.withLock { state -> CleanedMicState in
            state.isClosed = true
            return state
        }
        cleanedMicFile.seek(toFileOffset: 0)
        cleanedMicFile.write(WavWriter.header(dataSize: UInt32(finalState.bytesWritten)))
        cleanedMicFile.closeFile()
        return finalState.stats.snapshot()
    }

    private func copyAudioFileAndMeasure(from sourceURL: URL?, to destinationURL: URL) -> AudioSampleStatsSnapshot? {
        guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return Self.measureInt16Wav(at: destinationURL)
        } catch {
            fputs("[meeting-diagnostics] failed to copy \(sourceURL.path): \(error)\n", stderr)
            return nil
        }
    }

    private func writeText(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fputs("[meeting-diagnostics] failed to write \(url.lastPathComponent): \(error)\n", stderr)
        }
    }

    static func measureInt16Wav(at url: URL) -> AudioSampleStatsSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        var stats = AudioSampleStats()
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var offset = 44
            while offset + 1 < bytes.count {
                let low = UInt16(bytes[offset])
                let high = UInt16(bytes[offset + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                stats.addInt16Sample(sample)
                offset += 2
            }
        }
        return stats.snapshot()
    }

    static func estimateAecDelay(
        rawMicURL: URL,
        systemAudioURL: URL,
        candidateDelaysMs: [Int] = MeetingAecDelayEstimator.defaultCandidateDelaysMs
    ) -> AecDelayEstimate? {
        guard let rawMicSamples = loadInt16WavSamples(at: rawMicURL),
              let systemSamples = loadInt16WavSamples(at: systemAudioURL),
              !rawMicSamples.isEmpty,
              !systemSamples.isEmpty
        else { return nil }

        let frameSize = 320 // 20ms at 16kHz
        let micEnvelope = rmsEnvelope(samples: rawMicSamples, frameSize: frameSize)
        let systemEnvelope = rmsEnvelope(samples: systemSamples, frameSize: frameSize)
        guard !micEnvelope.isEmpty, !systemEnvelope.isEmpty else { return nil }

        let scores = candidateDelaysMs.map { delayMs in
            let delayFrames = max(0, Int(round(Double(delayMs) / 20.0)))
            let result = envelopeCosineSimilarity(
                micEnvelope: micEnvelope,
                systemEnvelope: systemEnvelope,
                delayFrames: delayFrames
            )
            return DelayScore(
                delayMs: delayMs,
                score: result.score,
                comparedFrames: result.comparedFrames
            )
        }

        let best = scores.max { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.comparedFrames < rhs.comparedFrames
            }
            return lhs.score < rhs.score
        }
        let runnerUpScore = scores
            .filter { $0.delayMs != best?.delayMs }
            .map(\.score)
            .max() ?? 0

        return AecDelayEstimate(
            bestDelayMs: (best?.comparedFrames ?? 0) > 0 ? best?.delayMs : nil,
            confidence: max(0, (best?.score ?? 0) - runnerUpScore),
            scores: scores
        )
    }

    private static func loadInt16WavSamples(at url: URL) -> [Int16]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var samples: [Int16] = []
            samples.reserveCapacity((bytes.count - 44) / 2)

            var offset = 44
            while offset + 1 < bytes.count {
                let low = UInt16(bytes[offset])
                let high = UInt16(bytes[offset + 1]) << 8
                samples.append(Int16(bitPattern: high | low))
                offset += 2
            }
            return samples
        }
    }

    private static func rmsEnvelope(samples: [Int16], frameSize: Int) -> [Double] {
        guard frameSize > 0 else { return [] }
        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / frameSize)

        var index = 0
        while index + frameSize <= samples.count {
            var sumSquares = 0.0
            for sample in samples[index..<(index + frameSize)] {
                let value = Double(sample) / 32768.0
                sumSquares += value * value
            }
            envelope.append(sqrt(sumSquares / Double(frameSize)))
            index += frameSize
        }
        return envelope
    }

    private static func envelopeCosineSimilarity(
        micEnvelope: [Double],
        systemEnvelope: [Double],
        delayFrames: Int
    ) -> (score: Double, comparedFrames: Int) {
        guard delayFrames < micEnvelope.count else { return (0, 0) }

        let comparedFrames = min(systemEnvelope.count, micEnvelope.count - delayFrames)
        guard comparedFrames > 0 else { return (0, 0) }

        var dot = 0.0
        var micNorm = 0.0
        var systemNorm = 0.0
        for index in 0..<comparedFrames {
            let mic = micEnvelope[index + delayFrames]
            let system = systemEnvelope[index]
            dot += mic * system
            micNorm += mic * mic
            systemNorm += system * system
        }

        guard micNorm > 0, systemNorm > 0 else { return (0, comparedFrames) }
        return (dot / sqrt(micNorm * systemNorm), comparedFrames)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fileTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func safePathComponent(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = input.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = collapsed.isEmpty ? "Meeting" : String(collapsed.prefix(48))
        return prefix.replacingOccurrences(of: " ", with: "-")
    }
}
