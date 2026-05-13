import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingMediaSessionTracker")
struct MeetingMediaSessionTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        browserMeetings: [BrowserMeetingContext] = [],
        audioInputProcesses: [AudioProcessActivity] = [],
        now: Date
    ) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            micActive: false,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            browserMeetings: browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: "com.google.Chrome",
            now: now
        )
    }

    private func browserURLCandidate(now: Date) -> MeetingCandidate {
        MeetingCandidate(
            id: "googleMeet:meet.google.com/pwm-txwq-txy",
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/pwm-txwq-txy",
            evidence: [.browserURL, .audioInputProcess],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000000"
        )
    }

    private func browserAudioCandidate(now: Date) -> MeetingCandidate {
        MeetingCandidate(
            id: "browser:com.google.Chrome:session:\(Int(now.timeIntervalSince1970))",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:\(Int(now.timeIntervalSince1970))"
        )
    }

    @Test("browser URL and generic browser audio candidates share a stable media session")
    func browserURLAndGenericAudioShareSession() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)

        let first = await tracker.stabilize(
            candidate: browserURLCandidate(now: now),
            snapshot: snapshot(now: now)
        )
        let second = await tracker.stabilize(
            candidate: browserAudioCandidate(now: now.addingTimeInterval(10)),
            snapshot: snapshot(now: now.addingTimeInterval(10))
        )

        #expect(first?.id == "meeting-session:browser:com.google.Chrome:1800000000")
        #expect(second?.id == first?.id)
        #expect(second?.suppressionID == first?.suppressionID)
        #expect(second?.platform == .googleMeet)
        #expect(second?.url == "meet.google.com/pwm-txwq-txy")
        #expect(second?.evidence.contains(.browserURL) == true)
    }

    @Test("browser media session expires after quiet window")
    func browserSessionExpiresAfterQuietWindow() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)

        let first = await tracker.stabilize(
            candidate: browserURLCandidate(now: now),
            snapshot: snapshot(now: now)
        )
        let later = await tracker.stabilize(
            candidate: browserURLCandidate(now: now.addingTimeInterval(45)),
            snapshot: snapshot(now: now.addingTimeInterval(45))
        )

        #expect(first?.id == "meeting-session:browser:com.google.Chrome:1800000000")
        #expect(later?.id == "meeting-session:browser:com.google.Chrome:1800000045")
        #expect(later?.id != first?.id)
    }

    @Test("non-media browser URL candidate keeps original identity")
    func nonMediaBrowserCandidateKeepsOriginalIdentity() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)
        let candidate = MeetingCandidate(
            id: "googleMeet:meet.google.com/pwm-txwq-txy",
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/pwm-txwq-txy",
            evidence: [.browserURL, .foregroundApp],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876
        )

        let result = await tracker.stabilize(
            candidate: candidate,
            snapshot: snapshot(now: now)
        )

        #expect(result?.id == candidate.id)
        #expect(result?.suppressionID == candidate.id)
    }
}
