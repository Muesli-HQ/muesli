import Foundation
import MuesliCore

/// Parent, direct children, and total size for the detail-view follow-up context.
struct MeetingThreadContext {
    let predecessor: MeetingRecord?
    let successors: [MeetingRecord]
    let count: Int
}

/// Decides when a completed meeting can spawn a follow-up meeting and how the
/// new meeting derives from its predecessor (title, carried-forward context).
///
/// A follow-up is a *new* meeting row linked to its predecessor through
/// `follow_up_to_id`, unlike resume, which reopens the same row. A meeting can
/// have multiple follow-ups; related meetings are ordered chronologically.
enum MeetingFollowUpPolicy {
    static let titlePrefix = "Follow-up: "

    /// Follow-ups hang off finalized meetings only, mirroring resume gating.
    static func canStartFollowUp(status: MeetingStatus) -> Bool {
        status == .completed
    }

    /// "Follow-up: <root title>" without stacking prefixes when the predecessor
    /// is itself a follow-up. Matches the bare "Follow-up:" prefix because
    /// trimming can strip the space that follows it.
    static func followUpTitle(from predecessorTitle: String) -> String {
        let barePrefix = titlePrefix.trimmingCharacters(in: .whitespaces)
        var base = predecessorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(barePrefix) {
            base = String(base.dropFirst(barePrefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !base.isEmpty else { return "Follow-up meeting" }
        return titlePrefix + base
    }

    /// Cap carried-forward predecessor notes so a long thread cannot blow up
    /// the summary prompt budget.
    static let maxCarriedNotesLength = 6000

    /// Predecessor notes to seed the follow-up's summary prompt with, or nil
    /// when the predecessor has no structured notes (a raw-transcript fallback
    /// would dump the whole prior transcript into the prompt).
    static func carriedContext(from predecessor: MeetingRecord) -> String? {
        guard predecessor.notesState == .structuredNotes else { return nil }
        return carriedContext(fromPredecessorNotes: predecessor.formattedNotes)
    }

    static func carriedContext(fromPredecessorNotes notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCarriedNotesLength else { return trimmed }
        return String(trimmed.prefix(maxCarriedNotesLength)) + "\n[…previous notes truncated]"
    }
}
