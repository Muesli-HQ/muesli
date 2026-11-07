import Foundation
import Testing
@testable import MuesliNativeApp

@MainActor
private final class MeetingAutoStopObserverHarness {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var assertion: Bool? = true
    var eligible = true
    var stopCount = 0
    var acceptStop = true
    private var pollContinuation: CheckedContinuation<Void, Never>?
    private var probeContinuation: CheckedContinuation<Bool, Never>?
    var waitingForPoll: Bool { pollContinuation != nil }
    var waitingForProbe: Bool { probeContinuation != nil }

    func makeObserver() -> MeetingAutoStopObserver {
        MeetingAutoStopObserver(
            readAssertion: { [self] _ in assertion },
            probeConnectivity: { [self] in
                await withCheckedContinuation { probeContinuation = $0 }
            },
            now: { [self] in clock },
            waitForNextPoll: { [self] in
                await withCheckedContinuation { pollContinuation = $0 }
            },
            monitorNetwork: false
        )
    }

    func start(_ observer: MeetingAutoStopObserver) {
        observer.start(target: .zoom, isEligible: { [self] in eligible }, onStop: { [self] in
            stopCount += 1
            return acceptStop
        })
        observer.observeNetwork(.available)
    }

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    func advancePoll() {
        let continuation = pollContinuation
        pollContinuation = nil
        continuation?.resume()
    }

    func finishProbe(_ reachable: Bool) {
        let continuation = probeContinuation
        probeContinuation = nil
        continuation?.resume(returning: reachable)
    }

    func finish(_ observer: MeetingAutoStopObserver) {
        observer.stop()
        advancePoll()
        finishProbe(false)
    }
}

@Suite("Meeting auto-stop policy")
struct MeetingAutoStopPolicyTests {
    @Test("assertion recovery while the connectivity probe is pending does not stop")
    @MainActor func assertionRecoveryDuringProbe() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.assertion = true
        harness.clock = harness.clock.addingTimeInterval(30)
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        #expect(harness.stopCount == 0)
        #expect(observer.hasObservedAssertion)
        harness.finish(observer)
    }

    @Test("pause during a pending probe discards the result and requires a fresh assertion")
    @MainActor func pauseDuringProbe() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.eligible = false
        observer.resetObservation()
        harness.clock = harness.clock.addingTimeInterval(40)
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.eligible = true
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        #expect(!observer.hasObservedAssertion)
        #expect(harness.stopCount == 0)
        harness.finish(observer)
    }

    @Test("cancellation while a connectivity probe is pending cannot stop a recording")
    @MainActor func cancellationDuringProbe() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        observer.stop()
        harness.clock = harness.clock.addingTimeInterval(40)
        harness.finishProbe(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.stopCount == 0)
        #expect(!observer.hasObservedAssertion)
    }

    @Test("confirmed assertion loss stops only once after the online grace")
    @MainActor func stopOnlyOnce() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(15)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.stopCount == 1 })
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.stopCount == 1)
        harness.finish(observer)
    }

    @Test("wake invalidates a pending probe and the observer continues monitoring")
    @MainActor func wakeDuringProbe() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        observer.resetObservation(preservingNetwork: false)
        observer.observeNetwork(.available)
        harness.assertion = true
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        #expect(observer.hasObservedAssertion)
        #expect(harness.stopCount == 0)
        harness.finish(observer)
    }

    @Test("a declined stop requires a fresh full loss grace before retrying")
    @MainActor func declinedStopRetriesAfterFreshGrace() async {
        let harness = MeetingAutoStopObserverHarness()
        harness.acceptStop = false
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(15)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.stopCount == 1 && harness.waitingForPoll })
        #expect(observer.hasObservedAssertion)
        harness.acceptStop = true
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(14)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        #expect(harness.stopCount == 1)
        harness.clock = harness.clock.addingTimeInterval(1)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.stopCount == 2 })
        harness.finish(observer)
    }

    @Test("network recovery waits a full minute for the meeting assertion to return")
    @MainActor func outageRecoveryGraceInPollingLoop() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        observer.observeNetwork(.unavailable)
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(55)
        observer.observeNetwork(.available)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(59)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForProbe })
        harness.finishProbe(true)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        #expect(harness.stopCount == 0)
        harness.clock = harness.clock.addingTimeInterval(1)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.stopCount == 1 })
        harness.finish(observer)
    }

    @Test("the same meeting returning after an outage keeps the recording running")
    @MainActor func outageMeetingReturnsInPollingLoop() async {
        let harness = MeetingAutoStopObserverHarness()
        let observer = harness.makeObserver()
        harness.start(observer)
        #expect(await harness.waitUntil { harness.waitingForPoll })
        observer.observeNetwork(.unavailable)
        harness.assertion = false
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(60)
        observer.observeNetwork(.available)
        harness.assertion = true
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        harness.clock = harness.clock.addingTimeInterval(600)
        harness.advancePoll()
        #expect(await harness.waitUntil { harness.waitingForPoll })
        #expect(observer.hasObservedAssertion)
        #expect(harness.stopCount == 0)
        harness.finish(observer)
    }
    @Test("Clamshell microphone warning appears once per built-in input episode")
    func clamshellMicWarning() {
        var state = MeetingClamshellMicWarningState()
        func check(_ closed: Bool, _ builtIn: Bool?, _ expected: Bool) {
            let result = state.update(lidClosed: closed, effectiveInputIsBuiltIn: builtIn)
            #expect(result == expected)
        }
        check(false, true, false)
        check(true, nil, false)
        check(true, false, false)
        check(true, true, true)
        state.markShown()
        check(true, true, false)
        check(true, nil, false)
        check(true, false, false)
        check(true, true, true)
        state.markShown()
        check(false, true, false)
        check(true, true, true)
    }
    @Test("Lid closure preserves recording with an active external display")
    func clamshellPolicy() {
        #expect(!MeetingLidStopPolicy.shouldStop(lidClosed: true, hasActiveExternalDisplay: true))
        #expect(MeetingLidStopPolicy.shouldStop(lidClosed: true, hasActiveExternalDisplay: false))
        #expect(!MeetingLidStopPolicy.shouldStop(lidClosed: false, hasActiveExternalDisplay: false))
        #expect(!MeetingLidStopPolicy.shouldStop(lidClosed: true, hasActiveExternalDisplay: nil))
    }
    @Test("System stop handles preparation and paused capture without stopping twice")
    func systemStopPhases() {
        #expect(MeetingSystemStopAction.action(phase: .preparing) == .cancelPreparation)
        #expect(MeetingSystemStopAction.action(phase: .capturing) == .stopRecording)
        #expect(MeetingSystemStopAction.action(phase: .paused) == .stopRecording)
        #expect(MeetingSystemStopAction.action(phase: .stopping) == .none)
        #expect(MeetingSystemStopAction.action(phase: .stopped) == .none)
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let room = "meet.google.com/aaa-bbbb-ccc"

    @Test("Zoom assertion absence requires a prior positive observation and healthy network knowledge")
    func zoomNeedsObservedAssertion() {
        var facts = MeetingAutoStopFacts()
        facts.observeNetwork(.available, now: now)
        facts.observeAssertion(.absent, now: now)
        #expect(!facts.shouldStop(now: now.addingTimeInterval(600)))
        facts.observeAssertion(.present, now: now)
        facts.observeAssertion(.absent, now: now)
        facts.observeProbe(.reachable, now: now)
        #expect(!facts.shouldStop(now: now.addingTimeInterval(14)))
        #expect(facts.shouldStop(now: now.addingTimeInterval(15)))
        facts.observeNetwork(.unknown, now: now)
        #expect(!facts.shouldStop(now: now.addingTimeInterval(600)))
    }

    @Test("network interruption preserves a recording and assertion recovery cancels loss")
    func zoomReconnect() {
        var facts = MeetingAutoStopFacts()
        facts.observeNetwork(.available, now: now)
        facts.observeAssertion(.present, now: now)
        facts.observeNetwork(.unavailable, now: now)
        facts.observeAssertion(.absent, now: now)
        #expect(!facts.shouldStop(now: now.addingTimeInterval(479)))
        #expect(facts.shouldStop(now: now.addingTimeInterval(480)))
        facts.observeNetwork(.available, now: now.addingTimeInterval(55))
        facts.observeProbe(.reachable, now: now.addingTimeInterval(55))
        #expect(!facts.shouldStop(now: now.addingTimeInterval(114)))
        #expect(facts.shouldStop(now: now.addingTimeInterval(115)))
        facts.observeAssertion(.present, now: now.addingTimeInterval(56))
        #expect(!facts.shouldStop(now: now.addingTimeInterval(600)))
    }

    @Test("recent reconnect is correlated even if loss is observed later")
    func zoomLateLossAndUnknown() {
        var facts = MeetingAutoStopFacts()
        facts.observeNetwork(.available, now: now)
        facts.observeAssertion(.present, now: now)
        facts.observeNetwork(.unavailable, now: now)
        facts.observeNetwork(.unknown, now: now.addingTimeInterval(5))
        facts.observeNetwork(.available, now: now.addingTimeInterval(10))
        facts.observeAssertion(.absent, now: now.addingTimeInterval(20))
        facts.observeProbe(.reachable, now: now.addingTimeInterval(20))
        #expect(!facts.shouldStop(now: now.addingTimeInterval(69)))
        #expect(facts.shouldStop(now: now.addingTimeInterval(70)))
        facts.observeAssertion(.unknown, now: now.addingTimeInterval(71))
        #expect(!facts.shouldStop(now: now.addingTimeInterval(600)))
    }

    @Test("failed connectivity checks extend recovery and successful checks restart grace")
    func zoomCanaryRecovery() {
        var facts = MeetingAutoStopFacts()
        facts.observeNetwork(.available, now: now)
        facts.observeAssertion(.present, now: now)
        facts.observeAssertion(.absent, now: now)
        facts.observeProbe(.unavailable, now: now.addingTimeInterval(5))
        #expect(!facts.shouldStop(now: now.addingTimeInterval(479)))
        #expect(facts.shouldStop(now: now.addingTimeInterval(480)))
        facts.observeProbe(.reachable, now: now.addingTimeInterval(100))
        #expect(!facts.shouldStop(now: now.addingTimeInterval(159)))
        #expect(facts.shouldStop(now: now.addingTimeInterval(160)))
    }

    @Test("assertion monitoring requires attributed meeting sources")
    func zoomSourceEligibility() throws {
        let url = try #require(URL(string: "https://zoom.us/j/123456789"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))
        #expect(source.assertionTarget == nil)
        let native = candidate(id: "native", url: nil, bundle: "us.zoom.xos")
        #expect(MeetingAutoStopPolicy.matches(candidate: native, source: source))
        #expect(source.refined(with: native).assertionTarget == .zoom)
        #expect(!MeetingAutoStopPolicy.matches(candidate: candidate(id: "native", url: nil, bundle: "us.zoom.xos", media: false), source: source))
        #expect(MeetingAutoStopSource(candidate: candidate(id: "zoom", url: nil, bundle: "us.zoom.xos")).assertionTarget == .zoom)
        #expect(MeetingAutoStopSource(candidate: candidate(id: "zoom", url: "zoom.us/j/123456789", bundle: "com.google.Chrome")).assertionTarget == .browser(bundleID: "com.google.Chrome"))
        #expect(MeetingAutoStopSource(candidate: candidate(url: nil)).assertionTarget == .browser(bundleID: "com.google.Chrome"))
        #expect(MeetingAutoStopSource(candidate: candidate(url: nil, bundle: "com.google.Chrome.helper")).assertionTarget == .browser(bundleID: "com.google.Chrome"))
        #expect(MeetingAutoStopSource(candidate: candidate(url: nil, bundle: "com.example.OtherBrowser")).assertionTarget == nil)
        #expect(MeetingAutoStopSource(candidate: candidate(bundle: "com.microsoft.teams2.helper")).assertionTarget == .teams)
        #expect(MeetingAutoStopSource(candidate: candidate(bundle: "com.cisco.webexmeetingsapp")).assertionTarget == .webex)
        #expect(MeetingRecordingStartOrigin.manual.signalLossSource(explicitSource: nil, recentSource: nil) == nil)
    }

    @Test("assertion signatures are specific to each platform")
    func assertionPatterns() {
        let on = 255
        #expect(MeetingAssertionTarget.zoom.matches(name: "Describe Activity Type", type: "NoDisplaySleepAssertion", level: on))
        #expect(MeetingAssertionTarget.teams.matches(name: "Call in progress", type: "PreventUserIdleDisplaySleep", level: on))
        #expect(!MeetingAssertionTarget.teams.matches(name: "Video Wake Lock", type: "PreventUserIdleDisplaySleep", level: on))
        #expect(MeetingAssertionTarget.webex.matches(name: "On a call", type: "PreventUserIdleDisplaySleep", level: on))
        #expect(!MeetingAssertionTarget.webex.matches(name: "Webex idle", type: "PreventUserIdleDisplaySleep", level: on))
        #expect(!MeetingAssertionTarget.webex.matches(name: "Video Wake Lock", type: "PreventUserIdleDisplaySleep", level: on))
        let browser = MeetingAssertionTarget.browser(bundleID: "com.google.Chrome")
        #expect(browser.matches(name: "WebRTC has active PeerConnections", type: "NoIdleSleepAssertion", level: on))
        #expect(!browser.matches(name: "Video Wake Lock", type: "NoIdleSleepAssertion", level: on))
        #expect(!browser.matches(name: "WebRTC has active PeerConnections", type: "NoIdleSleepAssertion", level: 0))
    }

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

    @Test("source-backed origins warn without stopping recording", arguments: [
        MeetingRecordingStartOrigin.manual, .detectedPrompt, .calendarAutoRecord,
        .scheduledMeetingPrompt, .joinAndRecord
    ])
    func startOrigin(origin: MeetingRecordingStartOrigin) {
        let explicit = MeetingAutoStopSource(candidate: candidate())
        let recent = MeetingAutoStopSource(candidate: candidate(id: "recent", url: nil))
        let tracksSource = origin != .manual
        let expectedSignalLoss: MeetingSignalLossResponse = tracksSource ? .warnOnly : .transcriptInactivity
        #expect(origin.tracksMeetingSource == tracksSource)
        #expect(origin.signalLossResponse == expectedSignalLoss)
        #expect(origin.signalLossSource(explicitSource: explicit, recentSource: recent) == (tracksSource ? explicit : nil))
        #expect(origin.signalLossSource(explicitSource: nil, recentSource: recent) == (tracksSource ? recent : nil))
    }

    @Test("manual reminder waits a full quiet period, including an initially empty transcript")
    func manualReminderDeadline() {
        var state = MeetingSignalLossPromptState()
        #expect(state.inactivityDeadline == nil) // Still preparing.
        state.noteTranscriptActivity(now: now) // Recording became active.
        #expect(state.inactivityDeadline == now.addingTimeInterval(45))
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(44.9), quietPeriod: 45))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(45), quietPeriod: 45))
        state.noteTranscriptActivity(now: now.addingTimeInterval(30))
        #expect(state.inactivityDeadline == now.addingTimeInterval(75))
        state.resetForRecording() // Stop/discard or a different recording.
        #expect(state.inactivityDeadline == nil)
    }

    @Test("manual reminders do not repeat until activity resumes, and explicit dismissal lasts for the recording")
    func manualReminderSuppression() {
        var state = MeetingSignalLossPromptState()
        state.noteTranscriptActivity(now: now)
        state.markPromptPresented()
        state.markAutoDismissed()
        #expect(state.inactivityDeadline == nil)
        state.markSourceRecovered()
        state.noteTranscriptActivity(now: now.addingTimeInterval(100))
        #expect(state.inactivityDeadline == now.addingTimeInterval(145))
        state.markDismissedByUser()
        state.markSourceRecovered()
        state.noteTranscriptActivity(now: now.addingTimeInterval(200))
        #expect(state.inactivityDeadline == nil)
        state.resetForRecording()
        state.noteTranscriptActivity(now: now.addingTimeInterval(300))
        #expect(state.inactivityDeadline == now.addingTimeInterval(345))
        #expect(MeetingSignalLossPromptState.notificationDuration == 30)
    }

    @Test("recent transcript activity defers a signal-loss warning")
    func transcriptActivity() {
        var state = MeetingSignalLossPromptState()
        #expect(!state.hasRecentTranscriptActivity(now: now, quietPeriod: 45))
        state.noteTranscriptActivity(now: now)
        #expect(state.hasRecentTranscriptActivity(now: now.addingTimeInterval(44), quietPeriod: 45))
        #expect(!state.hasRecentTranscriptActivity(now: now.addingTimeInterval(45), quietPeriod: 45))
        state.resetForRecording()
        #expect(!state.hasRecentTranscriptActivity(now: now, quietPeriod: 45))
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
