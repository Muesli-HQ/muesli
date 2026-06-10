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
        let micRecorder: MeetingMicRecorderDiagnosticsSnapshot?
        let micHealth: MeetingMicHealthSnapshot?
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
    private static let maxDiagnosticRuns = 10
    private static let maxDiagnosticBytes = 2 * 1_024 * 1_024 * 1_024

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
        let diagnosticsRoot = AppIdentity.supportDirectoryURL
            .appendingPathComponent("MeetingDiagnostics", isDirectory: true)
        let runDirectory = diagnosticsRoot
            .appendingPathComponent("\(timestamp)-\(safeTitle)-\(UUID().uuidString.prefix(8))", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            Self.pruneOldRuns(in: diagnosticsRoot, preserving: runDirectory)
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
        micRecorder: MeetingMicRecorderDiagnosticsSnapshot?,
        micHealth: MeetingMicHealthSnapshot?,
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
            micRecorder: micRecorder,
            micHealth: micHealth,
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

    private static func pruneOldRuns(in diagnosticsRoot: URL, preserving preservedRun: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: diagnosticsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var runs = contents.compactMap { url -> DiagnosticRun? in
            guard url.standardizedFileURL != preservedRun.standardizedFileURL else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            return DiagnosticRun(
                url: url,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                byteSize: directoryByteSize(url)
            )
        }
        runs.sort { $0.modifiedAt > $1.modifiedAt }

        var retainedCount = 1
        var retainedBytes = directoryByteSize(preservedRun)
        for run in runs {
            let shouldKeep = retainedCount < maxDiagnosticRuns
                && retainedBytes + run.byteSize <= maxDiagnosticBytes
            if shouldKeep {
                retainedCount += 1
                retainedBytes += run.byteSize
            } else {
                try? fileManager.removeItem(at: run.url)
            }
        }
    }

    private struct DiagnosticRun {
        let url: URL
        let modifiedAt: Date
        let byteSize: Int
    }

    private static func directoryByteSize(_ url: URL) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += values?.fileSize ?? 0
        }
        return total
    }

    static func measureInt16Wav(at url: URL) -> AudioSampleStatsSnapshot? {
        guard let wav = loadInt16Wav(at: url) else { return nil }
        var stats = AudioSampleStats()
        stats.addInt16(wav.samples)
        return stats.snapshot()
    }

    static func estimateAecDelay(
        rawMicURL: URL,
        systemAudioURL: URL,
        candidateDelaysMs: [Int] = MeetingAecDelayEstimator.defaultCandidateDelaysMs
    ) -> AecDelayEstimate? {
        guard let rawMic = loadInt16Wav(at: rawMicURL),
              let system = loadInt16Wav(at: systemAudioURL),
              rawMic.sampleRate == 16_000,
              system.sampleRate == 16_000,
              !rawMic.samples.isEmpty,
              !system.samples.isEmpty
        else { return nil }

        let frameSize = 320 // 20ms at 16kHz
        let micEnvelope = rmsEnvelope(samples: rawMic.samples, frameSize: frameSize)
        let systemEnvelope = rmsEnvelope(samples: system.samples, frameSize: frameSize)
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

    private struct Int16WavData {
        let sampleRate: Int
        let samples: [Int16]
    }

    private static func loadInt16Wav(at url: URL) -> Int16WavData? {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else { return nil }
        guard String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE"
        else { return nil }

        var sampleRate: Int?
        var channels: Int?
        var bitsPerSample: Int?
        var audioFormat: Int?
        var dataRange: Range<Int>?
        var offset = 12

        while offset + 8 <= data.count {
            guard let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii),
                  let chunkSize = readUInt32LE(data, at: offset + 4)
            else { return nil }

            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(chunkSize)
            guard payloadEnd <= data.count else { return nil }

            if chunkID == "fmt " {
                guard Int(chunkSize) >= 16,
                      let parsedFormat = readUInt16LE(data, at: payloadStart),
                      let parsedChannels = readUInt16LE(data, at: payloadStart + 2),
                      let parsedSampleRate = readUInt32LE(data, at: payloadStart + 4),
                      let parsedBits = readUInt16LE(data, at: payloadStart + 14)
                else { return nil }
                audioFormat = Int(parsedFormat)
                channels = Int(parsedChannels)
                sampleRate = Int(parsedSampleRate)
                bitsPerSample = Int(parsedBits)
            } else if chunkID == "data" {
                dataRange = payloadStart..<payloadEnd
            }

            offset = payloadEnd + (Int(chunkSize) % 2)
        }

        guard audioFormat == 1,
              bitsPerSample == 16,
              let sampleRate,
              let channelCount = channels,
              channelCount > 0,
              let dataRange
        else { return nil }

        let byteCount = dataRange.count - (dataRange.count % 2)
        var interleaved: [Int16] = []
        interleaved.reserveCapacity(byteCount / 2)

        var sampleOffset = dataRange.lowerBound
        let sampleEnd = dataRange.lowerBound + byteCount
        while sampleOffset + 1 < sampleEnd {
            let low = UInt16(data[sampleOffset])
            let high = UInt16(data[sampleOffset + 1]) << 8
            interleaved.append(Int16(bitPattern: high | low))
            sampleOffset += 2
        }

        let monoSamples: [Int16]
        if channelCount == 1 {
            monoSamples = interleaved
        } else {
            let frameCount = interleaved.count / channelCount
            monoSamples = (0..<frameCount).map { frame in
                var sum = 0
                for channel in 0..<channelCount {
                    sum += Int(interleaved[frame * channelCount + channel])
                }
                return Int16(clamping: sum / channelCount)
            }
        }

        return Int16WavData(sampleRate: sampleRate, samples: monoSamples)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
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
