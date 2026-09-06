import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingSignalRefreshPolicy")
struct MeetingSignalRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = MeetingSignalRefreshPolicy()
    private let mic = MeetingAudioAttributionEvidence(
        deviceMicActive: true, selfAudioActivityActive: false, externalMicBundleIDs: []
    )

    private func decision(
        _ state: MeetingSignalRefreshState = .init(),
        trigger: MeetingDetectionTrigger = .fallbackTimer,
        mode: MeetingMonitoringMode = .discovery,
        evidence: MeetingAudioAttributionEvidence? = nil,
        suppressed: Bool = false,
        elapsed: TimeInterval = 0
    ) -> MeetingSignalRefreshDecision {
        policy.decision(trigger: trigger, state: state, monitoringMode: mode,
                        audioEvidence: evidence ?? mic, suppressAudioAttribution: suppressed,
                        now: now.addingTimeInterval(elapsed))
    }

    @Test("every trigger respects capture ownership, even after prompt cooldown",
          arguments: MeetingDetectionTrigger.allCases)
    func captureAdmission(trigger: MeetingDetectionTrigger) {
        let source = MeetingAutoStopSource(candidate: MeetingCandidate(
            id: "zoom", platform: .zoom, appName: "Zoom", url: nil,
            evidence: [.audioInputProcess], startedAt: now, meetingTitle: nil,
            sourceBundleID: "us.zoom.xos"
        ))
        let state = MeetingSignalRefreshState(audioAttributionAttempt: .init(
            episode: .unattributedMic, attemptCount: 1, lastAttemptAt: now, resolvedCandidate: true
        ), hasMicOrCameraSignal: true)
        for mode: MeetingMonitoringMode in [.sourceLiveness(sessionID: 1, source: source),
                                             .suspended(sessionID: 1), .suspended(sessionID: nil)] {
            let result = decision(state, trigger: trigger, mode: mode, elapsed: 120)
            #expect(!result.refreshAudioAttribution && !result.refreshTrackedAudioProcesses)
            #expect(result.refreshBrowserMeetings == mode.performsEvaluation)
        }
    }

    @Test("idle wakeups do not invent activity", arguments: MeetingDetectionTrigger.allCases)
    func idleWakeups(trigger: MeetingDetectionTrigger) {
        let result = decision(.init(lastBrowserRefreshAt: now), trigger: trigger, evidence: .inactive)
        #expect(result.mode == .idle && result.fallbackInterval == 120)
        #expect(!result.refreshAudioAttribution && !result.refreshTrackedAudioProcesses)
        #expect(result.audioAttributionEpisode == nil)
    }

    @Test("browser throttling and suspicion lifetime are independent of audio scans")
    func browserCadence() {
        var state = MeetingSignalRefreshState(lastBrowserRefreshAt: now, lastSuspicionAt: now)
        #expect(!decision(state, elapsed: 2).refreshBrowserMeetings)
        let due = decision(state, elapsed: 3)
        #expect(due.mode == .suspicious && due.fallbackInterval == 3 && due.refreshBrowserMeetings)
        let expired = decision(state, elapsed: 13)
        #expect(expired.mode == .idle && expired.fallbackInterval == 120)
        #expect(!expired.refreshBrowserMeetings)
        #expect(decision(state, elapsed: 120).refreshBrowserMeetings)
        state.hasActiveCandidate = true
        #expect(decision(state, elapsed: 13).mode == .suspicious)
        #expect(decision(state, trigger: .workspaceActivated).refreshBrowserMeetings)
        #expect(policy.suspicionDate(state: .init(lastSuspicionAt: now), now: now.addingTimeInterval(13), resolvedCandidate: nil) == nil)
        #expect(policy.suspicionDate(state: .init(hasCalendarEvent: true), now: now, resolvedCandidate: nil) == now)
    }

    @Test("active-tab probes are throttled independently per browser")
    func activeTabCadence() {
        let state = MeetingSignalRefreshState(lastActiveTabFallbackAttemptAtByBundleID: [
            "chrome": now.addingTimeInterval(-10), "safari": now.addingTimeInterval(-16)
        ])
        #expect(!policy.allowsActiveTabFallbackProbe(for: "chrome", state: state, now: now))
        #expect(policy.allowsActiveTabFallbackProbe(for: "safari", state: state, now: now))
        #expect(policy.allowsActiveTabFallbackProbe(for: "new", state: state, now: now))
    }

    @Test("own audio is not an external meeting, but explicit external attribution wins")
    func evidenceOwnership() {
        let own = MeetingAudioAttributionEvidence(deviceMicActive: true, selfAudioActivityActive: true, externalMicBundleIDs: [])
        let external = MeetingAudioAttributionEvidence(deviceMicActive: true, selfAudioActivityActive: true, externalMicBundleIDs: ["zoom"])
        #expect(decision(evidence: own).audioAttributionEpisode == nil)
        #expect(!decision(evidence: own).refreshAudioAttribution)
        #expect(decision(evidence: external).audioAttributionEpisode == .attributedMic(bundleIDs: ["zoom"]))
        #expect(decision(evidence: external).refreshAudioAttribution)
    }

    @Test("suppression and completion callbacks cannot consume or restart a scan")
    func suppressedAdmission() {
        for result in [decision(suppressed: true), decision(trigger: .audioAttributionChanged)] {
            #expect(!result.refreshAudioAttribution && !result.refreshTrackedAudioProcesses)
            #expect(policy.audioAttributionAttemptState(after: result, current: nil, resolvedCandidate: false, now: now) == nil)
        }
        #expect(decision(elapsed: 16).refreshAudioAttribution)
    }

    @Test("one immediate scan, one delayed retry, and no further full scans")
    func boundedEpisode() {
        var state = MeetingSignalRefreshState(hasMicOrCameraSignal: true)
        let first = decision(state, trigger: .micChanged)
        #expect(first.refreshAudioAttribution && !first.refreshTrackedAudioProcesses)
        #expect(first.mode == .suspicious)
        state.audioAttributionAttempt = policy.audioAttributionAttemptState(
            after: first, current: nil, resolvedCandidate: false, now: now
        )
        #expect(state.audioAttributionAttempt?.attemptCount == 1)
        let early = decision(state, elapsed: 2)
        #expect(!early.refreshAudioAttribution && early.refreshTrackedAudioProcesses)
        let retry = decision(state, elapsed: 3)
        #expect(retry.refreshAudioAttribution && !retry.refreshTrackedAudioProcesses)
        state.audioAttributionAttempt = policy.audioAttributionAttemptState(
            after: retry, current: state.audioAttributionAttempt, resolvedCandidate: false, now: now.addingTimeInterval(3)
        )
        #expect(state.audioAttributionAttempt?.attemptCount == 2)
        #expect(!decision(state, elapsed: 3600).refreshAudioAttribution)
    }

    @Test("resolved episodes stay bounded; changed or cleared evidence rearms discovery")
    func episodeIdentity() {
        let first = decision()
        var state = MeetingSignalRefreshState(audioAttributionAttempt: policy.audioAttributionAttemptState(
            after: first, current: nil, resolvedCandidate: false, now: now
        ))
        state.audioAttributionAttempt = policy.audioAttributionAttemptState(
            after: decision(state, trigger: .audioAttributionChanged), current: state.audioAttributionAttempt,
            resolvedCandidate: true, now: now.addingTimeInterval(1)
        )
        #expect(state.audioAttributionAttempt?.resolvedCandidate == true)
        #expect(state.audioAttributionAttempt?.attemptCount == 1)
        #expect(state.audioAttributionAttempt?.lastAttemptAt == now)
        #expect(!decision(state, elapsed: 3600).refreshAudioAttribution)
        let changed = MeetingAudioAttributionEvidence(deviceMicActive: true, selfAudioActivityActive: false, externalMicBundleIDs: ["zoom"])
        #expect(decision(state, evidence: changed).refreshAudioAttribution)
        state.audioAttributionAttempt = policy.audioAttributionAttemptState(
            after: decision(state, evidence: .inactive), current: state.audioAttributionAttempt,
            resolvedCandidate: false, now: now.addingTimeInterval(2)
        )
        #expect(state.audioAttributionAttempt == nil)
        #expect(decision(state, elapsed: 3).refreshAudioAttribution)
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

    @Test("capture phase determines discovery, suspension, or source liveness",
          arguments: [MeetingCapturePhase.preparing, .capturing, .paused, .stopping, .stopped])
    func capturePhaseDeterminesMonitoring(phase: MeetingCapturePhase) {
        for sessionID: Int64? in [7, nil] {
            for autoStopSource in [source, nil] {
                let lifecycle = MeetingRecordingLifecycleSnapshot(
                    phase: phase, sessionID: sessionID, autoStopSource: autoStopSource
                )
                let expected: MeetingMonitoringMode
                if phase == .stopped {
                    expected = .discovery
                } else if phase == .stopping || sessionID == nil || autoStopSource == nil {
                    expected = .suspended(sessionID: sessionID)
                } else {
                    expected = .sourceLiveness(sessionID: 7, source: source)
                }
                #expect(MeetingMonitoringModePolicy.resolve(lifecycle) == expected)
            }
        }
    }

}

@Suite("Audio attribution isolation")
struct AudioAttributionServiceTests {
    @Test("blocked attribution cannot block evaluation or reset, or accumulate scans")
    func blockedCollector() async {
        let entered = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let service = AudioAttributionService { _ in
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
            return []
        }
        let first = await service.activeInputProcesses(
            refreshFull: true, refreshTracked: false, episode: .unattributedMic,
            onChange: { Issue.record("A retired scan published into the next detector lifetime") }
        )
        #expect(first.startedRefresh)
        for await _ in entered.stream { break }
        let repeated = await service.activeInputProcesses(
            refreshFull: true, refreshTracked: false, episode: .unattributedMic,
            onChange: { Issue.record("A duplicate scan was queued") }
        )
        #expect(!repeated.startedRefresh)
        // Reset must return before the native query. Its late result cannot
        // publish a meeting into the next detector lifetime.
        await service.reset()
        release.signal()
        await service.waitForObservation()
        // A separate owner proves completion generates exactly the observation
        // event, whose policy decision must not schedule another query.
        let fresh = AudioAttributionService { _ in [] }
        _ = await fresh.activeInputProcesses(
            refreshFull: true, refreshTracked: false, episode: .unattributedMic,
            onChange: { completed.continuation.yield(()) }
        )
        for await _ in completed.stream { break }
        let decision = MeetingSignalRefreshPolicy().decision(
            trigger: .audioAttributionChanged,
            state: MeetingSignalRefreshState(), monitoringMode: .discovery,
            audioEvidence: .init(deviceMicActive: true, selfAudioActivityActive: false, externalMicBundleIDs: []),
            now: Date()
        )
        #expect(!decision.refreshAudioAttribution)
        #expect(!decision.refreshTrackedAudioProcesses)
    }
}
