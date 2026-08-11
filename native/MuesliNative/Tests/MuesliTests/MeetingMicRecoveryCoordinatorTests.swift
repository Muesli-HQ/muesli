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
                return true
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

    @Test("signal recovery closes the episode with exactly one recovered event")
    func recoveryClosesEpisode() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()
        harness.micSignal()

        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
        #expect(harness.events.last?.recoveryAttempts == 1)
        #expect(!harness.coordinator.hasActiveEpisode)
    }

    @Test("a second episode after recovery is a new episode")
    func secondEpisodeIsDistinct() {
        let harness = Harness()
        harness.systemActive(seconds: 4)
        harness.micSignal()
        harness.systemActive(seconds: 4)

        #expect(harness.events.map(\.kind) == [.degraded, .recovered, .degraded])
        #expect(harness.events[0].episodeID != harness.events[2].episodeID)
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

    @Test("ordinary mic signal without system audio never starts an episode")
    func quietRoomIsNotDegraded() {
        let harness = Harness()
        harness.micSilence()
        harness.micSilence()
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("recovery request returning false does not count an attempt")
    func uninitiatedRecoveryIsNotCounted() {
        let harness = Harness(cooldown: 0.5, maxAttempts: 1)
        harness.coordinator.recoveryRequest = { _ in false }
        harness.systemActive(seconds: 4)

        #expect(harness.events.count == 1)
        #expect(harness.events.first?.recoveryAttempts == 0)
    }
}
