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

    @Test("ignores unrelated browser audio in the same browser")
    func ignoresUnrelatedBrowserAudioInSameBrowser() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let otherTabAudio = MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000999",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000999"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: otherTabAudio, source: source))
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
        #expect(source.hasObservedCandidate == false)
    }

    @Test("refines URL-only source with observed browser source")
    func refinesURLOnlySourceWithObservedBrowserSource() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))

        let refined = source.refined(with: googleMeetCandidate())

        #expect(refined.sourceBundleID == "com.google.Chrome")
        #expect(refined.suppressionID == "browser:com.google.Chrome:session:1800000000")
        #expect(refined.hasObservedCandidate)
    }

    @Test("refinement preserves existing suppression ID when candidate lacks one")
    func refinementPreservesExistingSuppressionIDWhenCandidateLacksOne() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))
        let partialCandidate = MeetingCandidate(
            id: "browser:com.google.Chrome:unknown",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: nil
        )

        let refined = source.refined(with: partialCandidate)

        #expect(refined.suppressionID == "googleMeet:meet.google.com/aaa-bbbb-ccc")
        #expect(refined.hasObservedCandidate)
    }

    @Test("candidate source starts as observed")
    func candidateSourceStartsObserved() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())

        #expect(source.hasObservedCandidate)
    }

    @Test("tracker waits for a recording-time observation before auto-stopping")
    func trackerWaitsForRecordingTimeObservationBeforeAutoStopping() {
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(candidate: googleMeetCandidate()))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shouldStop = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(25),
            gracePeriod: 20
        )

        #expect(!shouldStop)
        #expect(tracker.lastSeenAt == nil)
    }

    @Test("tracker stops after a confirmed recording-time source disappears")
    func trackerStopsAfterConfirmedRecordingTimeSourceDisappears() {
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(candidate: googleMeetCandidate()))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shouldStopWhileVisible = tracker.observe(
            candidate: googleMeetCandidate(),
            now: now,
            gracePeriod: 20
        )
        let shouldStopBeforeGrace = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(19),
            gracePeriod: 20
        )
        let shouldStopAfterGrace = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(21),
            gracePeriod: 20
        )

        #expect(!shouldStopWhileVisible)
        #expect(!shouldStopBeforeGrace)
        #expect(shouldStopAfterGrace)
    }

    @Test("tracker refines URL source before disappearing")
    func trackerRefinesURLSourceBeforeDisappearing() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shouldStopBeforeObservation = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(25),
            gracePeriod: 20
        )
        let shouldStopWhileVisible = tracker.observe(
            candidate: googleMeetCandidate(),
            now: now.addingTimeInterval(30),
            gracePeriod: 20
        )
        let shouldStopAfterGrace = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(51),
            gracePeriod: 20
        )

        #expect(!shouldStopBeforeObservation)
        #expect(!shouldStopWhileVisible)
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        #expect(tracker.source?.hasObservedCandidate == true)
        #expect(shouldStopAfterGrace)
    }

    @Test("tracker starts disappearance grace at recording start after startup observation")
    func trackerStartsGraceAtRecordingStartAfterStartupObservation() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        tracker.observeBeforeRecordingStarted(candidate: googleMeetCandidate())
        tracker.markRecordingStarted(now: now.addingTimeInterval(10))
        let shouldStopBeforeGrace = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(29),
            gracePeriod: 20
        )
        let shouldStopAfterGrace = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(31),
            gracePeriod: 20
        )

        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        #expect(!shouldStopBeforeGrace)
        #expect(shouldStopAfterGrace)
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
