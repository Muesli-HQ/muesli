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

    @Test("dedicated app source still matches after its media session ID rotates")
    func matchesDedicatedAppAfterSessionRotation() {
        let source = MeetingAutoStopSource(candidate: teamsCandidate())
        // MeetingMediaSessionTracker mints a fresh session ID once its quiet
        // window lapses, so a call that briefly stops reporting microphone input
        // reappears under a different ID. A dedicated app has no meeting URL to
        // fall back on, so without app identity the source can never re-match and
        // the still-running meeting is torn down.
        let afterRotation = MeetingCandidate(
            id: "app:com.microsoft.teams2:session:1800000045",
            platform: .teams,
            appName: "Teams",
            url: nil,
            evidence: [.audioInputProcess, .dedicatedApp],
            startedAt: Date(timeIntervalSince1970: 1_800_000_045),
            meetingTitle: nil,
            sourceBundleID: "com.microsoft.teams2",
            sourcePID: 4321,
            suppressionID: "app:com.microsoft.teams2:session:1800000045"
        )

        #expect(MeetingAutoStopPolicy.matches(candidate: afterRotation, source: source))
    }

    @Test("ignores a different meeting app than the tracked source")
    func ignoresDifferentDedicatedApp() {
        let source = MeetingAutoStopSource(candidate: teamsCandidate())
        let zoom = MeetingCandidate(
            id: "app:us.zoom.xos:session:1800000045",
            platform: .zoom,
            appName: "Zoom",
            url: nil,
            evidence: [.audioInputProcess, .dedicatedApp],
            startedAt: Date(timeIntervalSince1970: 1_800_000_045),
            meetingTitle: nil,
            sourceBundleID: "us.zoom.xos",
            sourcePID: 555,
            suppressionID: "app:us.zoom.xos:session:1800000045"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: zoom, source: source))
    }

    @Test("app identity fallback does not apply to browsers")
    func ignoresUnrelatedBrowserAudioWhenSourceHasNoURL() {
        // A browser-audio-only source also has no URL, but one browser hosts many
        // unrelated tabs, so its bundle ID is not a meeting identity.
        let browserAudioSource = MeetingAutoStopSource(candidate: MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000000",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 1234,
            suppressionID: "browser:com.google.Chrome:session:1800000000"
        ))
        let otherTabAudio = MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000999",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_999),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000999"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: otherTabAudio, source: browserAudioSource))
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

    @Test("manual start origin does not track meeting signal loss")
    func manualStartOriginDoesNotTrackMeetingSignalLoss() {
        let explicitSource = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let recentSource = MeetingAutoStopSource(candidate: teamsCandidate())

        let resolvedSource = MeetingRecordingStartOrigin.manual.signalLossSource(
            explicitSource: explicitSource,
            recentSource: recentSource
        )

        #expect(!MeetingRecordingStartOrigin.manual.enablesMeetingAutoStop)
        #expect(MeetingRecordingStartOrigin.manual.signalLossResponse == .none)
        #expect(resolvedSource == nil)
        #expect(MeetingRecordingStartOrigin.manual.signalLossSource(
            explicitSource: nil,
            recentSource: recentSource
        ) == nil)
    }

    @Test("source-backed start origins can auto-stop after warning")
    func sourceBackedStartOriginsCanAutoStopAfterWarning() {
        let explicitSource = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let recentSource = MeetingAutoStopSource(candidate: teamsCandidate())
        let origins: [MeetingRecordingStartOrigin] = [
            .detectedPrompt,
            .calendarAutoRecord,
            .scheduledMeetingPrompt,
            .joinAndRecord,
        ]

        for origin in origins {
            #expect(origin.enablesMeetingAutoStop)
            #expect(origin.signalLossResponse == .autoStopAfterWarning)
            #expect(origin.signalLossSource(explicitSource: explicitSource, recentSource: recentSource) == explicitSource)
            #expect(origin.signalLossSource(explicitSource: nil, recentSource: recentSource) == recentSource)
        }
    }

    @Test("signal loss prompt can reappear after source recovery when not dismissed")
    func signalLossPromptCanReappearAfterSourceRecoveryWhenNotDismissed() {
        var state = MeetingSignalLossPromptState()

        #expect(state.canPresentPrompt)
        state.markPromptPresented()
        #expect(!state.canPresentPrompt)

        state.markSourceRecovered()
        #expect(state.canPresentPrompt)
    }

    @Test("user dismissed signal loss prompt stays suppressed for recording")
    func userDismissedSignalLossPromptStaysSuppressedForRecording() {
        var state = MeetingSignalLossPromptState()

        state.markPromptPresented()
        state.markDismissedByUser()
        state.markSourceRecovered()

        #expect(!state.canPresentPrompt)

        state.resetForRecording()
        #expect(state.canPresentPrompt)
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

    @Test("keeps matching a calendar meeting after every observed identity changes")
    func matchesCalendarMeetingAfterObservedIdentityChanges() throws {
        let armed = try #require(joinAndRecordSource())
        let focusedTab = focusedTabCandidate()

        #expect(MeetingAutoStopPolicy.matches(candidate: focusedTab, source: armed))

        // Leaving the call's tab drops the room URL, and a browser audio
        // session that lapses past its idle timeout mints a fresh id. Neither
        // the candidate id, the suppression id nor the URL survives that, so
        // the calendar event is the only identity left to match on.
        let refined = armed.refined(with: focusedTab)
        #expect(MeetingAutoStopPolicy.matches(
            candidate: backgroundedTabCandidate(),
            source: refined
        ))
    }

    @Test("does not auto-stop a calendar meeting whose observed identity changed")
    func doesNotAutoStopCalendarMeetingAfterObservedIdentityChanges() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: try #require(joinAndRecordSource()))
        tracker.observeBeforeRecordingStarted(candidate: focusedTabCandidate())
        tracker.markRecordingStarted(now: startedAt)

        let shouldStop = tracker.observe(
            candidate: backgroundedTabCandidate(),
            now: startedAt.addingTimeInterval(120),
            gracePeriod: 20
        )

        #expect(!shouldStop)
    }

    @Test("still auto-stops once the calendar meeting's audio is gone")
    func autoStopsWhenCalendarMeetingCandidateDisappears() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: try #require(joinAndRecordSource()))
        tracker.observeBeforeRecordingStarted(candidate: focusedTabCandidate())
        tracker.markRecordingStarted(now: startedAt)

        let shouldStop = tracker.observe(
            candidate: nil,
            now: startedAt.addingTimeInterval(120),
            gracePeriod: 20
        )

        #expect(shouldStop)
    }

    @Test("ignores a candidate for a different calendar event")
    func ignoresDifferentCalendarEvent() throws {
        let refined = try #require(joinAndRecordSource()).refined(with: focusedTabCandidate())
        let otherMeeting = MeetingCandidate(
            id: "cal:event-2",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess, .calendarEvent],
            startedAt: Date(timeIntervalSince1970: 1_800_000_120),
            meetingTitle: "Something else",
            sourceBundleID: "com.google.Chrome",
            sourcePID: 4242,
            suppressionID: "browser:com.google.Chrome:session:1800000120",
            calendarEventID: "event-2"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: otherMeeting, source: refined))
    }

    @Test("a calendar placeholder with no meeting media does not hold a recording open")
    func ignoresCalendarCandidateWithoutMeetingMedia() throws {
        let refined = try #require(joinAndRecordSource()).refined(with: focusedTabCandidate())
        // `resolve` attributes any media activity to the current calendar event,
        // and its last fallback returns a bare `cal:<id>` with no meeting app.
        // A reminder or placeholder plus unrelated mic use — a dictation tool —
        // would otherwise keep the recording alive for the event's whole duration.
        let placeholder = MeetingCandidate(
            id: "cal:event-1",
            platform: .unknown,
            appName: "Meeting",
            url: nil,
            evidence: [.micActive, .calendarEvent],
            startedAt: Date(timeIntervalSince1970: 1_800_000_120),
            meetingTitle: "Hold: write review",
            sourceBundleID: nil,
            sourcePID: nil,
            suppressionID: "cal:event-1",
            calendarEventID: "event-1"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: placeholder, source: refined))
    }

    @Test("the same calendar event still matches once meeting audio is attributed")
    func matchesCalendarCandidateWithAttributedAudio() throws {
        let refined = try #require(joinAndRecordSource()).refined(with: focusedTabCandidate())
        // Negative control for the guard above: identical event, but now the
        // meeting app actually holds audio, so this is a real call.
        let realCall = MeetingCandidate(
            id: "cal:event-1",
            platform: .zoom,
            appName: "Zoom",
            url: nil,
            evidence: [.micActive, .calendarEvent, .audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_120),
            meetingTitle: "Weekly sync",
            sourceBundleID: "us.zoom.xos",
            sourcePID: 4321,
            suppressionID: "app:us.zoom.xos:session:1800000120",
            calendarEventID: "event-1"
        )

        #expect(MeetingAutoStopPolicy.matches(candidate: realCall, source: refined))
    }

    @Test("ignores an uncorrelated candidate when the source has a calendar event")
    func ignoresCandidateWithoutCalendarEvent() throws {
        let refined = try #require(joinAndRecordSource()).refined(with: focusedTabCandidate())
        let unrelated = MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000120",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_120),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 4242,
            suppressionID: "browser:com.google.Chrome:session:1800000120"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: unrelated, source: refined))
    }

    /// "Join & Record" arms auto-stop from the calendar event's join URL alone,
    /// so the source starts with no bundle id and no calendar id of its own.
    private func joinAndRecordSource() -> MeetingAutoStopSource? {
        URL(string: "https://meet.google.com/aaa-bbbb-ccc")
            .flatMap(MeetingAutoStopSource.init(meetingURL:))
    }

    private func focusedTabCandidate() -> MeetingCandidate {
        MeetingCandidate(
            id: "googleMeet:meet.google.com/aaa-bbbb-ccc",
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/aaa-bbbb-ccc",
            evidence: [.browserURL, .audioInputProcess, .calendarEvent],
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingTitle: "Team sync",
            sourceBundleID: "com.google.Chrome",
            sourcePID: 1234,
            suppressionID: "browser:com.google.Chrome:session:1800000000",
            calendarEventID: "event-1"
        )
    }

    private func backgroundedTabCandidate() -> MeetingCandidate {
        MeetingCandidate(
            id: "cal:event-1",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess, .calendarEvent],
            startedAt: Date(timeIntervalSince1970: 1_800_000_120),
            meetingTitle: "Team sync",
            sourceBundleID: "com.google.Chrome",
            sourcePID: 1234,
            suppressionID: "browser:com.google.Chrome:session:1800000120",
            calendarEventID: "event-1"
        )
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

    private func teamsCandidate() -> MeetingCandidate {
        MeetingCandidate(
            id: "app:com.microsoft.teams2:session:1800000000",
            platform: .teams,
            appName: "Teams",
            url: nil,
            evidence: [.audioInputProcess, .dedicatedApp],
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingTitle: nil,
            sourceBundleID: "com.microsoft.teams2",
            sourcePID: 4321,
            suppressionID: "app:com.microsoft.teams2:session:1800000000"
        )
    }
}
