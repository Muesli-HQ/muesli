import Foundation
import Testing
@testable import MuesliNativeApp

struct MeetingMicRecoveryCoordinatorTests {
    private final class Harness {
        let tracker = MeetingMicHealthTracker()
        var coordinator: MeetingMicRecoveryCoordinator!
        var events: [MeetingMicHealthEpisodeEvent] = []
        var recoveryRequests: [String] = []
        var now = Date(timeIntervalSince1970: 1_000_000)

        init(cooldown: TimeInterval = 15, maxAttempts: Int = 3) {
            coordinator = MeetingMicRecoveryCoordinator(
                policy: .init(attemptCooldown: cooldown, maxAttemptsPerEpisode: maxAttempts),
                now: { [weak self] in self?.now ?? Date() }
            )
            coordinator.recoveryRequest = { [weak self] reason in
                self?.recoveryRequests.append(reason)
                return .initiated
            }
            coordinator.onEpisodeEvent = { [weak self] event in
                self?.events.append(event)
            }
        }

        /// 0.1s of active system audio per call; the tracker declares
        /// degradation after 3s (48000 samples) of active system audio with no
        /// mic signal.
        func systemActive(seconds: Int) {
            let chunks = seconds * 10
            for _ in 0..<chunks {
                let snapshot = tracker.noteSystemSamples(Array(repeating: 2000, count: 1600), now: now)
                coordinator.process(snapshot)
                now = now.addingTimeInterval(0.1)
            }
        }

        func micSignal() {
            let snapshot = tracker.noteRawMicSamples(Array(repeating: 1000, count: 1600), now: now)
            coordinator.process(snapshot)
        }

        func advance(seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }

        func micSilence() {
            let snapshot = tracker.noteRawMicSamples(Array(repeating: 0, count: 1600), now: now)
            coordinator.process(snapshot)
        }
    }

    @Test("confirmed missing callbacks start one episode and one recovery attempt")
    func episodeStartsOnConfirmedDegradation() {
        let harness = Harness()
        harness.systemActive(seconds: 4)

        #expect(harness.events.count == 1)
        #expect(harness.events.first?.kind == .degraded)
        #expect(harness.events.first?.reason == "system_audio_active_without_mic_callbacks")
        #expect(harness.events.first?.state == MeetingMicHealthState.micCallbacksMissing.rawValue)
        #expect(harness.recoveryRequests == ["system_audio_active_without_mic_callbacks"])
    }

    @Test("continued degradation does not emit duplicate events or premature retries")
    func continuedDegradationIsSilent() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.systemActive(seconds: 5)

        #expect(harness.events.count == 1)
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("degradation mode change within an episode counts a flap without a new episode")
    func modeChangeCountsFlap() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSilence()
        harness.systemActive(seconds: 4)

        #expect(harness.events.count == 1)
        #expect(harness.recoveryRequests.count == 1)
        // micAllZeroWhileSystemActive follows micCallbacksMissing: same episode.
        #expect(harness.coordinator.hasActiveEpisode)
    }

    @Test("recovery retries after cooldown and stops at the attempt cap")
    func recoveryCooldownAndCap() {
        let harness = Harness(cooldown: 0.5, maxAttempts: 2)
        harness.systemActive(seconds: 3) // exactly reaches the 3s confirmation threshold
        #expect(harness.recoveryRequests.count == 1)

        harness.systemActive(seconds: 1) // 1s > 0.5s cooldown
        #expect(harness.recoveryRequests.count == 2)

        harness.systemActive(seconds: 1)
        #expect(harness.recoveryRequests.count == 2) // cap reached
    }

    @Test("signal recovery closes the episode with exactly one recovered event after sustained health")
    func recoveryClosesEpisode() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()
        harness.advance(seconds: 10)
        harness.micSignal()

        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
        #expect(harness.events.last?.recoveryAttempts == 1)
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("a healthy blip does not close the episode or reset the retry budget")
    func healthyBlipKeepsEpisodeOpen() {
        let harness = Harness(cooldown: 0.5, maxAttempts: 2)
        harness.systemActive(seconds: 3)           // episode starts at t=3, attempt 1
        harness.micSignal()                        // healthy blip (not sustained)
        harness.micSilence()                       // mic goes all-zero again
        harness.systemActive(seconds: 4)           // re-degrades (zero-mic) at ~t=6: flap, attempt 2

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.recoveryRequests.count == 2)
        #expect(harness.coordinator.hasActiveEpisode)

        harness.systemActive(seconds: 2)           // still degraded; budget exhausted
        #expect(harness.recoveryRequests.count == 2)
    }

    @Test("a second episode after sustained recovery is a new episode")
    func secondEpisodeIsDistinct() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()
        harness.advance(seconds: 10)
        harness.micSignal()
        harness.systemActive(seconds: 4)

        #expect(harness.events.map(\.kind) == [.degraded, .recovered, .degraded])
        #expect(harness.events[0].episodeID != harness.events[2].episodeID)
    }

    @Test("meeting ending after a healthy blip closes as recovered, not unrecovered")
    func meetingEndAfterHealthyBlipIsRecovered() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()                        // healthy but not sustained
        harness.coordinator.finishMeeting()

        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
    }

    @Test("a recovery reserved before the episode closed is never dispatched")
    func closedEpisodeInvalidatesPendingRecovery() {
        let harness = Harness()
        harness.coordinator.onEpisodeEvent = { [weak harness] event in
            harness?.events.append(event)
            guard let harness, event.kind == .degraded else { return }
            // Recover synchronously inside the event callback, before the
            // coordinator dispatches the reserved recovery.
            harness.micSignal()
            harness.advance(seconds: 10)
            harness.micSignal()
        }
        harness.systemActive(seconds: 4)

        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("meeting ending while degraded emits one unrecovered event")
    func meetingEndWhileDegradedIsTerminal() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.coordinator.finishMeeting()

        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("finishMeeting without an episode is silent")
    func finishMeetingWithoutEpisode() {
        let harness = Harness()
        harness.micSignal()
        harness.coordinator.finishMeeting()
        #expect(harness.events.isEmpty)
    }

    @Test("snapshots processed after finishMeeting cannot open a dangling episode")
    func lateSnapshotsAfterFinishMeetingAreIgnored() {
        // Regression test for the stop()-ordering race: a sample callback
        // enqueued before teardown can run after finishMeeting(); it must not
        // open an episode that never sees a terminal event.
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.coordinator.finishMeeting()
        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])

        harness.systemActive(seconds: 4)
        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])
        #expect(harness.recoveryRequests.count == 1)
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("ordinary mic silence without system audio never starts an episode, even past the confirmation window")
    func quietRoomIsNotDegraded() {
        let harness = Harness()
        // Feed zero mic samples for longer than the detector's 3s confirmation
        // threshold, with no system audio present.
        for _ in 0..<40 {
            harness.micSilence()
            harness.advance(seconds: 0.1)
        }
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("muted input at confirmation suppresses the episode and signals once")
    func mutedInputSuppressesEpisode() {
        let harness = Harness()
        var mutedSignals = 0
        harness.coordinator.isInputMuted = { true }
        harness.coordinator.onUserMuted = { mutedSignals += 1 }

        harness.systemActive(seconds: 4)
        harness.systemActive(seconds: 4)

        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
        #expect(mutedSignals == 1)
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("un-muting while still degraded opens the episode then")
    func unmuteWhileDegradedOpensEpisode() {
        let harness = Harness()
        var muted = true
        harness.coordinator.isInputMuted = { muted }

        harness.systemActive(seconds: 4) // muted: suppressed
        #expect(harness.events.isEmpty)

        muted = false
        harness.advance(seconds: 1.5)      // past the 1Hz mute-read throttle
        harness.systemActive(seconds: 1)   // still degraded, no longer muted

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("no mute reads happen while an episode is open")
    func noMuteReadsWhileEpisodeOpen() {
        let harness = Harness()
        var reads = 0
        harness.coordinator.isInputMuted = { reads += 1; return false }

        harness.systemActive(seconds: 3)   // episode opens at t=3
        let readsAtOpen = reads
        harness.systemActive(seconds: 10)  // episode open: zero further reads

        #expect(readsAtOpen == 1)
        #expect(reads == 1)
    }

    @Test("muted classification does not latch past a healthy stretch")
    func mutedClassificationDoesNotLatch() {
        let harness = Harness()
        var muted = true
        harness.coordinator.isInputMuted = { muted }

        harness.systemActive(seconds: 4)   // muted episode suppressed
        muted = false
        harness.micSignal()                // healthy
        harness.systemActive(seconds: 4)   // new degradation, unmuted

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("unavailable recovery counts toward the cap so refusals cannot churn forever")
    func unavailableRecoveryCountsTowardCap() {
        let harness = Harness(cooldown: 0.5, maxAttempts: 2)
        var requestCount = 0
        harness.coordinator.recoveryRequest = { _ in
            requestCount += 1
            return .unavailable
        }
        harness.systemActive(seconds: 3)   // dispatch #1
        harness.systemActive(seconds: 1)   // past cooldown: dispatch #2
        harness.systemActive(seconds: 2)   // cap reached: no more

        #expect(requestCount == 2)
        #expect(harness.events.first?.recoveryAttempts == 0) // measured at episode start
    }

    @Test("external degradation opens an episode and drives recovery")
    func externalDegradationOpensEpisode() {
        let harness = Harness()
        harness.coordinator.noteExternalDegradation(reason: "mic_callbacks_stale_while_system_tap_dead")

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.events.first?.reason == "mic_callbacks_stale_while_system_tap_dead")
        #expect(harness.recoveryRequests.count == 1)
        #expect(harness.coordinator.hasActiveEpisode)
    }

    @Test("external degradation while an episode is open does not double-open")
    func externalDegradationWhileOpenIsIgnored() {
        let harness = Harness()
        harness.systemActive(seconds: 4) // tracker-driven episode open
        harness.coordinator.noteExternalDegradation(reason: "mic_callbacks_stale_while_system_tap_dead")

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("external degradation after finishMeeting is ignored")
    func externalDegradationAfterFinishIsIgnored() {
        let harness = Harness()
        harness.coordinator.finishMeeting()
        harness.coordinator.noteExternalDegradation(reason: "mic_callbacks_stale_while_system_tap_dead")

        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("recovery dispatch defers while a route transition is settling")
    func recoveryDefersWhileRouteSettles() {
        let harness = Harness()
        var settling = true
        harness.coordinator.isRouteSettling = { settling }
        var deferredWork: (() -> Void)?
        harness.coordinator.scheduleAfter = { _, work in deferredWork = work }

        harness.systemActive(seconds: 4) // episode starts; recovery reserved
        #expect(harness.recoveryRequests.isEmpty) // deferred, not dispatched

        settling = false
        deferredWork?() // settle window elapsed
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("transient recovery refusals are throttled by the cooldown, not per-snapshot")
    func transientRefusalsRespectCooldown() {
        // Simulates a handoff already pending: the recorder declines (false)
        // while degradation continues. The coordinator must not re-dispatch
        // per snapshot — the refusal keeps its back-pressure timestamp.
        let harness = Harness() // default 15s cooldown
        var requestCount = 0
        harness.coordinator.recoveryRequest = { _ in
            requestCount += 1
            return .busy
        }
        harness.systemActive(seconds: 3)   // episode start: dispatch #1 at t=3
        harness.systemActive(seconds: 10)  // t=3→13, all within cooldown
        #expect(requestCount == 1)

        harness.systemActive(seconds: 6)   // t=13→19: cooldown elapsed at t=18
        #expect(requestCount == 2)
    }

    @Test("episode event callbacks may re-enter process without deadlock")
    func episodeCallbackReentryDoesNotDeadlock() {
        let harness = Harness()
        var reentered = false
        harness.coordinator.onEpisodeEvent = { [weak harness] event in
            harness?.events.append(event)
            guard let harness, !reentered else { return }
            reentered = true
            // Re-enter synchronously, as if a consumer fed a health snapshot back.
            harness.micSignal()
        }
        harness.systemActive(seconds: 4) // must complete without deadlock
        #expect(harness.events.contains { $0.kind == .degraded })
    }

    @Test("recovery request callback may re-enter process without deadlock")
    func recoveryCallbackReentryDoesNotDeadlock() {
        let harness = Harness()
        harness.coordinator.recoveryRequest = { [weak harness] reason in
            harness?.recoveryRequests.append(reason)
            // Synchronous re-entry, as if a recovery drove an audio callback
            // straight back into the coordinator.
            harness?.micSignal()
            return .initiated
        }
        harness.systemActive(seconds: 4)
        #expect(!harness.recoveryRequests.isEmpty)
    }
}

struct RecentMeetingIdentityGateTests {
    @Test("authorized meetings pass until evicted past capacity")
    func capacityEviction() {
        var gate = RecentMeetingIdentityGate(capacity: 2)
        gate.authorize(1)
        gate.authorize(2)
        #expect(gate.allows(1))
        gate.authorize(3)
        #expect(!gate.allows(1))
        #expect(gate.allows(3))
    }

    @Test("a stopped meeting remains authorized alongside a newer stopped meeting")
    func twoStoppedMeetingsStayAuthorized() {
        var gate = RecentMeetingIdentityGate()
        gate.authorize(10)
        gate.authorize(11)
        gate.authorize(12)
        #expect(gate.allows(10))
        #expect(gate.allows(11))
        #expect(gate.allows(12))
        #expect(!gate.allows(99))
    }

    @Test("re-authorizing an existing member does not evict")
    func reauthorizationIsIdempotent() {
        var gate = RecentMeetingIdentityGate(capacity: 2)
        gate.authorize(1)
        gate.authorize(2)
        gate.authorize(1)
        gate.authorize(3)
        // Order is 1,2,3? No: re-authorize(1) is a no-op, so 1 is oldest and evicted.
        #expect(!gate.allows(1))
        #expect(gate.allows(2))
        #expect(gate.allows(3))
    }
}
