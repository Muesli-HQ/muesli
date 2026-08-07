import Foundation

struct MeetingPromptVisibility {
    let isVisible: Bool
    let currentPromptID: String?
    let shownAt: Date?
}

struct MeetingPromptDecision: Equatable {
    enum Action: Equatable {
        case show
        case hide
        case none
    }

    enum Reason: Equatable {
        case eligible
        case noCandidate
        case disabled
        case calendarNotificationVisible
        case recording
        case promptAlreadyVisible
        case candidatePending
        case autoDismissedSuppression
        case userDismissedSuppression
        case recordingStartedSuppression
    }

    let action: Action
    let candidate: MeetingCandidate?
    let reason: Reason
}

final class MeetingPromptStateMachine {
    private(set) var visiblePromptID: String?
    private var userDismissedSuppressionIDs: Set<String> = []
    // Media-session IDs are unique for each continuous call and intentionally
    // remain consumed for this app process. Evicting them on a timer or count
    // could re-prompt a long-running meeting; app restart is the cleanup bound,
    // matching the existing user-dismissed suppression lifetime.
    private var recordingStartedSuppressionIDs: Set<String> = []
    private var autoDismissedSuppressionIDs: [String: Date] = [:]
    private var lastCandidateID: String?
    private let candidateStabilityDelay: TimeInterval
    private let browserAutoDismissCooldown: TimeInterval
    /// How long a calendar-only candidate stays suppressed after the user starts recording it.
    /// Long enough to outlast a stop then re-detect cycle, short enough that a later occurrence
    /// of a recurring event still prompts. See markRecordingStarted.
    private let calendarRestartCooldown: TimeInterval
    private var pendingCandidateID: String?
    private var pendingCandidateFirstSeenAt: Date?

    init(
        candidateStabilityDelay: TimeInterval = 3,
        browserAutoDismissCooldown: TimeInterval = 120,
        calendarRestartCooldown: TimeInterval = 15 * 60
    ) {
        self.candidateStabilityDelay = candidateStabilityDelay
        self.browserAutoDismissCooldown = browserAutoDismissCooldown
        self.calendarRestartCooldown = calendarRestartCooldown
    }

    func evaluate(
        candidate: MeetingCandidate?,
        detectionEnabled: Bool,
        isRecording: Bool,
        isStartingRecording: Bool,
        isCalendarNotificationVisible: Bool,
        visibility: MeetingPromptVisibility,
        now: Date
    ) -> MeetingPromptDecision {
        expireAutoDismissSuppressions(now: now)
        reconcileVisibility(visibility)

        guard detectionEnabled else {
            resetPendingCandidate()
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: nil, reason: .disabled)
                : MeetingPromptDecision(action: .hide, candidate: nil, reason: .disabled)
        }

        guard !isRecording, !isStartingRecording else {
            resetPendingCandidate()
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: candidate, reason: .recording)
                : MeetingPromptDecision(action: .hide, candidate: candidate, reason: .recording)
        }

        guard !isCalendarNotificationVisible else {
            resetPendingCandidate()
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: candidate, reason: .calendarNotificationVisible)
                : MeetingPromptDecision(action: .hide, candidate: candidate, reason: .calendarNotificationVisible)
        }

        guard let candidate else {
            lastCandidateID = nil
            resetPendingCandidate()
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: nil, reason: .noCandidate)
                : MeetingPromptDecision(action: .hide, candidate: nil, reason: .noCandidate)
        }

        if candidate.id != lastCandidateID {
            lastCandidateID = candidate.id
        }

        if userDismissedSuppressionIDs.contains(candidate.suppressionID) {
            resetPendingCandidate()
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .userDismissedSuppression)
        }

        if recordingStartedSuppressionIDs.contains(candidate.suppressionID) {
            resetPendingCandidate()
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .recordingStartedSuppression)
        }

        if autoDismissedSuppressionIDs.keys.contains(candidate.suppressionID) {
            resetPendingCandidate()
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .autoDismissedSuppression)
        }

        if visiblePromptID == candidate.id {
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .promptAlreadyVisible)
        }

        guard candidateHasBeenStable(candidate, now: now) else {
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .candidatePending)
        }

        return MeetingPromptDecision(action: .show, candidate: candidate, reason: .eligible)
    }

    func markShown(_ candidate: MeetingCandidate) {
        visiblePromptID = candidate.id
        lastCandidateID = candidate.id
        resetPendingCandidate()
    }

    func markAutoDismissed(_ candidate: MeetingCandidate, now: Date = Date()) {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
        lastCandidateID = candidate.id
        autoDismissedSuppressionIDs[candidate.suppressionID] = autoDismissExpiry(for: candidate, now: now)
        resetPendingCandidate()
    }

    func markUserDismissed(_ candidate: MeetingCandidate) {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
        userDismissedSuppressionIDs.insert(candidate.suppressionID)
        autoDismissedSuppressionIDs.removeValue(forKey: candidate.suppressionID)
        resetPendingCandidate()
    }

    @discardableResult
    func markRecordingStarted(_ candidate: MeetingCandidate, now: Date = Date()) -> Bool {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
        lastCandidateID = candidate.id
        // Calendar-only candidates keep their raw "cal:<eventID>" id and used to record no
        // suppression at all, so accepting the prompt suppressed nothing and the identical
        // event re-prompted as soon as the recording stopped.
        //
        // They get an EXPIRING suppression rather than joining the permanent set: unlike a
        // media-session id, a calendar id is not guaranteed unique per occurrence, so
        // suppressing it for the life of the process could silently skip tomorrow's instance
        // of a recurring meeting. The cooldown only has to outlast the stop/re-detect loop.
        if candidate.suppressionID.hasPrefix("cal:") {
            let inserted = autoDismissedSuppressionIDs
                .updateValue(now.addingTimeInterval(calendarRestartCooldown),
                             forKey: candidate.suppressionID) == nil
            userDismissedSuppressionIDs.remove(candidate.suppressionID)
            resetPendingCandidate()
            return inserted
        }

        guard candidate.suppressionID.hasPrefix("meeting-session:") else {
            resetPendingCandidate()
            return false
        }
        let inserted = recordingStartedSuppressionIDs.insert(candidate.suppressionID).inserted
        userDismissedSuppressionIDs.remove(candidate.suppressionID)
        autoDismissedSuppressionIDs.removeValue(forKey: candidate.suppressionID)
        resetPendingCandidate()
        return inserted
    }

    func markClosed(_ candidate: MeetingCandidate) {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
    }

    func resetVisiblePrompt() {
        visiblePromptID = nil
        resetPendingCandidate()
    }

    private func candidateHasBeenStable(_ candidate: MeetingCandidate, now: Date) -> Bool {
        guard candidateStabilityDelay > 0 else { return true }
        guard pendingCandidateID == candidate.id else {
            pendingCandidateID = candidate.id
            pendingCandidateFirstSeenAt = now
            return false
        }
        let firstSeen = pendingCandidateFirstSeenAt ?? now
        pendingCandidateFirstSeenAt = firstSeen
        return now.timeIntervalSince(firstSeen) >= candidateStabilityDelay
    }

    private func resetPendingCandidate() {
        pendingCandidateID = nil
        pendingCandidateFirstSeenAt = nil
    }

    private func reconcileVisibility(_ visibility: MeetingPromptVisibility) {
        if visibility.isVisible {
            visiblePromptID = visibility.currentPromptID
        } else if visiblePromptID == visibility.currentPromptID || visibility.currentPromptID == nil {
            visiblePromptID = nil
        }
    }

    private func autoDismissExpiry(for candidate: MeetingCandidate, now: Date) -> Date {
        guard !candidate.suppressionID.hasPrefix("meeting-session:") else { return .distantFuture }
        guard candidate.evidence.contains(.browserURL) else { return .distantFuture }
        return now.addingTimeInterval(browserAutoDismissCooldown)
    }

    private func expireAutoDismissSuppressions(now: Date) {
        autoDismissedSuppressionIDs = autoDismissedSuppressionIDs.filter { _, expiry in
            return expiry > now
        }
    }
}
