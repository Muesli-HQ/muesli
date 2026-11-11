import AppKit
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("MeetingNotificationController")
struct MeetingNotificationControllerTests {
    @Test("a recently muted app cannot supply a cached calendar candidate")
    @MainActor
    func recentlyMutedCandidateIsCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeTestConfigStore(supportDirectory: directory)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: DictationStore(databaseURL: directory.appendingPathComponent("test.db")),
            configStore: store
        )
        let candidate = MeetingCandidate(id: "zoom", platform: .zoom, appName: "Zoom", url: nil,
            evidence: [.audioInputProcess], startedAt: Date(), meetingTitle: nil, sourceBundleID: "us.zoom.xos")
        controller.testingCacheMeetingCandidate(candidate)
        #expect(controller.testingRecentMeetingCandidate() == candidate)
        controller.updateConfig { $0.mutedMeetingDetectionAppBundleIDs = ["us.zoom.xos"] }
        #expect(controller.testingRecentMeetingCandidate() == nil)
        controller.updateConfig { $0.mutedMeetingDetectionAppBundleIDs = [] }
        #expect(controller.testingRecentMeetingCandidate() == nil)
    }

    struct JoinedCallRow: Sendable, CustomTestStringConvertible {
        let toasts: Bool, autoRecord: Bool, hasEvent: Bool, live: Bool
        let action: ScheduledMeetingNotificationPolicy.JoinedCallAction
        var testDescription: String { "toasts=\(toasts) autoRecord=\(autoRecord) event=\(hasEvent) live=\(live) -> \(action)" }
    }

    static let joinedCallRows: [JoinedCallRow] = [
        .init(toasts: true, autoRecord: true, hasEvent: true, live: true, action: .record),
        .init(toasts: true, autoRecord: true, hasEvent: true, live: false, action: .showToast),
        .init(toasts: true, autoRecord: true, hasEvent: false, live: true, action: .showToast),
        .init(toasts: true, autoRecord: true, hasEvent: false, live: false, action: .showToast),
        .init(toasts: true, autoRecord: false, hasEvent: true, live: true, action: .showToast),
        .init(toasts: true, autoRecord: false, hasEvent: true, live: false, action: .showToast),
        .init(toasts: true, autoRecord: false, hasEvent: false, live: true, action: .showToast),
        .init(toasts: true, autoRecord: false, hasEvent: false, live: false, action: .showToast),
        .init(toasts: false, autoRecord: true, hasEvent: true, live: true, action: .record),
        .init(toasts: false, autoRecord: true, hasEvent: true, live: false, action: .ignore),
        .init(toasts: false, autoRecord: true, hasEvent: false, live: true, action: .ignore),
        .init(toasts: false, autoRecord: true, hasEvent: false, live: false, action: .ignore),
        .init(toasts: false, autoRecord: false, hasEvent: true, live: true, action: .ignore),
        .init(toasts: false, autoRecord: false, hasEvent: true, live: false, action: .ignore),
        .init(toasts: false, autoRecord: false, hasEvent: false, live: true, action: .ignore),
        .init(toasts: false, autoRecord: false, hasEvent: false, live: false, action: .ignore),
    ]

    @Test("a call records only with auto-record on, a calendar match and live media, and prompts only with toasts on",
          arguments: joinedCallRows)
    func joinedCallAction(row: JoinedCallRow) {
        #expect(ScheduledMeetingNotificationPolicy.joinedCallAction(
            showsDetection: row.toasts, autoRecordMeetings: row.autoRecord,
            hasCalendarEvent: row.hasEvent, hasLiveMedia: row.live
        ) == row.action)
    }

    @Test("only an audio-input process attributed to the app counts as a live call, not global mic or camera, or a focused URL")
    func liveMediaEvidence() {
        func candidate(_ evidence: Set<MeetingCandidate.Evidence>) -> MeetingCandidate {
            MeetingCandidate(id: "meet", platform: .googleMeet, appName: "Chrome", url: "meet.google.com/aaa-bbbb-ccc",
                evidence: evidence, startedAt: Date(), meetingTitle: nil, sourceBundleID: nil)
        }
        #expect(candidate([.audioInputProcess, .browserURL]).hasLiveMediaEvidence)
        #expect(!candidate([.micActive]).hasLiveMediaEvidence)
        #expect(!candidate([.cameraActive, .micActive, .browserURL]).hasLiveMediaEvidence)
        #expect(!candidate([.browserURL, .foregroundApp, .calendarEvent]).hasLiveMediaEvidence)
        #expect(!candidate([]).hasLiveMediaEvidence)
    }

    @Test("auto-record tries each calendar event once, even when a one-off event is rescheduled")
    func autoRecordAttemptsEachEventOnce() {
        var attempts = AutoRecordAttemptGuard()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func key(_ id: String, series: String? = nil, _ at: Date) -> String {
            CalendarOccurrenceReference(
                provider: .eventKit, calendarID: "cal", eventID: id, seriesID: series, originalStartTime: at
            ).identityKey
        }
        let first = attempts.claim(key("standup", start))
        let rescheduled = attempts.claim(key("standup", start.addingTimeInterval(3_600)))
        let dayOne = attempts.claim(key("daily", series: "s", start))
        let dayTwo = attempts.claim(key("daily", series: "s", start.addingTimeInterval(86_400)))
        let dayOneAgain = attempts.claim(key("daily", series: "s", start))
        let otherEvent = attempts.claim(key("review", start))
        #expect([first, rescheduled, dayOne, dayTwo, dayOneAgain, otherEvent] == [true, false, true, true, false, true])
    }

    @Test("calendar auto-record preserves recordings, asks when a call may be active, and never starts without one")
    func autoRecordConflictDecision() {
        let decision = ScheduledMeetingNotificationPolicy.autoRecordDecision
        #expect(decision(true, true, true) == .keepCurrentRecording)
        #expect(decision(true, false, false) == .keepCurrentRecording)
        #expect(decision(false, true, false) == .askBeforeRecording)
        #expect(decision(false, false, true) == .askBeforeRecording)
        #expect(decision(false, false, nil) == .askBeforeRecording)
        #expect(decision(false, false, false) == .waitForJoin)
        #expect(!ScheduledMeetingNotificationPolicy.shouldNotifyAboutRecordingConflict(
            recordingRoom: "meet.google.com/aaa-bbbb-ccc", scheduledRoom: "meet.google.com/aaa-bbbb-ccc"
        ))
        #expect(ScheduledMeetingNotificationPolicy.shouldNotifyAboutRecordingConflict(
            recordingRoom: nil, scheduledRoom: "meet.google.com/aaa-bbbb-ccc"
        ))
        #expect(ScheduledMeetingNotificationPolicy.shouldNotifyAboutRecordingConflict(
            recordingRoom: "zoom.us/j/123", scheduledRoom: "zoom.us/j/456"
        ))
    }
    @Test("A close callback can install the next notification callback")
    @MainActor
    func closePreservesNextCallback() {
        let controller = MeetingNotificationController()
        var nextClosed = false
        controller.onClose = { controller.onClose = { nextClosed = true } }
        controller.close()
        #expect(controller.onClose != nil)
        controller.close()
        #expect(nextClosed)
    }

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

    @Test("Single-action prompts use available text width")
    @MainActor
    func singleActionPromptsUseAvailableTextWidth() {
        let subtitle = "Still transcribing. Stop if the meeting ended." as NSString
        let subtitleWidth = subtitle.size(withAttributes: [.font: AppFonts.regular(11)]).width
        let cardWidth = MeetingNotificationController.singleActionCardWidth(
            requiredTextWidth: subtitleWidth,
            textX: 14
        )
        let textWidth = MeetingNotificationController.singleActionTextWidth(cardWidth: cardWidth, textX: 14)

        #expect(cardWidth > 344)
        #expect(textWidth >= subtitleWidth)
    }

    @Test("Default join action arms the matching primary button")
    func defaultJoinActionArmsMatchingPrimaryButton() {
        #expect(MeetingJoinDefaultAction.joinAndRecord
            .resolved(hasJoinAndRecord: true, hasJoinOnly: true) == .joinAndRecord)
        #expect(MeetingJoinDefaultAction.joinOnly
            .resolved(hasJoinAndRecord: true, hasJoinOnly: true) == .joinOnly)
        #expect(MeetingJoinDefaultAction.recordOnly
            .resolved(hasJoinAndRecord: true, hasJoinOnly: true) == .recordOnly)
    }

    @Test("Join defaults fall back to transcribe only without a join link")
    func joinDefaultsFallBackToTranscribeOnlyWithoutJoinLink() {
        #expect(MeetingJoinDefaultAction.joinAndRecord
            .resolved(hasJoinAndRecord: false, hasJoinOnly: false) == .recordOnly)
        #expect(MeetingJoinDefaultAction.joinOnly
            .resolved(hasJoinAndRecord: false, hasJoinOnly: false) == .recordOnly)
        #expect(MeetingJoinDefaultAction.joinAndRecord
            .availableAlternatives(hasJoinAndRecord: false, hasJoinOnly: false).isEmpty)
    }

    @Test("Dropdown offers the two actions that are not armed")
    func dropdownOffersTheTwoActionsThatAreNotArmed() {
        #expect(MeetingJoinDefaultAction.joinAndRecord
            .availableAlternatives(hasJoinAndRecord: true, hasJoinOnly: true) == [.joinOnly, .recordOnly])
        #expect(MeetingJoinDefaultAction.recordOnly
            .availableAlternatives(hasJoinAndRecord: true, hasJoinOnly: true) == [.joinAndRecord, .joinOnly])
        #expect(MeetingJoinDefaultAction.joinOnly
            .availableAlternatives(hasJoinAndRecord: true, hasJoinOnly: true) == [.joinAndRecord, .recordOnly])
    }

    @Test("recording switches always offer join and transcribe or transcribe only")
    func switchActionsRespectDefaultWithoutOfferingJoinOnly() {
        for preferred in MeetingJoinDefaultAction.allCases {
            let primary = preferred.resolved(hasJoinAndRecord: true, hasJoinOnly: false)
            let alternatives = preferred.availableAlternatives(hasJoinAndRecord: true, hasJoinOnly: false)
            #expect(Set([primary] + alternatives) == Set([.joinAndRecord, .recordOnly]))
            #expect(!alternatives.contains(.joinOnly))
        }
    }

    @Test("Existing installs keep Join & Transcribe as the default")
    func existingInstallsKeepJoinAndTranscribeAsDefault() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.meetingJoinDefaultAction == .joinAndRecord)
        #expect(MeetingJoinDefaultAction.fallback == .joinAndRecord)
    }

    @Test("Saved default action round-trips through config JSON")
    func savedDefaultActionRoundTripsThroughConfigJSON() throws {
        var config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        config.meetingJoinDefaultAction = .recordOnly

        let encoded = try JSONEncoder().encode(config)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["meeting_join_default_action"] as? String == "record_only")

        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.meetingJoinDefaultAction == .recordOnly)
    }

    @Test("Join action labels say transcribe rather than record")
    func joinActionLabelsSayTranscribeRatherThanRecord() {
        #expect(MeetingJoinDefaultAction.joinAndRecord.buttonLabel == "Join & Transcribe")
        #expect(MeetingJoinDefaultAction.joinOnly.buttonLabel == "Join Only")
        #expect(MeetingJoinDefaultAction.recordOnly.buttonLabel == "Transcribe Only")
    }

    @Test("Every join action label fits the split button")
    @MainActor
    func everyJoinActionLabelFitsSplitButton() {
        for action in MeetingJoinDefaultAction.allCases {
            #expect(
                MeetingNotificationController.splitButtonLabelFits(action.buttonLabel),
                "\(action.buttonLabel) overflows the \(MeetingNotificationController.splitButtonWidth)pt split button"
            )
        }
        for label in ["Stop & Transcribe", "Stop, Join, Record"] {
            #expect(MeetingNotificationController.splitButtonLabelFits(label), "\(label) overflows the split button")
        }
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
