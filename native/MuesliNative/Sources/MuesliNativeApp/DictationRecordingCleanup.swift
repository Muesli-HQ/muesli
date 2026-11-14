import Foundation
import MuesliCore
import os

/// Deletes a stopped WAV unless another owner takes responsibility for retention or recovery.
struct DictationRecordingCleanup {
    let wavURL: URL
    var preserveOriginal = false

    func finish() {
        if !preserveOriginal { try? FileManager.default.removeItem(at: wavURL) }
    }
}

/// Owns a stopped WAV through deferred paste bookkeeping, or references the persistent
/// history WAV for playback or transcription.
final class DictationRecordingFile: Sendable {
    let url: URL
    private let cleanupURL: OSAllocatedUnfairLock<URL?>

    init(stoppedWAV: URL) {
        url = stoppedWAV
        cleanupURL = .init(initialState: stoppedWAV)
    }

    init(historyID: Int64, databaseURL: URL) throws {
        url = try DictationStore(databaseURL: databaseURL).dictationRecordingURL(id: historyID)
        cleanupURL = .init(initialState: nil)
    }

    /// Recovery storage failed. The original file now belongs to the user.
    func keepOriginalForManualRecovery() {
        cleanupURL.withLock { $0 = nil }
    }

    deinit {
        if let url = cleanupURL.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
}
