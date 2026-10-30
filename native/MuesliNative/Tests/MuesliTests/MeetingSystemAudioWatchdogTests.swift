import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("System audio recovery episodes")
struct MeetingSystemAudioWatchdogTests {
    private final class Harness {
        var watchdog: MeetingSystemAudioWatchdog!
        var events: [MeetingSystemAudioHealthEvent] = []
        var recoveryRequests: [String] = []
        var micBridgeReasons: [String] = []
        var now = Date(timeIntervalSince1970: 2_000_000)
        var captureActive = true
        var paused = false
        var routeSettling = false
        var micLastCallbackAt: Date?
        var acceptsRecovery = true

        init(policy: MeetingSystemAudioWatchdog.Policy = .default) {
            watchdog = MeetingSystemAudioWatchdog(
                policy: policy,
                now: { [weak self] in self?.now ?? Date() },
                deadlineScheduler: { _, _ in }
            )
            watchdog.isCaptureActive = { [weak self] in self?.captureActive ?? false }
            watchdog.isPaused = { [weak self] in self?.paused ?? false }
            watchdog.isRouteSettling = { [weak self] in self?.routeSettling ?? false }
            watchdog.lastMicCallbackAt = { [weak self] in self?.micLastCallbackAt }
            watchdog.recoveryRequest = { [weak self] reason in
                self?.recoveryRequests.append(reason)
                return self?.acceptsRecovery ?? false
            }
            watchdog.onMicBlindnessDegradation = { [weak self] reason in
                self?.micBridgeReasons.append(reason)
            }
            watchdog.onEpisodeEvent = { [weak self] event in
                self?.events.append(event)
            }
        }

        func tick() {
            watchdog.tick()
            now = now.addingTimeInterval(1)
        }

        func fail(_ reason: String = "rebuild_exhausted: tapCreationFailed") {
            captureActive = false
            watchdog.noteCaptureFailure(reason: reason)
        }
    }

    @Test("an exhausted verification window cannot reopen from its own rebuild error")
    func exhaustedWindowRetainsBudget() {
        var now = Date(timeIntervalSince1970: 1_000)
        var scheduled: [DispatchWorkItem] = []
        var requests = 0
        var events: [MeetingSystemAudioHealthKind] = []
        let watchdog = MeetingSystemAudioWatchdog(
            now: { now }, deadlineScheduler: { _, item in scheduled.append(item) }
        )
        watchdog.recoveryRequest = { _ in requests += 1; return true }
        watchdog.onEpisodeEvent = { events.append($0.kind) }
        watchdog.noteCaptureFailure(reason: "driver failure")
        for (index, elapsed) in [3.0, 8, 20, 40, 60].enumerated() {
            now = Date(timeIntervalSince1970: 1_000 + elapsed)
            scheduled[index].perform()
        }
        let attempts = requests
        let deadlines = scheduled.count
        watchdog.noteCaptureFailure(reason: "last rebuild also failed")
        #expect(requests == attempts)
        #expect(scheduled.count == deadlines)
        #expect(events == [.degraded, .unrecovered])
        watchdog.finishMeeting()
        #expect(events == [.degraded, .unrecovered])
    }

    @Test("ordinary capture ticks never infer failure from missing callbacks")
    func ordinaryTicksAreInert() {
        let harness = Harness()
        for _ in 0..<120 { harness.tick() }

        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("inactive capture alone is not positive failure evidence")
    func inactiveCaptureDoesNotOpenEpisode() {
        let harness = Harness()
        harness.captureActive = false
        harness.micLastCallbackAt = harness.now.addingTimeInterval(-10)
        for _ in 0..<20 { harness.tick() }

        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
        #expect(harness.micBridgeReasons.isEmpty)
    }

    @Test("stale microphone after a settled route event bridges into mic recovery")
    func routeEventBridgesStaleMic() {
        let harness = Harness()
        harness.micLastCallbackAt = harness.now.addingTimeInterval(-10)
        harness.watchdog.noteRouteChange()

        harness.tick()

        #expect(harness.micBridgeReasons == ["mic_callbacks_stale_after_audio_route_change"])
        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }

    @Test("fresh microphone after a route event needs no recovery")
    func routeEventAcceptsFreshMic() {
        let harness = Harness()
        harness.micLastCallbackAt = harness.now
        harness.watchdog.noteRouteChange()

        harness.tick()

        #expect(harness.micBridgeReasons.isEmpty)
    }

    @Test("route-event microphone probe waits for route settling")
    func routeEventProbeWaitsForSettle() {
        let harness = Harness()
        harness.micLastCallbackAt = harness.now.addingTimeInterval(-10)
        harness.routeSettling = true
        harness.watchdog.noteRouteChange()

        harness.tick()
        #expect(harness.micBridgeReasons.isEmpty)

        harness.routeSettling = false
        harness.tick()
        #expect(harness.micBridgeReasons == ["mic_callbacks_stale_after_audio_route_change"])
    }

    @Test("post-route verification catches a stall after an initially fresh callback")
    func delayedStallAfterFreshCallback() {
        let harness = Harness()
        harness.micLastCallbackAt = harness.now
        harness.watchdog.noteRouteChange()
        harness.tick()
        #expect(harness.micBridgeReasons.isEmpty)
        harness.now = harness.now.addingTimeInterval(30)
        harness.tick()
        #expect(harness.micBridgeReasons == ["mic_callbacks_stale_after_audio_route_change"])
        harness.watchdog.suspendVerification()
        harness.tick()
        #expect(harness.micBridgeReasons.count == 1)
    }

    @Test("explicit capture failure opens one episode and requests recovery")
    func explicitFailureOpensEpisode() {
        let harness = Harness()
        harness.fail()

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.events.first?.reason == "rebuild_exhausted: tapCreationFailed")
        #expect(harness.recoveryRequests == ["rebuild_exhausted: tapCreationFailed"])
        #expect(harness.watchdog.hasActiveEpisode)
    }

    @Test("repeated failure reports do not duplicate an active episode")
    func repeatedFailureDoesNotDuplicateEpisode() {
        let harness = Harness()
        harness.fail()
        harness.watchdog.noteCaptureFailure(reason: "second failure")

        #expect(harness.events.map(\.kind) == [.degraded])
        #expect(harness.recoveryRequests.count == 1)
    }

    @Test("successful recorder state closes an episode after two ticks")
    func recoveryClosesEpisode() {
        let harness = Harness()
        harness.fail()
        harness.captureActive = true

        harness.tick()
        #expect(harness.events.map(\.kind) == [.degraded])
        harness.tick()

        #expect(harness.events.map(\.kind) == [.degraded, .recovered])
        #expect(harness.events.last?.recoveryAttempts == 1)
        #expect(!harness.watchdog.hasActiveEpisode)
    }

    @Test("retries are cooldown-limited and capped per explicit failure episode")
    func retriesAreBounded() {
        let harness = Harness(policy: .init(
            recoveredAfterTicks: 2,
            attemptCooldown: 5,
            maxAttemptsPerEpisode: 3
        ))
        harness.fail()
        for _ in 0..<6 { harness.tick() }
        #expect(harness.recoveryRequests.count == 2)
        for _ in 0..<5 { harness.tick() }
        #expect(harness.recoveryRequests.count == 3)
        for _ in 0..<20 { harness.tick() }
        #expect(harness.recoveryRequests.count == 3)
    }

    @Test("a rejected recovery keeps cooldown back-pressure without burning budget")
    func rejectedRecoveryKeepsCooldown() {
        let harness = Harness(policy: .init(
            recoveredAfterTicks: 2,
            attemptCooldown: 5,
            maxAttemptsPerEpisode: 3
        ))
        harness.acceptsRecovery = false
        harness.fail()
        #expect(harness.recoveryRequests.count == 1)

        for _ in 0..<5 { harness.tick() }
        #expect(harness.recoveryRequests.count == 1)
        harness.tick()
        #expect(harness.recoveryRequests.count == 2)
    }

    @Test("route settling pauses retries for an explicit failure")
    func routeSettlingPausesRetries() {
        let harness = Harness(policy: .init(
            recoveredAfterTicks: 2,
            attemptCooldown: 2,
            maxAttemptsPerEpisode: 3
        ))
        harness.fail()
        harness.routeSettling = true
        for _ in 0..<10 { harness.tick() }
        #expect(harness.recoveryRequests.count == 1)

        harness.routeSettling = false
        harness.tick()
        #expect(harness.recoveryRequests.count == 2)
    }

    @Test("mic blindness bridge requires a confirmed tap failure and fires once")
    func micBlindnessBridgeFiresOnce() {
        let harness = Harness()
        harness.micLastCallbackAt = harness.now.addingTimeInterval(-10)
        harness.fail()
        for _ in 0..<4 { harness.tick() }

        #expect(harness.micBridgeReasons == ["mic_callbacks_stale_while_system_tap_dead"])
    }

    @Test("capture failure while paused opens no episode")
    func captureFailureWhilePausedIsIgnored() {
        let harness = Harness()
        harness.paused = true
        harness.fail()

        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
        #expect(!harness.watchdog.hasActiveEpisode)
    }

    @Test("meeting end terminalizes only an explicit open failure episode")
    func meetingEndTerminalizesOpenEpisode() {
        let harness = Harness()
        harness.fail()
        harness.watchdog.finishMeeting()

        #expect(harness.events.map(\.kind) == [.degraded, .unrecovered])
        #expect(!harness.watchdog.hasActiveEpisode)
    }

    @Test("ticks after finish are ignored")
    func ticksAfterFinishAreIgnored() {
        let harness = Harness()
        harness.watchdog.finishMeeting()
        harness.captureActive = false
        for _ in 0..<20 { harness.tick() }

        #expect(harness.events.isEmpty)
        #expect(harness.recoveryRequests.isEmpty)
    }
}
