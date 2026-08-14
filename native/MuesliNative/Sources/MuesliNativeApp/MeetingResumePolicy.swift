import Foundation
import MuesliCore

/// Decides whether a finished meeting may be resumed (reopened to append more
/// recording onto the same meeting row).
///
/// Resume is intentionally age-independent: users may continue transcribing into
/// an older meeting artifact when that is the right product-level grouping.
enum MeetingResumePolicy {
    /// Only finalized meetings can be resumed. Active, processing, note-only, and
    /// failed rows have separate lifecycle actions.
    static func canResume(status: MeetingStatus) -> Bool {
        status == .completed
    }

    /// Separator inserted between the prior transcript and the newly recorded one
    /// when a meeting is resumed (Approach A — concatenate, see the PRD).
    static let resumeSeparator = "\n\n— Resumed —\n\n"

    /// Concatenates the prior transcript with the newly recorded one. If nothing
    /// new was captured (empty/whitespace), the prior transcript is returned
    /// unchanged so a no-op resume never appends a dangling separator.
    static func combinedResumeTranscript(prior: String, new: String) -> String {
        let trimmedPrior = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return prior }
        guard !trimmedPrior.isEmpty else { return new }
        return prior + resumeSeparator + new
    }

    static func hasNewTranscriptContent(prior: String, new: String) -> Bool {
        combinedResumeTranscript(prior: prior, new: new) != prior
    }
}
