import Foundation

enum ScheduledMeetingNotificationPolicy {
    static let defaultLeadTime: TimeInterval = 5 * 60

    static func upcomingCandidates(
        from events: [UnifiedCalendarEvent],
        now: Date,
        hiddenEventIDs: Set<String>,
        leadTime: TimeInterval = defaultLeadTime
    ) -> [UnifiedCalendarEvent] {
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

    static func shouldShowUpcomingPrompt(
        for event: UnifiedCalendarEvent,
        now: Date,
        windowEnd: Date,
        hiddenEventIDs: Set<String>
    ) -> Bool {
        guard isJoinableMeeting(event, hiddenEventIDs: hiddenEventIDs) else { return false }
        return event.startDate > now && event.startDate <= windowEnd
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
