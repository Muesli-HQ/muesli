import Dispatch
import Foundation
import Testing
@testable import MuesliNativeApp

// Compiled semantic fixtures, not captured or verified LINE Accessibility trees.
@Suite("LINE call detection adapter")
struct LINECallDetectionAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(
        bundle: String = "jp.naver.line.mac", pid: Int32 = 42,
        launch: String = "launch-a", surface: String = "surface-a", origin: String? = nil
    ) -> CallDetectionSource {
        .init(bundleID: bundle, processID: pid, processLaunchID: launch, surfaceID: surface, origin: origin)
    }

    private func snapshot(
        kind: LINECallDetectionSurfaceKind = .connected,
        controls: Set<LINECallDetectionControl> = [.endCall, .mute],
        age: TimeInterval = 0, before: CallDetectionSource? = nil,
        after: CallDetectionSource? = nil, generation: String = "call-a",
        roster: CallDetectionRoster = .unknown
    ) -> LINECallDetectionSnapshot {
        .init(sourceBeforeRead: before ?? source(), sourceAfterRead: after ?? before ?? source(),
              observedAt: now.addingTimeInterval(-age), surfaces: [
                .init(kind: kind, callGeneration: generation, controls: controls, roster: roster)
              ])
    }

    private func adapter(_ snapshots: [LINECallDetectionSnapshot]) -> LINECallDetectionAdapter {
        let date = now
        return .init(provider: LINESequenceProvider(snapshots.map { .snapshot($0) }), now: { date })
    }

    private func observation(_ result: CallDetectionResult) throws -> CallDetectionObservation {
        guard case .observation(let value) = result else {
            Issue.record("Expected scoped connected observation, got \(result)")
            throw LINEFixtureError.noObservation
        }
        return value
    }

    @Test func connectedRequiresScopedControlsAndPreservesReadTime() async throws {
        let adapter = adapter([snapshot(age: 2)])
        let value = try observation(await adapter.observe())
        #expect(value.service == .line)
        #expect(value.phase == .connected)
        #expect(value.source == source())
        #expect(value.observedAt == now.addingTimeInterval(-2))
        #expect(value.evidence == [.scopedCallControls, .connectedState])
        #expect(value.roster == .unknown)
        #expect(UUID(uuidString: value.callToken) != nil)
    }

    @Test func idleVoiceNotesPreviewRingingEndedAndDiagnosticsNeverConnect() async {
        for kind in [
            .idle, .voiceNoteRecording, .voiceNotePlayback, .ringing, .prejoin,
            .ended, .settings, .deviceTest, .callLog, .unknown
        ] as [LINECallDetectionSurfaceKind] {
            #expect(await adapter([snapshot(kind: kind)]).observe() == .unavailable(.unsupported))
        }
        for controls in [[], [.mute], [.endCall]] as [Set<LINECallDetectionControl>] {
            #expect(await adapter([snapshot(controls: controls)]).observe() == .unavailable(.unsupported))
        }
    }

    @Test func freshnessBoundaryAndNonfiniteDatesFailClosed() async throws {
        _ = try observation(await adapter([snapshot(age: 5)]).observe())
        for age in [5.001, -0.001, .infinity, -.infinity, .nan] as [TimeInterval] {
            #expect(await adapter([snapshot(age: age)]).observe() == .unavailable(.stale))
        }
    }

    @Test func sourceMismatchRejectsChangedOrMissingScope() async {
        let invalid = [source(bundle: "other.app"), source(pid: 0), source(launch: ""),
                       source(surface: ""), source(origin: "https://line.me")]
        for value in invalid {
            #expect(await adapter([snapshot(before: value)]).observe() == .unavailable(.sourceMismatch))
        }
        for value in [source(pid: 43), source(launch: "launch-b"), source(surface: "surface-b")] {
            #expect(await adapter([snapshot(after: value)]).observe() == .unavailable(.sourceMismatch))
        }
        #expect(await adapter([snapshot(generation: "")]).observe() == .unavailable(.unsupported))
    }

    @Test func ambiguousSurfaceCannotSelectFrontmostCall() async {
        let single = snapshot()
        for kind in [.connected, .ringing, .prejoin, .unknown] as [LINECallDetectionSurfaceKind] {
            let value = LINECallDetectionSnapshot(
                sourceBeforeRead: source(), sourceAfterRead: source(), observedAt: now,
                surfaces: single.surfaces + [.init(kind: kind, callGeneration: "call-b", controls: [], roster: .unknown)]
            )
            #expect(await adapter([value]).observe() == .unavailable(.ambiguous))
        }
    }

    @Test func unavailableProviderResultIsPropagated() async {
        let date = now
        for reason in [.noSource, .permissionRequired, .unsupported, .timedOut, .ambiguous] as [CallDetectionUnavailableReason] {
            let adapter = LINECallDetectionAdapter(provider: LINESequenceProvider([.unavailable(reason)]), now: { date })
            #expect(await adapter.observe() == .unavailable(reason))
        }
    }

    @Test func tokenStableWithinCallAndRotatesAfterCallOrSourceReplacement() async throws {
        let nextSources = [source(), source(pid: 43), source(launch: "launch-b"), source(surface: "surface-b")]
        for next in nextSources {
            let adapter = adapter([snapshot(), snapshot(), snapshot(before: next, generation: next == source() ? "call-b" : "call-a")])
            let first = try observation(await adapter.observe())
            let same = try observation(await adapter.observe())
            let replacement = try observation(await adapter.observe())
            #expect(first.callToken == same.callToken)
            #expect(first.callToken != replacement.callToken)
        }
    }

    @Test func missingObservationIntervalRotatesSession() async throws {
        let clock = LINEFixtureClock(now)
        let first = snapshot()
        let later = LINECallDetectionSnapshot(
            sourceBeforeRead: source(), sourceAfterRead: source(),
            observedAt: now.addingTimeInterval(6), surfaces: first.surfaces
        )
        let adapter = LINECallDetectionAdapter(provider: LINESequenceProvider([.snapshot(first), .snapshot(later)]), now: { clock.read() })
        let initial = try observation(await adapter.observe())
        clock.set(now.addingTimeInterval(6))
        #expect(initial.callToken != (try observation(await adapter.observe())).callToken)
    }

    @Test func interruptedCallRotatesEvenWhenProviderReusesGeneration() async throws {
        for kind in [.ended, .ringing, .prejoin, .unknown] as [LINECallDetectionSurfaceKind] {
            let adapter = adapter([snapshot(), snapshot(kind: kind), snapshot()])
            let first = try observation(await adapter.observe())
            _ = await adapter.observe()
            let reconnected = try observation(await adapter.observe())
            #expect(first.callToken != reconnected.callToken)
        }
        let date = now
        let adapter = LINECallDetectionAdapter(provider: LINESequenceProvider([
            .snapshot(snapshot()), .unavailable(.permissionRequired), .snapshot(snapshot())
        ]), now: { date })
        let first = try observation(await adapter.observe())
        _ = await adapter.observe()
        #expect(first.callToken != (try observation(await adapter.observe())).callToken)
    }

    @Test func rosterKnowledgeIsPreservedWithoutInferringDepartures() async throws {
        let adapter = adapter([
            snapshot(roster: .unknown), snapshot(roster: .partial(["opaque-a"])),
            snapshot(roster: .complete(["opaque-a", "opaque-b"])), snapshot(roster: .partial(["opaque-a"]))
        ])
        let unknown = try observation(await adapter.observe())
        let partial = try observation(await adapter.observe())
        let complete = try observation(await adapter.observe())
        let reduced = try observation(await adapter.observe())
        #expect(unknown.roster == .unknown)
        #expect(partial.roster == .partial(["opaque-a"]))
        #expect(complete.roster == .complete(["opaque-a", "opaque-b"]))
        #expect(reduced.roster == .partial(["opaque-a"]))
        #expect(unknown.callToken == reduced.callToken)
        for roster in [.partial([]), .complete([]), .partial([""]), .complete([" "])] as [CallDetectionRoster] {
            #expect(await self.adapter([snapshot(roster: roster)]).observe() == .unavailable(.unsupported))
        }
    }
    @Test func timeoutReturnsWithoutWaitingForUncooperativeReadAndLimitsFlights() async {
        let date = now
        let provider = LINESuspendedProvider(.snapshot(snapshot()))
        let adapter = LINECallDetectionAdapter(provider: provider, now: { date }, timeout: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        let result = await adapter.observe()
        #expect(result == .unavailable(.timedOut))
        #expect(start.duration(to: clock.now) < .seconds(1))
        for _ in 0..<20 {
            #expect(await adapter.observe() == .unavailable(.timedOut))
        }
        #expect(await provider.readCount == 1)
        await provider.release()
    }

    @Test func callerCancellationReturnsNoObservationOrAdditionalProviderReads() async {
        let date = now
        let provider = LINESuspendedProvider(.snapshot(snapshot()))
        let adapter = LINECallDetectionAdapter(provider: provider, now: { date }, timeout: .seconds(5))
        let read = Task { await adapter.observe() }
        await provider.waitForRead()
        read.cancel()
        #expect(await read.value == .unavailable(.timedOut))
        for _ in 0..<10 {
            let cancelled = Task { await adapter.observe() }
            cancelled.cancel()
            #expect(await cancelled.value == .unavailable(.timedOut))
        }
        #expect(await provider.readCount == 1)
        await provider.release()
    }

    @Test func overlappingReadsInvalidateBothRatherThanReturnLateConnected() async {
        let date = now
        let provider = LINESuspendedProvider(.snapshot(snapshot()))
        let adapter = LINECallDetectionAdapter(provider: provider, now: { date })
        let first = Task { await adapter.observe() }
        await provider.waitForRead()
        #expect(await adapter.observe() == .unavailable(.ambiguous))
        await provider.release()
        #expect(await first.value == .unavailable(.ambiguous))
    }

    @Test func blockingProviderCancellationCannotHoldDeadlineOrRecovery() async throws {
        let date = now
        let latch = LINECancellationLatch()
        defer { latch.release() }
        let provider = LINERecoveryProvider(.snapshot(snapshot()), latch: latch)
        let adapter = LINECallDetectionAdapter(provider: provider, now: { date }, timeout: .milliseconds(100))
        let original = try observation(await adapter.observe())
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await adapter.observe() == .unavailable(.timedOut))
        // Broken synchronous cancellation waits two seconds on the latch.
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await adapter.observe() == .unavailable(.timedOut))
        latch.release()
        await provider.release()
        var recovered: CallDetectionObservation?
        for _ in 0..<100 {
            if case .observation(let value) = await adapter.observe() { recovered = value; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(recovered != nil)
        #expect(recovered?.callToken != original.callToken)
    }

    @Test func alreadyCancelledReadNeverInvokesProvider() async {
        let date = now
        let provider = LINESuspendedProvider(.snapshot(snapshot()))
        let adapter = LINECallDetectionAdapter(provider: provider, now: { date })
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await adapter.observe()
        }
        #expect(await read.value == .unavailable(.timedOut))
        #expect(await provider.readCount == 0)
    }

}

private enum LINEFixtureError: Error { case noObservation }

private actor LINESequenceProvider: LINECallDetectionSnapshotProviding {
    private var values: [LINECallDetectionCollection]
    init(_ values: [LINECallDetectionCollection]) { self.values = values }
    func snapshot() async -> LINECallDetectionCollection {
        guard !values.isEmpty else { return .unavailable(.noSource) }
        return values.removeFirst()
    }
}

// Deliberately ignores cancellation, to exercise the actual injected async boundary.
private actor LINESuspendedProvider: LINECallDetectionSnapshotProviding {
    private let value: LINECallDetectionCollection
    private var continuation: CheckedContinuation<LINECallDetectionCollection, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    init(_ value: LINECallDetectionCollection) { self.value = value }
    func snapshot() async -> LINECallDetectionCollection {
        readCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitForRead() async {
        if readCount > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class LINEFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class LINECancellationLatch: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func block() { _ = semaphore.wait(timeout: .now() + 2) }
    func release() { semaphore.signal() }
}

private actor LINERecoveryProvider: LINECallDetectionSnapshotProviding {
    private let value: LINECallDetectionCollection
    private let latch: LINECancellationLatch
    private var reads = 0
    private var continuation: CheckedContinuation<LINECallDetectionCollection, Never>?
    init(_ value: LINECallDetectionCollection, latch: LINECancellationLatch) {
        self.value = value
        self.latch = latch
    }
    func snapshot() async -> LINECallDetectionCollection {
        reads += 1
        guard reads == 2 else { return value }
        let latch = self.latch
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            latch.block()
        }
    }
    func release() {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
