import Foundation

enum ScheduledMeetingNotificationPolicy {
    static let defaultLeadTime: TimeInterval = 0
    static let startPromptGracePeriod: TimeInterval = 90

    /// How long after an event's start auto-record will still claim it. Wider
    /// than `startPromptGracePeriod` so a wake/poll that is delayed (e.g. by
    /// App Nap or a wake-from-sleep) can still start the recording instead of
    /// silently missing the meeting.
    static let autoRecordCatchUpWindow: TimeInterval = 5 * 60

    /// Only events starting within this horizon get a pre-scheduled wake timer.
    /// Covers a full day of meetings in a single scheduling pass; reconciled on
    /// every calendar refresh.
    static let autoRecordWakeHorizon: TimeInterval = 18 * 60 * 60

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
        // but it always waits until the event start window instead of using reminder lead time,
        // and uses a wider catch-up window so a delayed trigger can still claim the meeting.
        events
            .filter { event in
                shouldAutoRecordNow(
                    for: event,
                    now: now,
                    hiddenEventIDs: hiddenEventIDs
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Upcoming joinable events that should each get a pre-scheduled wake timer
    /// fired at their start time. Excludes events already in progress/past — the
    /// catch-up poll handles those.
    static func autoRecordWakeCandidates(
        from events: [UnifiedCalendarEvent],
        now: Date,
        hiddenEventIDs: Set<String>,
        horizon: TimeInterval = autoRecordWakeHorizon
    ) -> [UnifiedCalendarEvent] {
        let windowEnd = now.addingTimeInterval(horizon)
        return events
            .filter { event in
                isJoinableMeeting(event, hiddenEventIDs: hiddenEventIDs)
                    && event.startDate > now
                    && event.startDate <= windowEnd
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// True when an event is currently within the auto-record catch-up window:
    /// it has started (or starts now), is still ongoing, and started no longer
    /// ago than `autoRecordCatchUpWindow`.
    static func shouldAutoRecordNow(
        for event: UnifiedCalendarEvent,
        now: Date,
        hiddenEventIDs: Set<String>,
        catchUpWindow: TimeInterval = autoRecordCatchUpWindow
    ) -> Bool {
        guard isJoinableMeeting(event, hiddenEventIDs: hiddenEventIDs) else { return false }
        return event.startDate <= now
            && event.startDate >= now.addingTimeInterval(-catchUpWindow)
            && event.endDate > now
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
