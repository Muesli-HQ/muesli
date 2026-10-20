import Foundation
import MuesliCore

struct MeetingResumeTranscript: Sendable {
    let text: String
    let speakerLabels: [String]
}

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

    static func summaryIsCurrentAfterNoOpResume(
        existingSummaryIsStale: Bool?,
        savedTranscript: String?,
        resumedTranscript: String
    ) -> Bool? {
        guard let existingSummaryIsStale, let savedTranscript else { return nil }
        return !existingSummaryIsStale && savedTranscript == resumedTranscript
    }

    /// Removes revocable automatic names only when structured evidence still
    /// exactly renders this transcript. User-edited text is left untouched.
    static func resumeTranscriptWithoutAutomaticNames(
        _ transcript: String,
        speakerState: MeetingSpeakerState?
    ) -> String {
        transcriptForResume(transcript, speakerState: speakerState).text
    }

    static func transcriptForResume(
        _ transcript: String,
        speakerState: MeetingSpeakerState?
    ) -> MeetingResumeTranscript {
        guard var speakerState, speakerState.isValid, speakerState.render() == transcript else {
            return MeetingResumeTranscript(text: transcript, speakerLabels: [])
        }
        speakerState.removeSelfEvidence()
        speakerState.removeAccessibilityAssignments()
        let labelsInTurns = speakerState.turns.compactMap { speakerState.labels[$0.speaker] }
        let labels = Set((speakerState.renderedPrefixSpeakerLabels ?? []) + labelsInTurns).sorted()
        return MeetingResumeTranscript(text: speakerState.render(), speakerLabels: labels)
    }

    /// Keeps the resumed session's structured evidence while adding the already
    /// sanitized prior transcript as an opaque prefix. This state can still be
    /// revoked and re-rendered against the complete persisted transcript.
    static func speakerStateForResume(
        priorTranscript: String,
        currentTranscript: String,
        currentState: MeetingSpeakerState?,
        priorSpeakerLabels: [String] = []
    ) -> MeetingSpeakerState? {
        guard var state = currentState, state.isValid, !state.turns.isEmpty,
              state.render() == currentTranscript else { return nil }
        let priorIsEmpty = priorTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state.renderedPrefix = priorIsEmpty ? nil : priorTranscript + resumeSeparator
        state.renderedPrefixSpeakerLabels = priorIsEmpty
            ? nil
            : Array(Set(priorSpeakerLabels + (state.renderedPrefixSpeakerLabels ?? []))).sorted()
        guard state.render() == combinedResumeTranscript(prior: priorTranscript, new: currentTranscript) else { return nil }
        return state
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
