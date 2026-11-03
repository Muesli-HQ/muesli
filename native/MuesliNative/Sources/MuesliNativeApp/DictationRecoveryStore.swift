import Foundation
import MuesliCore

struct FailedDictation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Double
    let modelName: String
    let failureMessage: String
    var partialTranscript: String? = nil
}

/// Called only after a failed attempt or from the recovery UI. Successful
/// dictations never create a recovery directory, copy audio, or write metadata.
/// Uses #677's private, unique recovery folders and preserves the original WAV
/// until every part of the recovery has been saved successfully.
struct DictationRecoveryStore: Sendable {
    let directory: URL

    enum Failure: LocalizedError, Equatable {
        case noCapturedAudio
        case invalidRecording
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .noCapturedAudio: return "The microphone did not capture any audio to recover."
            case .invalidRecording: return "The saved recording is unavailable."
            case .emptyTranscript: return "No text was recognized. The recording is still available."
            }
        }
    }

    func audioURL(for record: FailedDictation) -> URL {
        sessionURL(record.id).appendingPathComponent("audio.wav")
    }

    func save(wavURL: URL, startedAt: Date, durationSeconds: Double,
              modelName: String, failureMessage: String, partialTranscript: String? = nil) throws -> FailedDictation {
        let files = FileManager.default
        let attributes = try files.attributesOfItem(atPath: wavURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.invalidRecording
        }
        // Our recorders write a 44-byte PCM WAV header even when no samples arrive.
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 44 else {
            throw Failure.noCapturedAudio
        }
        let record = FailedDictation(id: UUID(), startedAt: startedAt,
                                    durationSeconds: durationSeconds, modelName: modelName,
                                    failureMessage: failureMessage, partialTranscript: partialTranscript)
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let session = sessionURL(record.id)
        try files.createDirectory(at: session, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        do {
            let audio = audioURL(for: record)
            try files.copyItem(at: wavURL, to: audio)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            if let partialTranscript {
                let transcript = session.appendingPathComponent("transcript.txt")
                try Data(partialTranscript.utf8).write(to: transcript, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
            }
            let metadata = session.appendingPathComponent("failure.json")
            try JSONEncoder().encode(record).write(to: metadata, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            return record
        } catch {
            try? files.removeItem(at: session)
            throw error
        }
    }

    func recordings() throws -> [FailedDictation] {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return [] }
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { session in
                let metadata = session.appendingPathComponent("failure.json")
                guard let id = UUID(uuidString: session.lastPathComponent),
                      (try? files.attributesOfItem(atPath: session.path)[.type]) as? FileAttributeType == .typeDirectory,
                      (try? files.attributesOfItem(atPath: metadata.path)[.type]) as? FileAttributeType == .typeRegular,
                      let data = try? Data(contentsOf: metadata),
                      let record = try? JSONDecoder().decode(FailedDictation.self, from: data),
                      record.id == id,
                      (try? validatedAudioURL(for: record)) != nil else { return nil }
                return record
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func validatedAudioURL(for record: FailedDictation) throws -> URL {
        let files = FileManager.default
        let session = sessionURL(record.id)
        guard try files.attributesOfItem(atPath: session.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidRecording
        }
        let audio = audioURL(for: record)
        let attributes = try files.attributesOfItem(atPath: audio.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 44 else {
            throw Failure.invalidRecording
        }
        return audio
    }

    func discard(_ record: FailedDictation) throws {
        // UUID-derived paths only; never accept a path from persisted metadata.
        let session = sessionURL(record.id)
        guard FileManager.default.fileExists(atPath: session.path) else { return }
        guard try FileManager.default.attributesOfItem(atPath: session.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidRecording
        }
        try FileManager.default.removeItem(at: session)
    }

    func discardAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidRecording
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func sessionURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

enum DictationRecoveryPolicy {
    static func shouldPreserve(after error: Error, taskIsCancelled: Bool,
                               isCurrentSession: Bool, isTestMode: Bool) -> Bool {
        !isTestMode && HostedDictationFallbackPolicy.shouldFallback(
            after: error, taskIsCancelled: taskIsCancelled, isCurrentSession: isCurrentSession
        )
    }
}

enum DictationRecoveryRetry {
    /// Each worker owns its SQLite connection. Lock waits and filesystem work
    /// must not occupy the main actor; only the returned text crosses back.
    @MainActor
    static func persistHistory(record: FailedDictation, text: String, databaseURL: URL,
                               model: DictationModelIdentity? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).insertRecoveredDictation(
                recoveryID: record.id, text: text, durationSeconds: record.durationSeconds,
                startedAt: record.startedAt,
                endedAt: record.startedAt.addingTimeInterval(record.durationSeconds),
                transcriptionModel: model)
        }.value
    }

    /// A retry never opens a microphone or pastes into the foreground app.
    /// Keep the only recovery copy until text is durably saved to history.
    @MainActor
    static func run(
        record: FailedDictation, store: DictationRecoveryStore,
        transcribe: (URL) async throws -> String,
        persist: (String) async throws -> Void
    ) async throws {
        let audio = try await Task.detached { try store.validatedAudioURL(for: record) }.value
        try Task.checkCancellation()
        let text = try await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !text.isEmpty else { throw DictationRecoveryStore.Failure.emptyTranscript }
        try await persist(text)
        // Cancellation during a database wait may arrive after its transaction
        // commits. Keep the archive; its durable retry key prevents duplicates.
        try Task.checkCancellation()
        try await Task.detached { try store.discard(record) }.value
    }
}
