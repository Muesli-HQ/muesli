import Foundation
import MuesliCore

extension Notification.Name {
    /// Posted with the meeting ID (Int64) as object, or nil when profiles changed globally.
    static let meetingSpeakersDidChange = Notification.Name("MuesliMeetingSpeakersDidChange")
}

/// Named speakers. All database work runs off the main actor. Logs carry counts only:
/// never names, labels, or vectors.
extension MuesliController {
    func startingSpeakerNumberForMeeting(meetingID: Int64) async -> Int {
        guard let priorTranscript = pendingResumePriorTranscript[meetingID] else { return 1 }
        let databaseURL = speakerIdentityDatabaseURL
        do {
            return try await Task.detached(priority: .userInitiated) {
                try DictationStore(databaseURL: databaseURL).nextSpeakerNumber(
                    forMeetingID: meetingID,
                    priorTranscript: priorTranscript
                )
            }.value
        } catch {
            fputs("[speakers] meeting \(meetingID): could not compute speaker offset\n", stderr)
            return 1
        }
    }

    /// Called by `MeetingSession` after diarization. Private meetings (failing closed)
    /// record matches locally but never get names rendered into their transcript.
    func resolveMeetingSpeakers(meetingID: Int64, observations: [MeetingSpeakerObservation]) async -> [String: String] {
        let renderNames = !isMeetingPrivateFailingClosed(id: meetingID)
        let preservingExisting = pendingResumePriorTranscript[meetingID] != nil
        let databaseURL = speakerIdentityDatabaseURL
        do {
            let names = try await Task.detached(priority: .userInitiated) {
                try DictationStore(databaseURL: databaseURL).recordMeetingSpeakers(
                    meetingID: meetingID,
                    observations: observations,
                    renderNames: renderNames,
                    preservingExisting: preservingExisting
                )
            }.value
            fputs("[speakers] meeting \(meetingID): \(observations.count) speakers, \(names.count) recognized\n", stderr)
            return names
        } catch {
            fputs("[speakers] meeting \(meetingID): could not record speakers\n", stderr)
            return [:]
        }
    }

    func meetingSpeakers(meetingID: Int64) async throws -> [MeetingSpeaker] {
        try await onSpeakerStore { try $0.meetingSpeakers(meetingID: meetingID) }
    }

    func speakerProfiles() async throws -> [SpeakerProfileSummary] {
        try await onSpeakerStore { try $0.speakerProfiles() }
    }

    @discardableResult
    func assignMeetingSpeaker(meetingID: Int64, label: String, name: String) async throws -> SpeakerAssignmentResult {
        let result = try await onSpeakerStore { try $0.assignSpeaker(meetingID: meetingID, label: label, name: name) }
        if result.transcriptRewritten { speakerIdentityDidRewriteTranscript() }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: meetingID)
        return result
    }

    func forgetSpeakerVoiceprints(profileID: Int64, sourceMeetingID: Int64?) async throws {
        try await onSpeakerStore { try $0.forgetVoiceprints(profileID: profileID, sourceMeetingID: sourceMeetingID) }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: nil)
    }

    func deleteSpeakerProfile(id: Int64) async throws {
        try await onSpeakerStore { try $0.deleteSpeakerProfile(id: id) }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: nil)
    }

    private func onSpeakerStore<T: Sendable>(_ operation: @escaping @Sendable (DictationStore) throws -> T) async throws -> T {
        let databaseURL = speakerIdentityDatabaseURL
        return try await Task.detached(priority: .userInitiated) {
            try operation(DictationStore(databaseURL: databaseURL))
        }.value
    }
}
