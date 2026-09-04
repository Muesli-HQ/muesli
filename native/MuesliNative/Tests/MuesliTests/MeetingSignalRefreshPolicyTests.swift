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

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery, now: now
        )

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

        let decision = policy.decision(
            trigger: .micChanged, state: state,
            monitoringMode: .discovery, now: now
        )

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
        #expect(decision.refreshAudioAttribution == true)
    }

    @Test("capture lifecycle suppresses attribution without association or retained ownership")
    func captureLifecycleSuppressesAttributionWithoutRetainedOwnership() {
        let policy = MeetingSignalRefreshPolicy()
        // Empty discovery state represents a manual meeting or a detector restart.
        let state = MeetingSignalRefreshState()
        let modes: [(MeetingMonitoringMode, Bool)] = [
            (.discovery, true),
            (.suspended(sessionID: 1), false),
            (.sourceLiveness(sessionID: 1, source: nativeSource()), false),
            (.suspended(sessionID: nil), false),
            (.discovery, true),
            // Failed startup must not leave stale suppression behind.
            (.discovery, true),
        ]

        for (mode, refresh) in modes {
            let decision = policy.decision(
                trigger: .startup, state: state,
                monitoringMode: mode, now: now
            )
            #expect(decision.refreshAudioAttribution == refresh)
        }
    }

    @Test("cooldown reevaluation cannot resume attribution during a recording")
    func cooldownReevaluationCannotResumeAttributionDuringRecording() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-120),
            hasActiveCandidate: true
        )
        // resumeAfterCooldown() schedules promptStateChanged. Neither that event
        // nor a timer after the 15-second cooldown may permit a fresh scan.
        for elapsed in [0.0, 16.0, 120.0, 3600.0] {
            for trigger in [MeetingDetectionTrigger.promptStateChanged, .fallbackTimer] {
                let decision = policy.decision(
                    trigger: trigger, state: state,
                    monitoringMode: .sourceLiveness(sessionID: 1, source: nativeSource()),
                    now: now.addingTimeInterval(elapsed)
                )
                #expect(decision.refreshAudioAttribution == false)
            }
        }
    }

    @Test("repeated suspicious fallback respects expensive collector throttle")
    func repeatedSuspiciousFallbackRespectsThrottle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-4),
            lastBrowserRefreshAt: now.addingTimeInterval(-1),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery, now: now
        )

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

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery, now: now
        )

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == true)
        #expect(decision.refreshBrowserMeetings == true)
    }

    @Test(
        "every trigger suppresses CoreAudio attribution throughout capture",
        arguments: MeetingDetectionTrigger.allCases, [false, true]
    )
    func everyTriggerSuppressesAudioAttribution(
        trigger: MeetingDetectionTrigger,
        hasActiveCandidate: Bool
    ) {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            hasMicOrCameraSignal: true,
            hasActiveCandidate: hasActiveCandidate
        )
        let idleDecision = policy.decision(
            trigger: trigger,
            state: state,
            monitoringMode: .discovery,
            now: now
        )
        #expect(idleDecision.refreshAudioAttribution == true)

        let captureModes: [MeetingMonitoringMode] = [
            .suspended(sessionID: 1),
            .suspended(sessionID: nil),
            .sourceLiveness(sessionID: 1, source: nativeSource()),
        ]
        for mode in captureModes {
            let decision = policy.decision(
                trigger: trigger,
                state: state,
                monitoringMode: mode,
                now: now
            )

            #expect(decision.refreshAudioAttribution == false)
            #expect(decision.refreshBrowserMeetings == (mode.performsEvaluation
                ? idleDecision.refreshBrowserMeetings
                : false))
            #expect(decision.mode == idleDecision.mode)
            #expect(decision.fallbackInterval == idleDecision.fallbackInterval)
        }
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

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery, now: now
        )

        #expect(decision.mode == .idle)
        #expect(decision.fallbackInterval == 120)
    }

    @Test("active candidate keeps suspicious mode")
    func activeCandidateKeepsSuspiciousMode() {
        let policy = MeetingSignalRefreshPolicy()
        var state = MeetingSignalRefreshState()
        state.hasActiveCandidate = true

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery, now: now
        )

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
    }

    private func nativeSource() -> MeetingAutoStopSource {
        MeetingAutoStopSource(candidate: MeetingCandidate(
            id: "app-session:zoom:1",
            platform: .zoom,
            appName: "Zoom",
            url: nil,
            evidence: [.audioInputProcess, .dedicatedApp],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "us.zoom.xos"
        ))
    }
}

@Suite("MeetingMonitoringModePolicy")
struct MeetingMonitoringModePolicyTests {
    private let source = MeetingAutoStopSource(candidate: MeetingCandidate(
        id: "meet:room",
        platform: .googleMeet,
        appName: "Chrome",
        url: "https://meet.google.com/abc-defg-hij",
        evidence: [.browserURL],
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        meetingTitle: nil,
        sourceBundleID: "com.google.Chrome"
    ))

    @Test("idle always derives discovery")
    func idleDerivesDiscovery() {
        let contradictoryIdle = MeetingRecordingLifecycleSnapshot(
            isRecording: false,
            isStarting: false,
            isStopping: false,
            sessionID: 7,
            autoStopSource: source
        )
        #expect(MeetingMonitoringModePolicy.resolve(contradictoryIdle) == .discovery)
    }

    @Test("manual capture suspends all detection")
    func manualCaptureSuspendsDetection() {
        for lifecycle in [
            MeetingRecordingLifecycleSnapshot(
                isRecording: false, isStarting: true, isStopping: false,
                sessionID: 7, autoStopSource: nil
            ),
            MeetingRecordingLifecycleSnapshot(
                isRecording: true, isStarting: false, isStopping: false,
                sessionID: 7, autoStopSource: nil
            ),
        ] {
            #expect(MeetingMonitoringModePolicy.resolve(lifecycle) == .suspended(sessionID: 7))
        }
    }

    @Test("source-backed capture derives narrow liveness")
    func sourceBackedCaptureDerivesLiveness() {
        let lifecycle = MeetingRecordingLifecycleSnapshot(
            isRecording: true,
            isStarting: false,
            isStopping: false,
            sessionID: 7,
            autoStopSource: source
        )
        #expect(MeetingMonitoringModePolicy.resolve(lifecycle) == .sourceLiveness(sessionID: 7, source: source))
    }

    @Test("stopping and invalid capture state fail closed")
    func invalidStatesFailClosed() {
        let stopping = MeetingRecordingLifecycleSnapshot(
            isRecording: true,
            isStarting: false,
            isStopping: true,
            sessionID: 7,
            autoStopSource: source
        )
        let missingSession = MeetingRecordingLifecycleSnapshot(
            isRecording: true,
            isStarting: false,
            isStopping: false,
            sessionID: nil,
            autoStopSource: source
        )
        #expect(MeetingMonitoringModePolicy.resolve(stopping) == .suspended(sessionID: 7))
        #expect(MeetingMonitoringModePolicy.resolve(missingSession) == .suspended(sessionID: nil))
    }
}
