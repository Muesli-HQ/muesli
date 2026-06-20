import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingCandidateResolver")
struct MeetingCandidateResolverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func resolver() -> MeetingCandidateResolver {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = "com.muesli.app"
        return resolver
    }

    private func snapshot(
        micActive: Bool = true,
        cameraActive: Bool = true,
        calendarEvent: CalendarEventContext? = nil,
        runningApps: [RunningAppInfo] = [],
        browserMeetings: [BrowserMeetingContext] = [],
        audioInputProcesses: [AudioProcessActivity] = [],
        foregroundBundleID: String? = nil,
        now: Date? = nil
    ) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            micActive: micActive,
            cameraActive: cameraActive,
            calendarEvent: calendarEvent,
            runningApps: runningApps,
            browserMeetings: browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: foregroundBundleID,
            now: now ?? self.now
        )
    }

    @Test("Chrome Meet active beats background WhatsApp")
    func chromeMeetBeatsBackgroundWhatsApp() {
        let candidate = resolver().resolve(snapshot(
            runningApps: [
                RunningAppInfo(bundleID: "net.whatsapp.WhatsApp", isActive: false),
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.appName == "Chrome")
    }

    @Test("Chrome Meet audio input beats background WhatsApp")
    func chromeMeetAudioInputBeatsBackgroundWhatsApp() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "net.whatsapp.WhatsApp", isActive: false),
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 1234,
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.appName == "Chrome")
        #expect(candidate?.sourcePID == 1234)
        #expect(candidate?.evidence.contains(.audioInputProcess) == true)
    }

    @Test("Meet URL with browser output-only helper does not claim audio input attribution")
    func meetURLWithBrowserOutputOnlyHelperDoesNotClaimAudioInput() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "com.google.Chrome.helper",
                    appName: "Google Chrome Helper",
                    isRunningInput: false,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.sourcePID == 1234)
        #expect(candidate?.evidence.contains(.audioInputProcess) == false)
        #expect(candidate?.suppressionID == candidate?.id)
    }

    @Test("Chrome Meet audio input resolves after transient foreground loss")
    func chromeMeetAudioInputResolvesAfterForegroundLoss() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: false),
                RunningAppInfo(bundleID: "com.granola.app", isActive: true),
            ],
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: false
                ),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "com.google.Chrome.helper",
                    appName: "Google Chrome Helper",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.granola.app"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.sourceBundleID == "com.google.Chrome")
        #expect(candidate?.sourcePID == 9876)
        #expect(candidate?.evidence.contains(.audioInputProcess) == true)
        #expect(candidate?.evidence.contains(.foregroundApp) == false)
    }

    @Test("Chrome URL and media fallback share suppression session")
    func chromeURLAndMediaFallbackShareSuppressionSession() {
        let resolver = resolver()
        let urlCandidate = resolver.resolve(snapshot(
            micActive: false,
            cameraActive: false,
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "com.google.Chrome.helper",
                    appName: "Google Chrome Helper",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.google.Chrome",
            now: now
        ))

        let mediaCandidate = resolver.resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "com.google.Chrome.helper",
                    appName: "Google Chrome Helper",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.google.Chrome",
            now: now.addingTimeInterval(5)
        ))

        #expect(urlCandidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(mediaCandidate?.id == "browser:com.google.Chrome:session:1800000000")
        #expect(urlCandidate?.suppressionID == "browser:com.google.Chrome:session:1800000000")
        #expect(mediaCandidate?.suppressionID == urlCandidate?.suppressionID)
    }

    @Test("Chrome audio input resolves without URL after foreground loss")
    func chromeAudioInputResolvesWithoutURLAfterForegroundLoss() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: false),
                RunningAppInfo(bundleID: "com.granola.app", isActive: true),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "com.google.Chrome.helper",
                    appName: "Google Chrome Helper",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.granola.app"
        ))

        #expect(candidate?.id == "browser:com.google.Chrome:session:1800000000")
        #expect(candidate?.suppressionID == candidate?.id)
        #expect(candidate?.platform == .unknown)
        #expect(candidate?.subtitle == "Chrome")
        #expect(candidate?.appName == "Chrome")
        #expect(candidate?.sourceBundleID == "com.google.Chrome")
        #expect(candidate?.sourcePID == 9876)
        #expect(candidate?.evidence.contains(.audioInputProcess) == true)
        #expect(candidate?.evidence.contains(.foregroundApp) == false)
    }

    @Test("Chrome audio input without URL beats background WhatsApp")
    func chromeAudioInputWithoutURLBeatsBackgroundWhatsApp() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "net.whatsapp.WhatsApp", isActive: false),
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "com.google.Chrome.helper",
                    appName: "Google Chrome Helper",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "browser:com.google.Chrome:session:1800000000")
        #expect(candidate?.platform == .unknown)
        #expect(candidate?.subtitle == "Chrome")
        #expect(candidate?.appName == "Chrome")
        #expect(candidate?.sourceBundleID == "com.google.Chrome")
        #expect(candidate?.evidence.contains(.foregroundApp) == true)
    }

    @Test("foreground browser with global mic activity does not resolve without URL or input attribution")
    func foregroundBrowserWithGlobalMicDoesNotResolve() {
        let candidate = resolver().resolve(snapshot(
            micActive: true,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "company.thebrowser.Browser", isActive: true),
            ],
            browserMeetings: [],
            audioInputProcesses: [],
            foregroundBundleID: "company.thebrowser.Browser"
        ))

        #expect(candidate == nil)
    }

    @Test("browser output-only process does not resolve without URL")
    func browserOutputOnlyProcessDoesNotResolve() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 9876,
                    bundleID: "company.thebrowser.Browser.helper",
                    appName: "Arc Helper",
                    isRunningInput: false,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "company.thebrowser.Browser"
        ))

        #expect(candidate == nil)
    }

    @Test("dedicated app output-only process does not resolve without URL")
    func dedicatedAppOutputOnlyProcessDoesNotResolve() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: true),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 4321,
                    bundleID: "us.zoom.xos",
                    appName: "Zoom",
                    isRunningInput: false,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "us.zoom.xos"
        ))

        #expect(candidate == nil)
    }

    @Test("calendar plus output-only app process does not resolve without input activity")
    func calendarPlusOutputOnlyAppProcessDoesNotResolve() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt-zoom", title: "Team sync"),
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: true),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 4321,
                    bundleID: "us.zoom.xos",
                    appName: "Zoom",
                    isRunningInput: false,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "us.zoom.xos"
        ))

        #expect(candidate == nil)
    }

    @Test("synthetic browser audio PID is not exposed as source PID")
    func syntheticBrowserAudioPIDIsNotExposedAsSourcePID() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 0,
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "browser:com.google.Chrome:session:1800000000")
        #expect(candidate?.sourcePID == nil)
    }

    @Test("background Meet URL without browser audio does not steal foreground app detection")
    func backgroundMeetURLWithoutBrowserAudioDoesNotStealForegroundAppDetection() {
        let candidate = resolver().resolve(snapshot(
            micActive: true,
            cameraActive: true,
            runningApps: [
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: false),
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: true),
            ],
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: false
                ),
            ],
            foregroundBundleID: "us.zoom.xos"
        ))

        #expect(candidate?.id == "app:us.zoom.xos")
        #expect(candidate?.platform == .zoom)
        #expect(candidate?.appName == "Zoom")
    }

    @Test("focused Meet URL is eligible before mic flips")
    func focusedMeetURLIsEligibleBeforeMicFlips() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.sourceBundleID == "com.google.Chrome")
    }

    @Test("Teams active audio input resolves to Teams")
    func teamsActiveAudioInputResolvesToTeams() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 4321,
                    bundleID: "com.microsoft.teams2",
                    appName: "Microsoft Teams",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ]
        ))

        #expect(candidate?.id == "app:com.microsoft.teams2:session:1800000000")
        #expect(candidate?.suppressionID == candidate?.id)
        #expect(candidate?.platform == .teams)
        #expect(candidate?.appName == "Microsoft Teams")
        #expect(candidate?.sourcePID == 4321)
    }

    @Test("Slack running plus global mic activity does not resolve")
    func slackRunningPlusGlobalMicDoesNotResolve() {
        let candidate = resolver().resolve(snapshot(
            micActive: true,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "com.tinyspeck.slackmacgap", isActive: true),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap"
        ))

        #expect(candidate == nil)
    }

    @Test("Slack input-only process does not resolve")
    func slackInputOnlyProcessDoesNotResolve() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap"
        ))

        #expect(candidate == nil)
    }

    @Test("Slack full-duplex process resolves to Slack")
    func slackFullDuplexProcessResolves() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap"
        ))

        #expect(candidate?.id == "app:com.tinyspeck.slackmacgap:session:1800000000")
        #expect(candidate?.suppressionID == candidate?.id)
        #expect(candidate?.platform == .slack)
        #expect(candidate?.appName == "Slack")
        #expect(candidate?.sourcePID == 6789)
    }

    @Test("Slack audio session identity is stable while audio remains active")
    func slackAudioSessionIdentityIsStableWhileActive() {
        let resolver = resolver()
        let first = resolver.resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap",
            now: now
        ))

        let second = resolver.resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap",
            now: now.addingTimeInterval(5)
        ))

        #expect(first?.id == second?.id)
        #expect(second?.id == "app:com.tinyspeck.slackmacgap:session:1800000000")
    }

    @Test("Slack audio session identity resets after idle gap")
    func slackAudioSessionIdentityResetsAfterIdleGap() {
        let resolver = resolver()
        let first = resolver.resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap",
            now: now
        ))

        let second = resolver.resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap",
            now: now.addingTimeInterval(11)
        ))

        #expect(first?.id == "app:com.tinyspeck.slackmacgap:session:1800000000")
        #expect(second?.id == "app:com.tinyspeck.slackmacgap:session:1800000011")
        #expect(first?.id != second?.id)
    }

    @Test("WhatsApp input-only process remains eligible")
    func whatsAppInputOnlyProcessRemainsEligible() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 2468,
                    bundleID: "net.whatsapp.WhatsApp",
                    appName: "WhatsApp",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "net.whatsapp.WhatsApp"
        ))

        #expect(candidate?.id == "app:net.whatsapp.WhatsApp:session:1800000000")
        #expect(candidate?.suppressionID == candidate?.id)
        #expect(candidate?.platform == .whatsApp)
        #expect(candidate?.appName == "WhatsApp")
        #expect(candidate?.sourcePID == 2468)
    }

    @Test("calendar fallback does not label Slack without attributed audio")
    func calendarFallbackDoesNotLabelSlackWithoutAudio() {
        let candidate = resolver().resolve(snapshot(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt-slack", title: "Team sync"),
            runningApps: [
                RunningAppInfo(bundleID: "com.tinyspeck.slackmacgap", isActive: true),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap"
        ))

        #expect(candidate?.id == "cal:evt-slack")
        #expect(candidate?.platform == .unknown)
        #expect(candidate?.appName == "Meeting")
        #expect(candidate?.meetingTitle == "Team sync")
        #expect(candidate?.sourceBundleID == nil)
    }

    @Test("calendar audio candidate suppresses by app audio session")
    func calendarAudioCandidateSuppressesByAppAudioSession() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt-slack", title: "Team sync"),
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 6789,
                    bundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    isRunningInput: true,
                    isRunningOutput: true
                ),
            ],
            foregroundBundleID: "com.tinyspeck.slackmacgap"
        ))

        #expect(candidate?.id == "cal:evt-slack")
        #expect(candidate?.suppressionID == "app:com.tinyspeck.slackmacgap:session:1800000000")
        #expect(candidate?.platform == .slack)
    }

    @Test("different Meet URLs are different candidates")
    func differentMeetURLsAreDifferentCandidates() {
        let first = resolver().resolve(snapshot(browserMeetings: [
            BrowserMeetingContext(
                bundleID: "com.google.Chrome",
                appName: "Chrome",
                url: "meet.google.com/aaa-bbbb-ccc",
                normalizedID: "googleMeet:meet.google.com/aaa-bbbb-ccc",
                platform: .googleMeet,
                isFocused: true
            ),
        ]))

        let second = resolver().resolve(snapshot(browserMeetings: [
            BrowserMeetingContext(
                bundleID: "com.google.Chrome",
                appName: "Chrome",
                url: "meet.google.com/ddd-eeee-fff",
                normalizedID: "googleMeet:meet.google.com/ddd-eeee-fff",
                platform: .googleMeet,
                isFocused: true
            ),
        ]))

        #expect(first?.id != second?.id)
    }

    @Test("URL normalizer extracts stable Google Meet identity")
    func googleMeetURLNormalization() {
        let normalized = MeetingURLNormalizer.normalize("https://meet.google.com/pwm-txwq-txy?authuser=0")

        #expect(normalized?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(normalized?.url == "meet.google.com/pwm-txwq-txy")
        #expect(normalized?.platform == .googleMeet)
    }

    @Test("URL normalizer rejects Google Meet landing pages")
    func googleMeetURLNormalizationRejectsLandingPages() {
        #expect(MeetingURLNormalizer.normalize("https://meet.google.com/landing") == nil)
        #expect(MeetingURLNormalizer.normalize("https://meet.google.com/") == nil)
    }
}
