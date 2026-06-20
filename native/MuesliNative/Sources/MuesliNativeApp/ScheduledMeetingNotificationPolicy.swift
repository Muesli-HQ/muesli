import Foundation

enum ScheduledMeetingNotificationPolicy {
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
