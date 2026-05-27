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
}
