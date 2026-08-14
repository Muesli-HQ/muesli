import Foundation
import Testing
@testable import MuesliNativeApp

struct MeetingSystemAudioWatchdogTests {
    private final class Harness {
        var watchdog: MeetingSystemAudioWatchdog!
        var events: [MeetingSystemAudioHealthEvent] = []
        var recoveryRequests: [String] = []
        var micBridgeReasons: [String] = []
        var now = Date(timeIntervalSince1970: 2_000_000)
        var heartbeat: UInt64 = 0
        var captureActive = true
        var paused = false
        var micLastCallbackAt: Date?

        init(policy: MeetingSystemAudioWatchdog.Policy = .default) {
            watchdog = MeetingSystemAudioWatchdog(policy: policy, now: { [weak self] in self?.now ?? Date() })
            watchdog.captureHeartbeat = { [weak self] in self?.heartbeat ?? 0 }
            watchdog.isCaptureActive = { [weak self] in self?.captureActive ?? false }
            watchdog.isPaused = { [weak self] in self?.paused ?? false }
            watchdog.lastMicCallbackAt = { [weak self] in self?.micLastCallbackAt }
            watchdog.recoveryRequest = { [weak self] reason in
                self?.recoveryRequests.append(reason)
                return true
            }
            watchdog.onMicBlindnessDegradation = { [weak self] reason in
                self?.micBridgeReasons.append(reason)
            }
            watchdog.onEpisodeEvent = { [weak self] event in
                self?.events.append(event)
            }
        }

        /// One watchdog tick with the heartbeat advancing (healthy capture).
        func aliveTick() {
            heartbeat &+= 1
            watchdog.tick()
            now = now.addingTimeInterval(1)
        }

        /// One tick with no heartbeat advance (stalled capture).
        func stalledTick() {
            watchdog.tick()
            now = now.addingTimeInterval(1)
        }
    }

    @Test("heartbeat advancing keeps the pipeline healthy")
    func advancingHeartbeatIsHealthy() {
        let harness = Harness()
        for _ in 0..<10 { harness.aliveTick() }
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("a stalled heartbeat opens one episode and requests one immediate rebuild")
    func stallOpensEpisode() {
        let harness = Harness()
        harness.aliveTick() // establish heartbeat
        for _ in 0..<3 { harness.stalledTick() }

        #expect(harness.events.count == 1)
        #expect(harness.events.first?.kind == .degraded)
        #expect(harness.events.first?.reason == "capture_heartbeat_stalled")
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("capture inactive (recorder stopped reporting) is treated as dead")
    func inactiveCaptureIsDead() {
        let harness = Harness()
        harness.captureActive = false
        harness.watchdog.tick()
        #expect(harness.events.first?.kind == .degraded)
    }

    @Test("resumed heartbeat closes the episode after two alive ticks")
    func recoveryClosesEpisode() {
        let harness = Harness()
        harness.aliveTick()
        harness.stalledTick()
        harness.stalledTick()
        harness.aliveTick()
        #expect(harness.events.map(\.kind) == [.degraded])
        harness.aliveTick()
        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
        #expect(harness.events.last?.recoveryAttempts == 1)
        #expect(!harness.watchdog.hasActiveEpisode)
    }

    @Test("retries are cooldown-limited and capped per episode")
    func retriesAreBounded() {
        let harness = Harness(policy: .init(
            stallThreshold: 2,
            recoveredAfterTicks: 2,
            attemptCooldown: 5,
            maxAttemptsPerEpisode: 3
        ))
        harness.aliveTick()
        harness.stalledTick() // episode + attempt 1
        for _ in 0..<4 { harness.stalledTick() } // within cooldown
        #expect(harness.recoveryRequests.count == 1)
        harness.stalledTick() // t=+5 past first attempt → attempt 2
        harness.stalledTick() // t=+6 < cooldown since attempt 2
        #expect(harness.recoveryRequests.count == 2)
        for _ in 0..<5 { harness.stalledTick() } // attempt 3 at t=+10s
        #expect(harness.recoveryRequests.count == 3)
        for _ in 0..<6 { harness.stalledTick() } // cap reached
        #expect(harness.recoveryRequests.count == 3)
    }

    @Test("terminal capture failure opens an episode immediately with an immediate rebuild")
    func captureFailureOpensEpisode() {
        let harness = Harness()
        harness.aliveTick()
        harness.watchdog.noteCaptureFailure(reason: "rebuild_exhausted: tapCreationFailed")

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.events.first?.reason.contains("rebuild_exhausted") == true)
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("meeting end with an open episode terminalizes as unrecovered")
    func meetingEndTerminalizes() {
        let harness = Harness()
        harness.aliveTick()
        harness.stalledTick()
        harness.stalledTick() // past the 2s stall threshold: episode open
        harness.watchdog.finishMeeting()

        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])
        #expect(!harness.watchdog.hasActiveEpisode)
    }

    @Test("ticks after finishMeeting are ignored")
    func ticksAfterFinishAreIgnored() {
        let harness = Harness()
        harness.watchdog.finishMeeting()
        harness.stalledTick()
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("paused capture suppresses evaluation entirely")
    func pauseSuppressesEvaluation() {
        let harness = Harness()
        harness.aliveTick()
        harness.paused = true
        harness.stalledTick()
        harness.stalledTick()
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("route transitions suppress stall evaluation while settling")
    func routeSettlingSuppressesEvaluation() {
        let harness = Harness()
        var settling = false
        harness.watchdog.isRouteSettling = { settling }
        harness.aliveTick()

        settling = true
        harness.stalledTick()
        harness.stalledTick()
        harness.stalledTick()
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)

        settling = false
        harness.stalledTick()
        harness.stalledTick()
        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("mic blindness bridge fires once when the tap is dead and mic callbacks are stale")
    func micBlindnessBridgeFiresOnce() {
        let harness = Harness()
        harness.aliveTick()
        harness.micLastCallbackAt = harness.now.addingTimeInterval(-10) // stale mic
        harness.stalledTick() // episode opens
        harness.stalledTick() // bridge fires
        harness.stalledTick()
        #expect(harness.micBridgeReasons == ["mic_callbacks_stale_while_system_tap_dead"])
    }

    @Test("no bridge while the mic is alive")
    func noBridgeWhenMicAlive() {
        let harness = Harness()
        harness.aliveTick()
        harness.micLastCallbackAt = harness.now
        harness.stalledTick()
        harness.stalledTick()
        harness.stalledTick()
        #expect(harness.micBridgeReasons.isEmpty)
    }

    @Test("capture failure while paused opens no episode and requests nothing")
    func captureFailureWhilePausedIsIgnored() {
        let harness = Harness()
        harness.paused = true
        harness.watchdog.noteCaptureFailure(reason: "rebuild_exhausted: tapCreationFailed")
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
        #expect(!harness.watchdog.hasActiveEpisode)
    }

    @Test("a rejected recovery request refunds the attempt but keeps back-pressure")
    func rejectedRecoveryKeepsCooldown() {
        let harness = Harness(policy: .init(
            stallThreshold: 2,
            recoveredAfterTicks: 2,
            attemptCooldown: 5,
            maxAttemptsPerEpisode: 3
        ))
        var requestCount = 0
        harness.watchdog.recoveryRequest = { _ in
            requestCount += 1
            return false // rejected (paused / rebuild in flight)
        }

        harness.aliveTick()
        harness.stalledTick()
        harness.stalledTick() // episode confirmed → dispatch → rejected
        #expect(requestCount == 1)

        harness.stalledTick() // inside cooldown: nothing
        #expect(requestCount == 1)

        for _ in 0..<4 { harness.stalledTick() } // cooldown elapses → one more
        #expect(requestCount == 2)
    }
}
