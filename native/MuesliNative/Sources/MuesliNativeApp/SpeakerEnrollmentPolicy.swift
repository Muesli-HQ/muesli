import Foundation
import MuesliCore

/// Decides which speaker voiceprints to remember when a meeting's speaker names
/// change.
///
/// Naming a speaker is what teaches Muesli that voice: the diarization cluster's
/// embedding is enrolled under the chosen name so the same person is recognized
/// in later meetings. Clearing the name forgets the voice again, so a mistaken
/// rename never leaves a wrong voiceprint behind.
enum SpeakerEnrollmentPolicy {
    struct Plan: Equatable {
        var enroll: [KnownSpeakerRecord] = []
        var forget: [String] = []
    }

    /// Maps a meeting's clusters and its current rename map onto enrollments and
    /// removals. Clusters without an embedding are skipped: there is no voice to
    /// remember, and enrolling an empty vector would match nothing.
    static func plan(
        speakers: [MeetingSpeakerRecord],
        names: [String: String]
    ) -> Plan {
        var plan = Plan()
        for speaker in speakers where !speaker.embedding.isEmpty {
            let name = names[speaker.label]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty {
                plan.forget.append(speaker.speakerID)
            } else {
                plan.enroll.append(
                    KnownSpeakerRecord(id: speaker.speakerID, name: name, embedding: speaker.embedding)
                )
            }
        }
        return plan
    }
}
