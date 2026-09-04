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
            lastBrowserRefreshAt: now.addingTimeInterval(-10)
        )

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery, now: now
        )

        #expect(decision.mode == .idle)
        #expect(decision.fallbackInterval == 120)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.audioAttributionEpisode == nil)
        #expect(decision.refreshBrowserMeetings == false)
    }

    @Test("new unattributed mic episode allows one immediate attribution")
    func micTriggerAllowsImmediateAudioAttribution() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastBrowserRefreshAt: now,
            hasMicOrCameraSignal: true
        )

        let decision = policy.decision(
            trigger: .micChanged, state: state,
            monitoringMode: .discovery,
            audioEvidence: unresolvedMicEvidence(),
            now: now
        )

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
        #expect(decision.refreshAudioAttribution == true)
        #expect(decision.audioAttributionEpisode == .unattributedMic)
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
                monitoringMode: mode,
                audioEvidence: unresolvedMicEvidence(),
                now: now
            )
            #expect(decision.refreshAudioAttribution == refresh)
        }
    }

    @Test("cooldown reevaluation cannot resume attribution during a recording")
    func cooldownReevaluationCannotResumeAttributionDuringRecording() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            hasActiveCandidate: true
        )
        // resumeAfterCooldown() schedules promptStateChanged. Neither that event
        // nor a timer after the 15-second cooldown may permit a fresh scan.
        for elapsed in [0.0, 16.0, 120.0, 3600.0] {
            for trigger in [MeetingDetectionTrigger.promptStateChanged, .fallbackTimer] {
                let decision = policy.decision(
                    trigger: trigger, state: state,
                    monitoringMode: .sourceLiveness(sessionID: 1, source: nativeSource()),
                    audioEvidence: unresolvedMicEvidence(),
                    now: now.addingTimeInterval(elapsed)
                )
                #expect(decision.refreshAudioAttribution == false)
            }
        }
    }

    @Test("repeated suspicious fallback does not repeat attribution in one episode")
    func repeatedSuspiciousFallbackDoesNotRepeatAttribution() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            audioAttributionAttempt: attempt(
                episode: .unattributedMic,
                lastAttemptAt: now.addingTimeInterval(-4),
                resolvedCandidate: true
            ),
            lastBrowserRefreshAt: now.addingTimeInterval(-1),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery,
            audioEvidence: unresolvedMicEvidence(),
            now: now
        )

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.refreshTrackedAudioProcesses == true)
        #expect(decision.refreshBrowserMeetings == false)
    }

    @Test("suspicious fallback may refresh browser without repeating attribution")
    func suspiciousFallbackRefreshesBrowserOnly() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            audioAttributionAttempt: attempt(
                episode: .unattributedMic,
                lastAttemptAt: now.addingTimeInterval(-9),
                resolvedCandidate: true
            ),
            lastBrowserRefreshAt: now.addingTimeInterval(-4),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(
            trigger: .fallbackTimer, state: state,
            monitoringMode: .discovery,
            audioEvidence: unresolvedMicEvidence(),
            now: now
        )

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.refreshTrackedAudioProcesses == true)
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
            audioEvidence: unresolvedMicEvidence(),
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
                audioEvidence: unresolvedMicEvidence(),
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

    @Test("self-owned interactive audio never authorizes attribution")
    func selfOwnedInteractiveAudioSkipsAttribution() {
        let policy = MeetingSignalRefreshPolicy()
        let evidence = MeetingAudioAttributionEvidence(
            deviceMicActive: true,
            selfAudioActivityActive: true,
            externalMicBundleIDs: []
        )

        for trigger in MeetingDetectionTrigger.allCases {
            let decision = policy.decision(
                trigger: trigger,
                state: MeetingSignalRefreshState(hasMicOrCameraSignal: false),
                monitoringMode: .discovery,
                audioEvidence: evidence,
                now: now
            )
            #expect(decision.refreshAudioAttribution == false)
            #expect(decision.refreshTrackedAudioProcesses == false)
            #expect(decision.audioAttributionEpisode == nil)
        }
    }

    @Test("external mic attribution remains distinct while Muesli owns audio")
    func externalMicDuringSelfAudioStartsEpisode() {
        let policy = MeetingSignalRefreshPolicy()
        let evidence = MeetingAudioAttributionEvidence(
            deviceMicActive: true,
            selfAudioActivityActive: true,
            externalMicBundleIDs: ["com.microsoft.teams2"]
        )

        let decision = policy.decision(
            trigger: .sensorAttributionChanged,
            state: MeetingSignalRefreshState(hasMicOrCameraSignal: true),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now
        )

        #expect(decision.refreshAudioAttribution == true)
        #expect(decision.audioAttributionEpisode == .attributedMic(bundleIDs: ["com.microsoft.teams2"]))
    }

    @Test("a changed external attribution starts a new episode")
    func changedExternalAttributionStartsNewEpisode() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            audioAttributionAttempt: attempt(
                episode: .attributedMic(bundleIDs: ["us.zoom.xos"]),
                resolvedCandidate: true
            ),
            hasMicOrCameraSignal: true
        )
        let evidence = MeetingAudioAttributionEvidence(
            deviceMicActive: true,
            selfAudioActivityActive: false,
            externalMicBundleIDs: ["com.microsoft.teams2"]
        )

        let decision = policy.decision(
            trigger: .sensorAttributionChanged,
            state: state,
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now
        )

        #expect(decision.refreshAudioAttribution == true)
    }

    @Test("clearing input re-arms the same external attribution")
    func clearingInputRearmsEpisode() {
        let policy = MeetingSignalRefreshPolicy()
        let evidence = MeetingAudioAttributionEvidence(
            deviceMicActive: true,
            selfAudioActivityActive: false,
            externalMicBundleIDs: ["us.zoom.xos"]
        )
        let first = policy.decision(
            trigger: .sensorAttributionChanged,
            state: MeetingSignalRefreshState(hasMicOrCameraSignal: true),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now
        )
        let attributedAttempt = policy.audioAttributionAttemptState(
            after: first,
            current: nil,
            resolvedCandidate: true,
            now: now
        )
        #expect(attributedAttempt?.episode == .attributedMic(bundleIDs: ["us.zoom.xos"]))

        let repeated = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: attributedAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(9)
        )
        #expect(repeated.refreshAudioAttribution == false)

        let cleared = policy.decision(
            trigger: .sensorAttributionChanged,
            state: MeetingSignalRefreshState(audioAttributionAttempt: attributedAttempt),
            monitoringMode: .discovery,
            now: now.addingTimeInterval(10)
        )
        let clearedAttempt = policy.audioAttributionAttemptState(
            after: cleared,
            current: attributedAttempt,
            resolvedCandidate: false,
            now: now.addingTimeInterval(10)
        )
        #expect(clearedAttempt == nil)

        let next = policy.decision(
            trigger: .sensorAttributionChanged,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: clearedAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(11)
        )
        #expect(next.refreshAudioAttribution == true)
    }

    @Test("wake-up triggers without media evidence remain idle and skip attribution")
    func wakeUpTriggersDoNotCreateSuspicion() {
        let policy = MeetingSignalRefreshPolicy()
        for trigger in [
            MeetingDetectionTrigger.micChanged,
            .cameraChanged,
            .sensorAttributionChanged,
            .calendarChanged,
            .workspaceActivated,
        ] {
            let decision = policy.decision(
                trigger: trigger,
                state: MeetingSignalRefreshState(),
                monitoringMode: .discovery,
                now: now
            )
            #expect(decision.mode == .idle)
            #expect(decision.refreshAudioAttribution == false)
        }
    }

    @Test("global suppression delays rather than consumes an external episode")
    func suppressionDoesNotConsumeEpisode() {
        let policy = MeetingSignalRefreshPolicy()
        let evidence = unresolvedMicEvidence()
        let suppressed = policy.decision(
            trigger: .micChanged,
            state: MeetingSignalRefreshState(hasMicOrCameraSignal: true),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            suppressAudioAttribution: true,
            now: now
        )
        #expect(suppressed.refreshAudioAttribution == false)
        #expect(suppressed.refreshTrackedAudioProcesses == false)
        #expect(suppressed.audioAttributionEpisode == .unattributedMic)
        let retainedAttempt = policy.audioAttributionAttemptState(
            after: suppressed,
            current: nil,
            resolvedCandidate: false,
            now: now
        )
        #expect(retainedAttempt == nil)

        let resumed = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: retainedAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(15)
        )
        #expect(resumed.refreshAudioAttribution == true)
    }

    @Test("an unresolved episode gets one delayed retry and then stops")
    func unresolvedEpisodeHasBoundedRetry() {
        let policy = MeetingSignalRefreshPolicy()
        let evidence = unresolvedMicEvidence()
        let first = policy.decision(
            trigger: .micChanged,
            state: MeetingSignalRefreshState(hasMicOrCameraSignal: true),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now
        )
        let firstAttempt = policy.audioAttributionAttemptState(
            after: first,
            current: nil,
            resolvedCandidate: false,
            now: now
        )

        let tooSoon = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: firstAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(2)
        )
        #expect(tooSoon.refreshAudioAttribution == false)
        #expect(tooSoon.refreshTrackedAudioProcesses == true)

        let retry = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: firstAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(3)
        )
        #expect(retry.refreshAudioAttribution == true)
        #expect(retry.refreshTrackedAudioProcesses == false)
        let secondAttempt = policy.audioAttributionAttemptState(
            after: retry,
            current: firstAttempt,
            resolvedCandidate: false,
            now: now.addingTimeInterval(3)
        )

        let exhausted = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: secondAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(120)
        )
        #expect(exhausted.refreshAudioAttribution == false)
        #expect(exhausted.refreshTrackedAudioProcesses == true)
    }

    @Test("a narrow tracked-process refresh can resolve an episode without another full scan")
    func trackedRefreshCanResolveEpisode() {
        let policy = MeetingSignalRefreshPolicy()
        let evidence = unresolvedMicEvidence()
        let first = policy.decision(
            trigger: .micChanged,
            state: MeetingSignalRefreshState(hasMicOrCameraSignal: true),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now
        )
        let firstAttempt = policy.audioAttributionAttemptState(
            after: first,
            current: nil,
            resolvedCandidate: false,
            now: now
        )
        let tracked = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: firstAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(2)
        )
        #expect(tracked.refreshTrackedAudioProcesses == true)
        let resolvedAttempt = policy.audioAttributionAttemptState(
            after: tracked,
            current: firstAttempt,
            resolvedCandidate: true,
            now: now.addingTimeInterval(2)
        )

        let afterResolution = policy.decision(
            trigger: .fallbackTimer,
            state: MeetingSignalRefreshState(
                audioAttributionAttempt: resolvedAttempt,
                hasMicOrCameraSignal: true
            ),
            monitoringMode: .discovery,
            audioEvidence: evidence,
            now: now.addingTimeInterval(30)
        )
        #expect(afterResolution.refreshAudioAttribution == false)
        #expect(afterResolution.refreshTrackedAudioProcesses == true)
    }

    private func unresolvedMicEvidence() -> MeetingAudioAttributionEvidence {
        MeetingAudioAttributionEvidence(
            deviceMicActive: true,
            selfAudioActivityActive: false,
            externalMicBundleIDs: []
        )
    }

    private func attempt(
        episode: MeetingAudioAttributionEpisode,
        attemptCount: Int = 1,
        lastAttemptAt: Date? = nil,
        resolvedCandidate: Bool
    ) -> MeetingAudioAttributionAttemptState {
        MeetingAudioAttributionAttemptState(
            episode: episode,
            attemptCount: attemptCount,
            lastAttemptAt: lastAttemptAt ?? now,
            resolvedCandidate: resolvedCandidate
        )
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
