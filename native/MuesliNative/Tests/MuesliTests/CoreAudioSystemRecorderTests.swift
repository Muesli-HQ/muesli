import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("CoreAudioSystemRecorder")
struct CoreAudioSystemRecorderTests {

    @Test("global tap description captures process mix except Muesli")
    func globalTapDescriptionExcludesSelfAudio() {
        let tapDescription = CoreAudioSystemRecorder.makeGlobalTapDescription(
            excludingProcessID: 123,
            name: "Muesli Global Test Tap"
        )

        #expect(tapDescription.name == "Muesli Global Test Tap")
        #expect(tapDescription.deviceUID == nil)
        #expect(tapDescription.stream == nil)
        #expect(tapDescription.processes == [123])
        #expect(tapDescription.isPrivate)
        #expect(tapDescription.muteBehavior == .unmuted)
    }

    @Test("aggregate device description includes tap with drift compensation")
    func aggregateDeviceDescriptionIncludesTap() throws {
        let description = CoreAudioSystemRecorder.makeAggregateDeviceDescription(
            tapUID: "tap-uid",
            aggregateUID: "aggregate-uid"
        )

        #expect(description[kAudioAggregateDeviceNameKey] as? String == "Muesli System Audio")
        #expect(description[kAudioAggregateDeviceUIDKey] as? String == "aggregate-uid")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)

        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        let tap = try #require(taps.first)
        #expect(tap[kAudioSubTapUIDKey] as? String == "tap-uid")
        #expect(tap[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }

    @Test("rebuild retry policy backs off then exhausts")
    func rebuildRetryPolicyBackoff() {
        let policy = RebuildRetryPolicy.default
        #expect(policy.nextDelay(afterFailures: 0) == 2)
        #expect(policy.nextDelay(afterFailures: 1) == 5)
        #expect(policy.nextDelay(afterFailures: 2) == nil)
        #expect(policy.nextDelay(afterFailures: 10) == nil)
    }

    @Test("route notifications debounce into a single rebuild once churn settles")
    func routeChangeDebouncesRebuild() async throws {
        let recorder = CoreAudioSystemRecorder()
        recorder.testing_setRecording(true)
        var attempts = 0
        recorder.createAndStartForTesting = { attempts += 1 }

        CoreAudioSystemRecorder.routeSettleDelay = 0.05
        defer { CoreAudioSystemRecorder.routeSettleDelay = 1.5 }

        // A BT transition emits several notifications; each resets the settle
        // timer, so only one rebuild should run after they stop.
        recorder.restartTapForDefaultOutputDeviceChange()
        recorder.restartTapForDefaultOutputDeviceChange()
        recorder.restartTapForDefaultOutputDeviceChange()
        try await waitForCondition { attempts == 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(attempts == 1)
    }

    @Test("CoreAudio tap backend supports heartbeat monitoring; SCK fallback does not")
    func heartbeatCapabilityByBackend() {
        #expect(CoreAudioSystemRecorder().supportsHeartbeatMonitoring)
        #expect(!SystemAudioRecorder().supportsHeartbeatMonitoring)
    }

    @Test("failed rebuild retries then succeeds without a terminal failure")
    func rebuildRetriesThenSucceeds() async throws {
        let recorder = CoreAudioSystemRecorder()
        recorder.testing_setRecording(true)
        var attempts = 0
        recorder.createAndStartForTesting = {
            attempts += 1
            if attempts < 3 { throw NSError(domain: "test", code: 1) }
        }
        var failures = 0
        recorder.onCaptureFailure = { _ in failures += 1 }

        let fast = RebuildRetryPolicy(delays: [0.02, 0.05, 0.05])
        CoreAudioSystemRecorder.rebuildRetryPolicy = fast
        defer { CoreAudioSystemRecorder.rebuildRetryPolicy = .default }

        recorder.attemptTapRebuild(reason: "test")
        try await waitForCondition { attempts == 3 && !recorder.isRebuilding }

        #expect(attempts == 3)
        #expect(failures == 0)
        #expect(!recorder.captureIsDead)
    }

    @Test("exhausted rebuild stays recoverable: watchdog rebuild after terminal failure succeeds")
    func terminalFailureRemainsRecoverable() async throws {
        let recorder = CoreAudioSystemRecorder()
        recorder.testing_setRecording(true)
        var shouldFail = true
        var attempts = 0
        recorder.createAndStartForTesting = {
            attempts += 1
            if shouldFail { throw NSError(domain: "test", code: 1) }
        }
        var failures = 0
        recorder.onCaptureFailure = { _ in failures += 1 }

        let fast = RebuildRetryPolicy(delays: [0.02, 0.02, 0.02])
        CoreAudioSystemRecorder.rebuildRetryPolicy = fast
        defer { CoreAudioSystemRecorder.rebuildRetryPolicy = .default }

        recorder.attemptTapRebuild(reason: "test")
        try await waitForCondition { failures == 1 }
        #expect(recorder.captureIsDead)
        // Terminal state must remain recoverable (isRecording stays alive).
        #expect(recorder.rebuildForHealthRecovery(reason: "watchdog"))

        shouldFail = false
        try await waitForCondition { !recorder.captureIsDead && !recorder.isRebuilding }
        #expect(attempts >= 4)
    }

    private func waitForCondition(
        timeout: Duration = .seconds(5),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for recorder state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
