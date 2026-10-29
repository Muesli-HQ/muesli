import AVFoundation
import Foundation
import os

/// Local-only recovery metadata stored beside retained audio until database
/// finalization succeeds. No transcript or meeting title is duplicated here.
struct MeetingRecordingRecoveryReference: Codable {
    let meetingID: Int64
    let startTime: String
    let databasePath: String

    static let suffix = ".recovery.json"

    static func url(for recording: URL) -> URL {
        URL(fileURLWithPath: recording.path + suffix)
    }

    func write(beside recording: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(for: recording), options: .atomic)
    }
}

enum MeetingRecordingFileFormat: String, CaseIterable, Sendable {
    case m4a
    case wav

    var displayName: String {
        switch self {
        case .m4a:
            return "M4A (AAC, smaller)"
        case .wav:
            return "WAV (lossless)"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    static func resolved(_ rawValue: String) -> MeetingRecordingFileFormat {
        MeetingRecordingFileFormat(rawValue: rawValue) ?? .m4a
    }
}

struct MeetingRecordingStopResult {
    let recordingURL: URL?
    let error: Error?
}

final class MeetingRecordingWriter {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var pendingMic: [Int16] = []
        var pendingSystem: [Int16] = []
        var firstFrame: Int64?
        var writeFailure: Error?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let synchronize: (FileHandle) throws -> Void

    init(destination: URL? = nil, synchronize: @escaping (FileHandle) throws -> Void = { try $0.synchronize() }) throws {
        self.synchronize = synchronize
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = destination ?? tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open retained meeting recording file for writing."]
            )
        }
        try fileHandle.write(contentsOf: WavWriter.header(dataSize: 0))
        lock.withLock {
            $0 = State(fileHandle: fileHandle, fileURL: fileURL)
        }
    }

    /// Incremental microphone-only path; meeting mixing retains its existing defaults.
    func appendMicrophone(_ samples: [Int16], startFrame: Int64) throws {
        try lock.withLock { state in
            guard let handle = state.fileHandle else { throw ScreenVideoRecorder.error("Narration writer is closed") }
            if let failure = state.writeFailure { throw failure }
            guard !samples.isEmpty else { return }
            if state.firstFrame == nil { state.firstFrame = startFrame }
            let position = startFrame - state.firstFrame!
            let written = Int64(state.bytesWritten / 2)
            let overlap = Int(max(0, written - position))
            guard overlap < samples.count else { return }
            do {
                var gap = max(0, position - written)
                guard gap <= 16_000 * 600 else { throw ScreenVideoRecorder.error("Invalid narration clock gap") }
                while gap > 0 {
                    let count = Int(min(gap, 16_000))
                    try handle.write(contentsOf: Data(count: count * 2))
                    state.bytesWritten += count * 2; gap -= Int64(count)
                }
                let block = Array(samples.dropFirst(overlap))
                try block.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
                state.bytesWritten += block.count * 2
            } catch { state.writeFailure = error; throw error }
        }
    }

    func finishMicrophone() throws -> URL? {
        try lock.withLock { state in
            guard let result = closeFile(state: &state) else { return nil }
            if let failure = result.failure { throw failure }
            return result.bytes > 0 ? result.url : nil
        }
    }

    func appendMic(_ samples: [Int16]) {
        append(samples, toMic: true)
    }

    func appendSystem(_ samples: [Int16]) {
        append(samples, toMic: false)
    }

    func stopRecording() -> MeetingRecordingStopResult {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
            let result = closeFile(state: &state)
            guard let result else { return MeetingRecordingStopResult(recordingURL: nil, error: nil) }
            if result.bytes == 0 {
                try? FileManager.default.removeItem(at: result.url)
                return MeetingRecordingStopResult(recordingURL: nil, error: result.failure)
            }
            return MeetingRecordingStopResult(recordingURL: result.url, error: result.failure)
        }
    }

    func stop() -> URL? {
        stopRecording().recordingURL
    }

    private func closeFile(state: inout State) -> (url: URL, bytes: Int, failure: Error?)? {
        guard let handle = state.fileHandle, let url = state.fileURL else { return nil }
        defer { state = State() }
        var failure: Error?
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WavWriter.header(dataSize: UInt32(state.bytesWritten)))
            try synchronize(handle)
        } catch {
            failure = error
        }
        do {
            try handle.close()
        } catch {
            failure = failure ?? error
        }
        return (url, state.bytesWritten, failure ?? state.writeFailure)
    }

    func markPauseBoundary() {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
        }
    }

    func cancel() {
        let tempURL = lock.withLock { state -> URL? in
            state.fileHandle?.closeFile()
            let fileURL = state.fileURL
            state = State()
            return fileURL
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    static func persistTemporaryRecordingAsync(
        from tempURL: URL,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) async throws -> URL {
        _ = try WavWriter.repairIncrementalWAV(at: tempURL)
        guard let source = try? AVAudioFile(forReading: tempURL),
              source.length > 0,
              source.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not validate the retained meeting WAV file."]
            )
        }

        let recordingsDirectory = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = recordingsDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).\(fileFormat.fileExtension)"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        switch fileFormat {
        case .m4a:
            do {
                try await transcodeWAVToM4AAsync(sourceURL: tempURL, destinationURL: destinationURL)
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        case .wav:
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        return destinationURL
    }

    private func append(_ samples: [Int16], toMic: Bool) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            if toMic {
                state.pendingMic.append(contentsOf: samples)
            } else {
                state.pendingSystem.append(contentsOf: samples)
            }
            writeMixedSamples(state: &state, flushAll: false)
        }
    }

    private func writeMixedSamples(state: inout State, flushAll: Bool) {
        let availableCount = flushAll
            ? max(state.pendingMic.count, state.pendingSystem.count)
            : min(state.pendingMic.count, state.pendingSystem.count)
        guard availableCount > 0 else { return }

        let mixedSamples = Self.mix(
            mic: Array(state.pendingMic.prefix(availableCount)),
            system: Array(state.pendingSystem.prefix(availableCount))
        )
        state.pendingMic.removeFirst(min(availableCount, state.pendingMic.count))
        state.pendingSystem.removeFirst(min(availableCount, state.pendingSystem.count))

        let pcmData = mixedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        state.fileHandle?.write(pcmData)
        state.bytesWritten += pcmData.count
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }

    private static func mix(mic: [Int16], system: [Int16]) -> [Int16] {
        let maxCount = max(mic.count, system.count)
        var output = [Int16]()
        output.reserveCapacity(maxCount)

        for index in 0..<maxCount {
            let hasMic = index < mic.count
            let hasSystem = index < system.count
            let micValue = hasMic ? Int(mic[index]) : 0
            let systemValue = hasSystem ? Int(system[index]) : 0
            let contributors = (hasMic ? 1 : 0) + (hasSystem ? 1 : 0)
            let averaged = contributors == 0 ? 0 : (micValue + systemValue) / contributors
            output.append(Int16(clamping: averaged))
        }

        return output
    }

    private static func transcodeWAVToM4AAsync(sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create M4A export session for meeting recording."]
            )
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        let exportSessionBox = ExportSessionBox(exportSession)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                guard exportSessionBox.session.status == .completed else {
                    continuation.resume(throwing: exportSessionBox.session.error ?? NSError(
                        domain: "MeetingRecordingWriter",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not export meeting recording as M4A."]
                    ))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

}
