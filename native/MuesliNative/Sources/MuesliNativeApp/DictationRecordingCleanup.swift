import Foundation

/// The existing temporary-file deletion on success and cancellation. Ownership
/// changes only in the final failure handler, before backup IO begins.
struct DictationRecordingCleanup {
    let wavURL: URL
    var preserveOriginal = false

    func finish() {
        if !preserveOriginal { try? FileManager.default.removeItem(at: wavURL) }
    }
}
