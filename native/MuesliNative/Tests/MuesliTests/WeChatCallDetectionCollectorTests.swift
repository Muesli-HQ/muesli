import Testing
@testable import MuesliNativeApp

@Suite("WeChat fail-closed production collector")
struct WeChatCallDetectionCollectorTests {
    @Test func injectedSyntheticConnectedEvidenceCannotActivateProductionCollector() async {
        let collector = WeChatCallDetectionCollector(probe: { WeChatCallDetectionFixtures.snapshot() })
        let adapter = WeChatCallDetectionAdapter(provider: collector, now: { WeChatCallDetectionFixtures.now })
        let result = await adapter.observe()
        #expect(result == .unavailable(.unsupported))
    }

    @Test func permissionAndSourceFailuresArePreserved() async {
        for reason in [CallDetectionUnavailableReason.permissionRequired, .noSource, .ambiguous, .sourceMismatch] {
            let collector = WeChatCallDetectionCollector(probe: { .unavailable(reason) })
            let adapter = WeChatCallDetectionAdapter(provider: collector, now: { WeChatCallDetectionFixtures.now })
            let result = await adapter.observe()
            #expect(result == .unavailable(reason))
        }
    }

    @Test func repeatedTimeoutsDoNotQueueMoreProbesAndSlotReleasesOnlyOnExit() async throws {
        let probe = WeChatCallDetectionControlledProvider()
        defer { Task { await probe.close() } }
        let collector = WeChatCallDetectionCollector(probe: { await probe.snapshot() })
        let adapter = WeChatCallDetectionAdapter(provider: collector, now: { WeChatCallDetectionFixtures.now }, timeout: .seconds(1))
        let initial = Task { await adapter.observe() }
        try await probe.waitForStarts(1)
        guard let timedOut = await weChatCallDetectionTaskValue(initial, onWatchdog: { await probe.close() }) else { return }
        #expect(timedOut == .unavailable(.timedOut))
        for _ in 0..<10 {
            let busy = await adapter.observe()
            #expect(busy == .unavailable(.timedOut))
        }
        let starts = await probe.started
        #expect(starts == 1)
        await probe.finish(1, with: .unavailable(.unsupported))
        // Wait for actual collector exit (not merely provider continuation resumption).
        guard await collectorExit(collector) else { return }
        let fresh = Task { await collector.snapshot() }
        try await probe.waitForStarts(2)
        await probe.finish(2, with: .unavailable(.unsupported))
        let result = await fresh.value
        guard case .unavailable(.unsupported) = result else {
            Issue.record("Expected unsupported after fresh probe"); return
        }
    }

    @Test func cancelledObservationRetainsCapacityUntilUnderlyingProbeExits() async throws {
        let probe = WeChatCallDetectionControlledProvider()
        defer { Task { await probe.close() } }
        let collector = WeChatCallDetectionCollector(probe: { await probe.snapshot() })
        let adapter = WeChatCallDetectionAdapter(provider: collector, now: { WeChatCallDetectionFixtures.now })
        let task = Task { await adapter.observe() }
        try await probe.waitForStarts(1)
        task.cancel()
        guard let cancelled = await weChatCallDetectionTaskValue(task, onWatchdog: { await probe.close() }) else { return }
        #expect(cancelled == .unavailable(.timedOut))
        for _ in 0..<10 {
            let busy = await adapter.observe()
            #expect(busy == .unavailable(.timedOut))
        }
        let starts = await probe.started
        #expect(starts == 1)
        await probe.finish(1, with: .unavailable(.unsupported))
        _ = await collectorExit(collector)
    }

    private func collectorExit(_ collector: WeChatCallDetectionCollector) async -> Bool {
        // Slot visibility is a production resource bound; polling never starts another probe.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while collector.isProbeInFlight && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard !collector.isProbeInFlight else {
            Issue.record("Collector failed to release capacity after underlying probe exit"); return false
        }
        return true
    }
}
