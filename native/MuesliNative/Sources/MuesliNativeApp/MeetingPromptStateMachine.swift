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
    }

    let action: Action
    let candidate: MeetingCandidate?
    let reason: Reason
}

final class MeetingPromptStateMachine {
    private(set) var visiblePromptID: String?
    private var userDismissedSuppressionIDs: Set<String> = []
    private var autoDismissedSuppressionIDs: [String: Date] = [:]
    private var lastCandidateID: String?
    private let candidateStabilityDelay: TimeInterval
    private let browserAutoDismissCooldown: TimeInterval
    private var pendingCandidateID: String?
    private var pendingCandidateFirstSeenAt: Date?

    init(candidateStabilityDelay: TimeInterval = 3, browserAutoDismissCooldown: TimeInterval = 120) {
        self.candidateStabilityDelay = candidateStabilityDelay
        self.browserAutoDismissCooldown = browserAutoDismissCooldown
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
