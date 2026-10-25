import CryptoKit
import Foundation
import MuesliCore

/// Downloads fingerprints only. Local meeting content is never sent to find a match.
@MainActor
enum MeetingSharingReconciliation {
    private static var run: Task<Void, Error>?

    static func reconcile(meetings: [MeetingRecord]) async throws {
        guard let token = PlusPreviewClient.readToken() else { return }
        if let run { return try await run.value }
        let task = Task { @MainActor in
            let response = try await PlusPreviewClient.call("reconcile", token: token)
            guard let notes = response["notes"] as? [[String: Any]] else {
                throw PlusPreviewClient.Failure(status: 0, message: "Could not check previously shared notes.")
            }
            let local = meetings.map { meeting in
                let summary = meeting.status == .noteOnly || meeting.usesImportedManualNotes
                    ? meeting.manualNotes : meeting.formattedNotes
                return (
                    key: "\(meeting.id)-\(meeting.startTime)",
                    title: digest(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)),
                    summary: digest(summary),
                    transcript: digest(meeting.rawTranscript)
                )
            }
            var matches: [String: [MeetingSharingReceipt]] = [:]
            for note in notes {
                guard let id = note["id"] as? String,
                      id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      let titleHash = note["titleHash"] as? String,
                      let summaryHash = note["summaryHash"] as? String,
                      let recipients = note["recipients"] as? [String],
                      let expiresAt = note["expiresAt"] as? Double,
                      expiresAt > Date().timeIntervalSince1970 else { continue }
                let transcriptHash = note["transcriptHash"] as? String
                // Without a transcript, require a nonempty summary; never match title alone.
                guard transcriptHash != nil || note["hasSummary"] as? Bool == true else { continue }
                let candidates = local.filter {
                    $0.title == titleHash && $0.summary == summaryHash
                        && (transcriptHash == nil || $0.transcript == transcriptHash)
                }
                guard candidates.count == 1,
                      let url = URL(string: "https://notes.muesli.works/n/" + id) else { continue }
                matches[candidates[0].key, default: []].append(MeetingSharingReceipt(
                    url: url, recipients: recipients, expiresAt: Date(timeIntervalSince1970: expiresAt)))
            }
            try Task.checkCancellation()
            for (key, candidates) in matches {
                // Multiple cloud copies are ambiguous; preserve existing explicit associations.
                let storageKey = "plus-preview.share." + key
                guard candidates.count == 1, UserDefaults.standard.data(forKey: storageKey) == nil else { continue }
                UserDefaults.standard.set(try JSONEncoder().encode(candidates[0]), forKey: storageKey)
            }
        }
        run = task
        do { try await task.value } catch { run = nil; throw error }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
