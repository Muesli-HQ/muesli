import Foundation

struct AutoRecordAttemptGuard {
    private var claimedCandidateID: String?

    mutating func claim(_ candidateID: String) -> Bool {
        guard claimedCandidateID != candidateID else { return false }
        claimedCandidateID = candidateID
        return true
    }

    mutating func reset() {
        claimedCandidateID = nil
    }
}

enum ScheduledMeetingNotificationPolicy {
    enum AutoRecordDecision: Equatable {
        case keepCurrentRecording
        case askBeforeRecording
        case waitForJoin
    }

    enum JoinedCallAction: Equatable {
        case record
        case showToast
        case ignore
    }

    static func autoRecordDecision(isRecording: Bool, hasDetectedCall: Bool, hasCallAssertion: Bool?) -> AutoRecordDecision {
        if isRecording { return .keepCurrentRecording }
        if hasDetectedCall || hasCallAssertion != false { return .askBeforeRecording }
        return .waitForJoin
    }

    static func joinedCallAction(
        showsDetection: Bool, autoRecordMeetings: Bool, hasCalendarEvent: Bool, hasLiveMedia: Bool
    ) -> JoinedCallAction {
        if autoRecordMeetings && hasCalendarEvent && hasLiveMedia { return .record }
        return showsDetection ? .showToast : .ignore
    }

    static func shouldNotifyAboutRecordingConflict(recordingRoom: String?, scheduledRoom: String?) -> Bool {
        guard let recordingRoom, let scheduledRoom else { return true }
        return recordingRoom != scheduledRoom
    }

    static let defaultLeadTime: TimeInterval = 0
    static let startPromptGracePeriod: TimeInterval = 90

    static func upcomingCandidates(
        from events: [UnifiedCalendarEvent],
        now: Date,
        hiddenEventIDs: Set<String>,
        leadTime: TimeInterval = defaultLeadTime
    ) -> [UnifiedCalendarEvent] {
        guard leadTime > 0 else {
            return events
                .filter { event in
                    shouldShowStartTimePrompt(
                        for: event,
                        now: now,
                        hiddenEventIDs: hiddenEventIDs
                    )
                }
                .sorted { $0.startDate < $1.startDate }
        }

        let windowEnd = now.addingTimeInterval(leadTime)
        return events
            .filter { event in
                shouldShowUpcomingPrompt(
                    for: event,
                    now: now,
                    windowEnd: windowEnd,
                    hiddenEventIDs: hiddenEventIDs
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    static func autoRecordCandidates(
        from events: [UnifiedCalendarEvent],
        now: Date,
        hiddenEventIDs: Set<String>
    ) -> [UnifiedCalendarEvent] {
        // Auto-record follows the same joinable-meeting eligibility as scheduled prompts,
        // but it always waits until the event start window instead of using reminder lead time.
        events
            .filter { event in
                shouldShowStartTimePrompt(
                    for: event,
                    now: now,
                    hiddenEventIDs: hiddenEventIDs
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    static func shouldShowUpcomingPrompt(
        for event: UnifiedCalendarEvent,
        now: Date,
        windowEnd: Date,
        hiddenEventIDs: Set<String>
    ) -> Bool {
        guard isJoinableMeeting(event, hiddenEventIDs: hiddenEventIDs) else { return false }
        return event.startDate > now && event.startDate <= windowEnd
    }

    static func shouldShowStartTimePrompt(
        for event: UnifiedCalendarEvent,
        now: Date,
        hiddenEventIDs: Set<String>,
        gracePeriod: TimeInterval = startPromptGracePeriod
    ) -> Bool {
        guard isJoinableMeeting(event, hiddenEventIDs: hiddenEventIDs) else { return false }
        return event.startDate <= now && event.startDate > now.addingTimeInterval(-gracePeriod)
    }

    static func shouldShowStartingNowPrompt(meetingURL: URL?) -> Bool {
        meetingURL != nil
    }

    static func startingNowCandidate(
        from events: [UnifiedCalendarEvent],
        eventID: String,
        startDate: Date,
        hiddenEventIDs: Set<String>
    ) -> UnifiedCalendarEvent? {
        events.first { event in
            event.id == eventID
                && Int(event.startDate.timeIntervalSince1970) == Int(startDate.timeIntervalSince1970)
                && isJoinableMeeting(event, hiddenEventIDs: hiddenEventIDs)
        }
    }

    static func isJoinableMeeting(
        _ event: UnifiedCalendarEvent,
        hiddenEventIDs: Set<String>
    ) -> Bool {
        event.meetingURL != nil
            && !event.isAllDay
            && !hiddenEventIDs.contains(event.id)
    }
}

extension MeetingCandidate {
    var hasLiveMediaEvidence: Bool {
        !evidence.isDisjoint(with: [.micActive, .cameraActive, .audioInputProcess])
    }
}
