import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingNotificationController")
struct MeetingNotificationControllerTests {
    @Test("Slack candidates map to the Slack notification platform")
    func slackCandidateMapsToSlackNotificationPlatform() {
        #expect(MeetingPlatform(.slack) == .slack)
    }

    @Test("Unsupported candidate platforms do not get notification icons")
    func unsupportedCandidatePlatformsDoNotMapToNotificationPlatforms() {
        #expect(MeetingPlatform(.whatsApp) == nil)
        #expect(MeetingPlatform(.unknown) == nil)
    }

    @Test("Auto-dismiss without a dedicated handler still fires close cleanup")
    @MainActor
    func autoDismissWithoutHandlerFiresCloseCleanup() {
        #expect(MeetingNotificationController.suppressesCloseCallbackDuringAutoDismiss(hasAutoDismissHandler: false) == false)
    }

    @Test("Detection auto-dismiss owns its cleanup path")
    @MainActor
    func detectionAutoDismissOwnsCleanupPath() {
        #expect(MeetingNotificationController.suppressesCloseCallbackDuringAutoDismiss(hasAutoDismissHandler: true))
    }

    @Test("Auto-dismiss callback is skipped when hover pauses during fade-out")
    @MainActor
    func autoDismissCallbackSkippedWhenPausedDuringFadeOut() {
        #expect(MeetingNotificationController.firesAutoDismissCallbackAfterFade(wasDismissPaused: false))
        #expect(!MeetingNotificationController.firesAutoDismissCallbackAfterFade(wasDismissPaused: true))
    }

    @Test("Completion notification can show during recording but not over prompts")
    func completionNotificationAllowsRecordingButRequiresFreeNotificationSurface() {
        #expect(MeetingCompletionNotificationPolicy.shouldShow(
            hasPresentedMeetingCandidate: false,
            isShowingCalendarNotification: false,
            isMeetingNotificationVisible: false
        ))

        #expect(!MeetingCompletionNotificationPolicy.shouldShow(
            hasPresentedMeetingCandidate: true,
            isShowingCalendarNotification: false,
            isMeetingNotificationVisible: true
        ))

        #expect(!MeetingCompletionNotificationPolicy.shouldShow(
            hasPresentedMeetingCandidate: false,
            isShowingCalendarNotification: true,
            isMeetingNotificationVisible: true
        ))
    }

    @Test("Scheduled meeting prompts require a joinable calendar event")
    func scheduledMeetingPromptsRequireJoinableCalendarEvent() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let windowEnd = now.addingTimeInterval(5 * 60)
        let meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")!

        let joinable = unifiedCalendarEvent(
            id: "joinable",
            startDate: now.addingTimeInterval(60),
            meetingURL: meetingURL
        )
        let lunch = unifiedCalendarEvent(
            id: "lunch",
            startDate: now.addingTimeInterval(60),
            meetingURL: nil
        )
        let allDay = unifiedCalendarEvent(
            id: "all-day",
            startDate: now.addingTimeInterval(60),
            isAllDay: true,
            meetingURL: meetingURL
        )
        let hidden = unifiedCalendarEvent(
            id: "hidden",
            startDate: now.addingTimeInterval(60),
            meetingURL: meetingURL
        )
        let later = unifiedCalendarEvent(
            id: "later",
            startDate: now.addingTimeInterval(10 * 60),
            meetingURL: meetingURL
        )

        #expect(ScheduledMeetingNotificationPolicy.shouldShowUpcomingPrompt(
            for: joinable,
            now: now,
            windowEnd: windowEnd,
            hiddenEventIDs: []
        ))
        #expect(!ScheduledMeetingNotificationPolicy.shouldShowUpcomingPrompt(
            for: lunch,
            now: now,
            windowEnd: windowEnd,
            hiddenEventIDs: []
        ))
        #expect(!ScheduledMeetingNotificationPolicy.shouldShowUpcomingPrompt(
            for: allDay,
            now: now,
            windowEnd: windowEnd,
            hiddenEventIDs: []
        ))
        #expect(!ScheduledMeetingNotificationPolicy.shouldShowUpcomingPrompt(
            for: hidden,
            now: now,
            windowEnd: windowEnd,
            hiddenEventIDs: ["hidden"]
        ))
        #expect(!ScheduledMeetingNotificationPolicy.shouldShowUpcomingPrompt(
            for: later,
            now: now,
            windowEnd: windowEnd,
            hiddenEventIDs: []
        ))
    }

    @Test("Scheduled meeting prompt candidates are sorted")
    func scheduledMeetingPromptCandidatesAreSorted() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let meetingURL = URL(string: "https://us02web.zoom.us/j/123456789")!
        let later = unifiedCalendarEvent(id: "later", startDate: now.addingTimeInterval(240), meetingURL: meetingURL)
        let sooner = unifiedCalendarEvent(id: "sooner", startDate: now.addingTimeInterval(60), meetingURL: meetingURL)
        let hidden = unifiedCalendarEvent(id: "hidden", startDate: now.addingTimeInterval(30), meetingURL: meetingURL)
        let personal = unifiedCalendarEvent(id: "personal", startDate: now.addingTimeInterval(45), meetingURL: nil)

        let candidates = ScheduledMeetingNotificationPolicy.upcomingCandidates(
            from: [later, personal, hidden, sooner],
            now: now,
            hiddenEventIDs: ["hidden"],
            leadTime: 5 * 60
        )

        #expect(candidates.map(\.id) == ["sooner", "later"])
    }

    @Test("Default scheduled prompts wait until meeting start")
    func defaultScheduledPromptsWaitUntilMeetingStart() {
        let now = Date(timeIntervalSinceReferenceDate: 2_500)
        let meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")!
        let beforeStart = unifiedCalendarEvent(id: "before", startDate: now.addingTimeInterval(60), meetingURL: meetingURL)
        let justStarted = unifiedCalendarEvent(id: "started", startDate: now.addingTimeInterval(-30), meetingURL: meetingURL)
        let stale = unifiedCalendarEvent(id: "stale", startDate: now.addingTimeInterval(-120), meetingURL: meetingURL)

        let candidates = ScheduledMeetingNotificationPolicy.upcomingCandidates(
            from: [beforeStart, justStarted, stale],
            now: now,
            hiddenEventIDs: []
        )

        #expect(candidates.map(\.id) == ["started"])
    }

    @Test("Auto-record candidates ignore reminder lead time")
    func autoRecordCandidatesIgnoreReminderLeadTime() {
        let now = Date(timeIntervalSinceReferenceDate: 2_750)
        let meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")!
        let beforeStart = unifiedCalendarEvent(id: "before", startDate: now.addingTimeInterval(5 * 60), meetingURL: meetingURL)
        let justStarted = unifiedCalendarEvent(id: "started", startDate: now.addingTimeInterval(-30), meetingURL: meetingURL)
        let noLink = unifiedCalendarEvent(id: "no-link", startDate: now.addingTimeInterval(-30), meetingURL: nil)

        let reminderCandidates = ScheduledMeetingNotificationPolicy.upcomingCandidates(
            from: [beforeStart, justStarted],
            now: now,
            hiddenEventIDs: [],
            leadTime: 5 * 60
        )
        let autoRecordCandidates = ScheduledMeetingNotificationPolicy.autoRecordCandidates(
            from: [beforeStart, justStarted, noLink],
            now: now,
            hiddenEventIDs: []
        )

        #expect(reminderCandidates.map(\.id) == ["before"])
        #expect(autoRecordCandidates.map(\.id) == ["started"])
    }

    @Test("Starting now scheduled prompts require a join link")
    func startingNowScheduledPromptsRequireJoinLink() {
        #expect(ScheduledMeetingNotificationPolicy.shouldShowStartingNowPrompt(
            meetingURL: URL(string: "https://teams.microsoft.com/l/meetup-join/abc")
        ))
        #expect(!ScheduledMeetingNotificationPolicy.shouldShowStartingNowPrompt(meetingURL: nil))
    }

    @Test("Starting now scheduled prompts revalidate current calendar event policy")
    func startingNowScheduledPromptsRevalidateCurrentCalendarEventPolicy() {
        let startDate = Date(timeIntervalSinceReferenceDate: 3_000)
        let meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")!
        let joinable = unifiedCalendarEvent(id: "meeting", startDate: startDate, meetingURL: meetingURL)
        let hidden = unifiedCalendarEvent(id: "meeting", startDate: startDate, meetingURL: meetingURL)
        let noLink = unifiedCalendarEvent(id: "meeting", startDate: startDate, meetingURL: nil)
        let allDay = unifiedCalendarEvent(id: "meeting", startDate: startDate, isAllDay: true, meetingURL: meetingURL)
        let rescheduled = unifiedCalendarEvent(id: "meeting", startDate: startDate.addingTimeInterval(60), meetingURL: meetingURL)

        #expect(ScheduledMeetingNotificationPolicy.startingNowCandidate(
            from: [joinable],
            eventID: "meeting",
            startDate: startDate,
            hiddenEventIDs: []
        ) == joinable)
        #expect(ScheduledMeetingNotificationPolicy.startingNowCandidate(
            from: [hidden],
            eventID: "meeting",
            startDate: startDate,
            hiddenEventIDs: ["meeting"]
        ) == nil)
        #expect(ScheduledMeetingNotificationPolicy.startingNowCandidate(
            from: [noLink],
            eventID: "meeting",
            startDate: startDate,
            hiddenEventIDs: []
        ) == nil)
        #expect(ScheduledMeetingNotificationPolicy.startingNowCandidate(
            from: [allDay],
            eventID: "meeting",
            startDate: startDate,
            hiddenEventIDs: []
        ) == nil)
        #expect(ScheduledMeetingNotificationPolicy.startingNowCandidate(
            from: [rescheduled],
            eventID: "meeting",
            startDate: startDate,
            hiddenEventIDs: []
        ) == nil)
    }

    private func unifiedCalendarEvent(
        id: String,
        startDate: Date,
        isAllDay: Bool = false,
        meetingURL: URL?
    ) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id,
            title: id,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: isAllDay,
            source: .eventKit,
            meetingURL: meetingURL
        )
    }
}
