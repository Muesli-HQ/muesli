import Foundation
import MuesliCore

/// The display result for one transcript speaker label.
struct ResolvedSpeakerName: Equatable {
    /// What to render in place of the raw label.
    let display: String
    /// The mic speaker (`You`), kept distinct so bubble alignment stays correct.
    let isUser: Bool
    /// An auto-recognized (not yet user-confirmed) name — UI flags it so the
    /// user knows to verify before trusting/sharing.
    let isAutoRecognized: Bool
}

/// Pure render-time mapping from a stored transcript label to a display name.
///
/// The stored blob always keeps `You` / `Others` / `Speaker N` tokens; this
/// resolver overlays names without mutating the text, so renames are instant and
/// the transcript parser stays unchanged.
enum SpeakerNameResolver {
    static func resolve(
        label: String,
        speakers: [String: MeetingSpeaker],
        userName: String
    ) -> ResolvedSpeakerName {
        if label.localizedCaseInsensitiveCompare("You") == .orderedSame {
            let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ResolvedSpeakerName(display: trimmed.isEmpty ? "You" : trimmed, isUser: true, isAutoRecognized: false)
        }

        // Only auto/confirmed entries apply a name; suggestions render the raw
        // label (the suggestion affordance is shown separately by the UI).
        if let entry = speakers[label],
           entry.matchState == .auto || entry.matchState == .confirmed,
           let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return ResolvedSpeakerName(
                display: name,
                isUser: false,
                isAutoRecognized: entry.matchState == .auto
            )
        }

        return ResolvedSpeakerName(display: label, isUser: false, isAutoRecognized: false)
    }

    /// Convenience: build the label-keyed lookup the resolver expects.
    static func speakerMap(from speakers: [MeetingSpeaker]) -> [String: MeetingSpeaker] {
        Dictionary(speakers.map { ($0.speakerLabel, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether a label is a diarized cluster token (`Speaker N`). Single source of
    /// truth shared by the transcript parser, the rename affordance, and the notes
    /// substitution — a cheap allocation-light check (no per-render regex compile).
    static func isSpeakerClusterLabel(_ label: String) -> Bool {
        guard label.count <= 32 else { return false }
        let parts = label.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Speaker") == .orderedSame,
              !parts[1].isEmpty,
              parts[1].allSatisfy(\.isNumber) else { return false }
        return true
    }
}
