import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting auto-stop policy")
struct MeetingAutoStopPolicyTests {
    @Test("matches the original browser meeting candidate")
    func matchesOriginalBrowserMeetingCandidate() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())

        #expect(MeetingAutoStopPolicy.matches(
            candidate: googleMeetCandidate(),
            source: source
        ))
    }

    @Test("matches calendar-wrapped candidate by normalized URL")
    func matchesCalendarWrappedCandidateByURL() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let calendarCandidate = MeetingCandidate(
            id: "cal:event-1:googleMeet:meet.google.com/aaa-bbbb-ccc",
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/aaa-bbbb-ccc",
            evidence: [.browserURL, .calendarEvent],
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingTitle: "Team sync",
            sourceBundleID: "com.google.Chrome",
            sourcePID: 1234
        )

        #expect(MeetingAutoStopPolicy.matches(candidate: calendarCandidate, source: source))
    }

    @Test("matches browser audio fallback by suppression session")
    func matchesBrowserAudioFallbackBySuppressionSession() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let audioFallback = MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000000",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000000"
        )

        #expect(MeetingAutoStopPolicy.matches(candidate: audioFallback, source: source))
    }

    @Test("ignores unrelated calendar-only activity")
    func ignoresUnrelatedCalendarOnlyActivity() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let calendarOnly = MeetingCandidate(
            id: "cal:event-2",
            platform: .unknown,
            appName: "Meeting",
            url: nil,
            evidence: [.calendarEvent, .micActive],
            startedAt: Date(timeIntervalSince1970: 1_800_000_010),
            meetingTitle: "Later meeting"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: calendarOnly, source: source))
    }

    @Test("creates source from supported meeting URL")
    func createsSourceFromSupportedMeetingURL() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc?authuser=0"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))

        #expect(source.candidateID == "googleMeet:meet.google.com/aaa-bbbb-ccc")
        #expect(source.normalizedURL == "meet.google.com/aaa-bbbb-ccc")
    }

    @Test("refines URL-only source with observed browser source")
    func refinesURLOnlySourceWithObservedBrowserSource() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))

        let refined = source.refined(with: googleMeetCandidate())

        #expect(refined.sourceBundleID == "com.google.Chrome")
        #expect(refined.suppressionID == "browser:com.google.Chrome:session:1800000000")
    }

    private func googleMeetCandidate() -> MeetingCandidate {
        MeetingCandidate(
            id: "googleMeet:meet.google.com/aaa-bbbb-ccc",
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/aaa-bbbb-ccc",
            evidence: [.browserURL, .audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 1234,
            suppressionID: "browser:com.google.Chrome:session:1800000000"
        )
    }
}
