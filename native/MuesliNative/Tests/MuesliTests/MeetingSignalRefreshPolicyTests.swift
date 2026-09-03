import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingSignalRefreshPolicy")
struct MeetingSignalRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("idle fallback skips expensive collectors")
    func idleFallbackSkipsExpensiveCollectors() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-10),
            lastBrowserRefreshAt: now.addingTimeInterval(-10)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .idle)
        #expect(decision.fallbackInterval == 120)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.refreshBrowserMeetings == false)
    }

    @Test("mic trigger enters suspicion and allows immediate audio attribution")
    func micTriggerAllowsImmediateAudioAttribution() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now,
            lastBrowserRefreshAt: now
        )

        let decision = policy.decision(trigger: .micChanged, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
        #expect(decision.refreshAudioAttribution == true)
    }

    @Test("Muesli-owned recording suppresses attribution until capture ends")
    func ownedRecordingSuppressesAttributionUntilCaptureEnds() {
        var gate = MeetingRecordingAttributionGate()

        #expect(gate.shouldSuppress(isRecording: true) == false)
        #expect(gate.markCaptureOwned() == true)
        #expect(gate.markCaptureOwned() == false)
        #expect(gate.shouldSuppress(isRecording: true) == true)

        gate.synchronize(isRecording: false, isStartingRecording: true)
        #expect(gate.ownsActiveCapture == true)

        gate.synchronize(isRecording: false, isStartingRecording: false)
        #expect(gate.ownsActiveCapture == false)
        #expect(gate.shouldSuppress(isRecording: true) == false)
    }

    @Test("repeated suspicious fallback respects expensive collector throttle")
    func repeatedSuspiciousFallbackRespectsThrottle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-4),
            lastBrowserRefreshAt: now.addingTimeInterval(-1),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.refreshBrowserMeetings == false)
    }

    @Test("suspicious fallback refreshes collectors after throttle expires")
    func suspiciousFallbackRefreshesAfterThrottle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-9),
            lastBrowserRefreshAt: now.addingTimeInterval(-4),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == true)
        #expect(decision.refreshBrowserMeetings == true)
    }

    @Test(
        "associated recording suppresses CoreAudio attribution",
        arguments: [
            MeetingDetectionTrigger.fallbackTimer,
            MeetingDetectionTrigger.micChanged,
            MeetingDetectionTrigger.sensorAttributionChanged,
            MeetingDetectionTrigger.manualRefresh,
        ]
    )
    func associatedRecordingSuppressesAudioAttribution(trigger: MeetingDetectionTrigger) {
        let policy = MeetingSignalRefreshPolicy()
        var state = MeetingSignalRefreshState()
        state.hasActiveCandidate = true

        let decision = policy.decision(
            trigger: trigger,
            state: state,
            suppressAudioAttribution: true,
            now: now
        )

        #expect(decision.refreshAudioAttribution == false)
    }

    @Test("active-tab fallback is throttled per browser bundle")
    func activeTabFallbackIsThrottledPerBundle() {
        let policy = MeetingSignalRefreshPolicy()
        var state = MeetingSignalRefreshState()
        state.lastActiveTabFallbackAttemptAtByBundleID = [
            "com.google.Chrome": now.addingTimeInterval(-10),
            "com.apple.Safari": now.addingTimeInterval(-16),
        ]

        #expect(policy.allowsActiveTabFallbackProbe(for: "com.google.Chrome", state: state, now: now) == false)
        #expect(policy.allowsActiveTabFallbackProbe(for: "com.apple.Safari", state: state, now: now) == true)
        #expect(policy.allowsActiveTabFallbackProbe(for: "com.brave.Browser", state: state, now: now) == true)
    }

    @Test("suspicion expires back to idle after TTL")
    func suspicionExpiresBackToIdle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-40),
            lastBrowserRefreshAt: now.addingTimeInterval(-40),
            lastSuspicionAt: now.addingTimeInterval(-13)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .idle)
        #expect(decision.fallbackInterval == 120)
    }

    @Test("active candidate keeps suspicious mode")
    func activeCandidateKeepsSuspiciousMode() {
        let policy = MeetingSignalRefreshPolicy()
        var state = MeetingSignalRefreshState()
        state.hasActiveCandidate = true

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
    }
}
