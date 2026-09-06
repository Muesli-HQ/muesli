import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting auto-stop policy")
struct MeetingAutoStopPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let room = "meet.google.com/aaa-bbbb-ccc"

    private func candidate(
        id: String = "room-a", url: String? = "meet.google.com/aaa-bbbb-ccc",
        bundle: String? = "com.google.Chrome", media: Bool = true,
        suppressionID: String? = "session-a"
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id, platform: .googleMeet, appName: "Meeting", url: url,
            evidence: media ? [.audioInputProcess] : [.browserURL],
            startedAt: now, meetingTitle: nil, sourceBundleID: bundle,
            suppressionID: suppressionID
        )
    }

    @Test("room identity wins over browser attribution and shared suppression IDs")
    func roomMatching() {
        let source = MeetingAutoStopSource(candidate: candidate())
        let cases: [(MeetingCandidate, Bool)] = [
            (candidate(), true),
            (candidate(id: "calendar-wrapped", suppressionID: "calendar"), true),
            (candidate(id: "audio-fallback", url: nil), true),
            (candidate(id: "new-session", url: nil, suppressionID: "new"), true),
            (candidate(id: "helper", url: nil, bundle: "com.google.Chrome.helper", suppressionID: "new"), true),
            (candidate(id: "foreground", url: nil, media: false, suppressionID: "new"), false),
            (candidate(id: "safari", url: nil, bundle: "com.apple.Safari", suppressionID: "new"), false),
            (candidate(id: "unattributed", url: nil, bundle: nil, suppressionID: "new"), false),
            (candidate(id: "room-b", url: "meet.google.com/zzz-yyyy-xxx", suppressionID: "new"), false),
            // Even a reused browser session or candidate ID cannot override a conflicting URL.
            (candidate(url: "meet.google.com/zzz-yyyy-xxx"), false)
        ]
        for (observed, expected) in cases {
            #expect(MeetingAutoStopPolicy.matches(candidate: observed, source: source) == expected)
        }
    }

    @Test("native source survives new helper/session identity, but not another app")
    func nativeMatching() {
        let source = MeetingAutoStopSource(candidate: candidate(url: nil, bundle: "com.microsoft.teams2"))
        #expect(MeetingAutoStopPolicy.matches(
            candidate: candidate(id: "new", url: nil, bundle: "com.microsoft.teams2.helper", suppressionID: "new"), source: source
        ))
        #expect(!MeetingAutoStopPolicy.matches(
            candidate: candidate(id: "new", url: nil, bundle: "us.zoom.xos", suppressionID: "new"), source: source
        ))
    }

    @Test("URL-only sources need observation and retain identity during refinement")
    func refinement() throws {
        let url = try #require(URL(string: "https://\(room)?authuser=0"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))
        #expect(source.candidateID == "googleMeet:\(room)")
        #expect(source.normalizedURL == room && !source.hasObservedCandidate)
        #expect(!MeetingAutoStopPolicy.matches(candidate: candidate(id: "fallback", url: nil), source: source))
        let refined = source.refined(with: candidate())
        #expect(refined.sourceBundleID == "com.google.Chrome" && refined.hasObservedCandidate)
        #expect(refined.suppressionID == "session-a")
        #expect(refined.normalizedURL == room)
        let partial = source.refined(with: candidate(id: "partial", url: nil, suppressionID: nil))
        #expect(partial.suppressionID == source.suppressionID)
        #expect(MeetingAutoStopSource(candidate: candidate()).hasObservedCandidate)
    }

    @Test("only source-backed origins enable auto-stop", arguments: [
        MeetingRecordingStartOrigin.manual, .detectedPrompt, .calendarAutoRecord,
        .scheduledMeetingPrompt, .joinAndRecord
    ])
    func startOrigin(origin: MeetingRecordingStartOrigin) {
        let explicit = MeetingAutoStopSource(candidate: candidate())
        let recent = MeetingAutoStopSource(candidate: candidate(id: "recent", url: nil))
        let enabled = origin != .manual
        #expect(origin.enablesMeetingAutoStop == enabled)
        #expect(origin.signalLossResponse == (enabled ? .autoStopAfterWarning : .none))
        #expect(origin.signalLossSource(explicitSource: explicit, recentSource: recent) == (enabled ? explicit : nil))
        #expect(origin.signalLossSource(explicitSource: nil, recentSource: recent) == (enabled ? recent : nil))
    }

    @Test("source recovery reopens prompts unless the user dismissed them", arguments: [false, true])
    func promptLifetime(dismissed: Bool) {
        var state = MeetingSignalLossPromptState()
        #expect(state.canPresentPrompt)
        state.markPromptPresented()
        #expect(!state.canPresentPrompt)
        if dismissed { state.markDismissedByUser() }
        state.markSourceRecovered()
        #expect(state.canPresentPrompt == !dismissed)
        state.resetForRecording()
        #expect(state.canPresentPrompt)
    }

    @Test("unobserved source cannot auto-stop; confirmed source uses disappearance grace")
    func disappearance() throws {
        var tracker = MeetingAutoStopTracker()
        let url = try #require(URL(string: "https://\(room)"))
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        let shouldStop1 = tracker.observe(candidate: nil, now: now, gracePeriod: 20)
        #expect(!shouldStop1)
        #expect(tracker.lastSeenAt == nil)
        let shouldStop2 = tracker.observe(candidate: candidate(), now: now, gracePeriod: 20)
        #expect(!shouldStop2)
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        #expect(tracker.source?.hasObservedCandidate == true)
        let shouldStop3 = tracker.observe(candidate: nil, now: now.addingTimeInterval(19), gracePeriod: 20)
        #expect(!shouldStop3)
        let shouldStop4 = tracker.observe(candidate: nil, now: now.addingTimeInterval(21), gracePeriod: 20)
        #expect(shouldStop4)
        tracker.disarm()
        #expect(!tracker.isArmed && tracker.lastSeenAt == nil)
    }

    @Test("media fallback extends grace, but a different known room does not")
    func fallbackGrace() {
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(candidate: candidate()))
        let shouldStop5 = tracker.observe(candidate: candidate(), now: now, gracePeriod: 20)
        #expect(!shouldStop5)
        let shouldStop6 = tracker.observe(candidate: candidate(id: "fallback", url: nil, suppressionID: "new"),
                                now: now.addingTimeInterval(30), gracePeriod: 20)
        #expect(!shouldStop6)
        let shouldStop7 = tracker.observe(candidate: nil, now: now.addingTimeInterval(49), gracePeriod: 20)
        #expect(!shouldStop7)
        let shouldStop8 = tracker.observe(candidate: candidate(id: "room-b", url: "meet.google.com/zzz-yyyy-xxx"),
                               now: now.addingTimeInterval(51), gracePeriod: 20)
        #expect(shouldStop8)
    }

    @Test("startup observation starts grace at recording start, not preparation")
    func preparationGrace() throws {
        var tracker = MeetingAutoStopTracker()
        let url = try #require(URL(string: "https://\(room)"))
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        tracker.observeBeforeRecordingStarted(candidate: candidate())
        tracker.markRecordingStarted(now: now.addingTimeInterval(10))
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        let shouldStop9 = tracker.observe(candidate: nil, now: now.addingTimeInterval(29), gracePeriod: 20)
        #expect(!shouldStop9)
        let shouldStop10 = tracker.observe(candidate: nil, now: now.addingTimeInterval(31), gracePeriod: 20)
        #expect(shouldStop10)
    }
}
