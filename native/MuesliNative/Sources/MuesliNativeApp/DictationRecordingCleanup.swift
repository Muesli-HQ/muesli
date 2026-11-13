import Foundation
import MuesliCore

/// Deletes a stopped WAV unless another owner takes responsibility for retention or recovery.
struct DictationRecordingCleanup {
    let wavURL: URL
    var preserveOriginal = false

    func finish() {
        if !preserveOriginal { try? FileManager.default.removeItem(at: wavURL) }
    }
}

/// Owns a stopped WAV through deferred paste bookkeeping, or a private playback
/// copy for as long as the history player or transcription task needs it.
final class DictationRecordingFile: Sendable {
    let url: URL
    private let cleanupURL: URL

    init(stoppedWAV: URL) {
        url = stoppedWAV
        cleanupURL = stoppedWAV
    }

    init(historyID: Int64, databaseURL: URL) throws {
        let data = try DictationStore(databaseURL: databaseURL).dictationAudio(id: historyID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        cleanupURL = directory
        url = directory.appendingPathComponent("dictation.wav")
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: cleanupURL) }
}
