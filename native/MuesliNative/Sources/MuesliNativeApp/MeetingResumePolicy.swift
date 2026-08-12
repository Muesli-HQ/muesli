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

    /// Combined visual context is prefix-capped so repeated resumes cannot grow
    /// the stored value without bound (each session's drain is already capped
    /// by MeetingScreenContextCollector).
    static let combinedVisualContextLimit = 20_000

    /// Merges the resumed meeting's stored visual context with the context the
    /// resumed session captured, mirroring combinedResumeTranscript: either
    /// side may be missing, and a no-op side never appends a dangling separator.
    /// At the cap, the oldest prior content is dropped first so the resumed
    /// session's context (the freshest) always survives whole.
    static func combinedResumeVisualContext(prior: String?, new: String?) -> String? {
        let trimmedPrior = prior?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedNew = new?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedNew.isEmpty { return trimmedPrior.isEmpty ? nil : prior }
        guard !trimmedPrior.isEmpty, let prior, let new else { return new }
        return String((prior + resumeSeparator + new).suffix(combinedVisualContextLimit))
    }
}
