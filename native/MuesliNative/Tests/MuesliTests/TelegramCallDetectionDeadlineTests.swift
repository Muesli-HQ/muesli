import Dispatch
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Telegram provider deadlines and overlap")
struct TelegramCallDetectionDeadlineTests {
    private typealias F = TelegramCallDetectionFixtures

    @Test func cancellationBeforeObservationDoesNotReadProvider() async {
        let counter = TelegramCallDetectionReadCounter()
        let adapter = TelegramCallDetectionAdapter(snapshotProvider: {
            counter.increment()
            return F.read()
        }, clock: { F.now })
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await adapter.observe()
        }
        task.cancel()
        #expect(await task.value == .unavailable(.timedOut))
        #expect(counter.value == 0)
    }

    @Test func cooperativeProviderIsCancelledOnTimeout() async throws {
        let cancelled = TelegramCallDetectionReadCounter()
        let adapter = TelegramCallDetectionAdapter(snapshotProvider: {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled.increment() }
            return F.read()
        }, clock: { F.now }, timeout: 0.02)
        #expect(await adapter.observe() == .unavailable(.timedOut))
        let limit = ContinuousClock.now.advanced(by: .seconds(1))
        while cancelled.value == 0 && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(1)) }
        #expect(cancelled.value == 1)
    }

    @Test func noncooperativeCancellationAndTimeoutReturnWithoutJoiningProvider() async throws {
        for cancel in [false, true] {
            let provider = TelegramCallDetectionSuspendedFixture(initial: F.read())
            let adapter = TelegramCallDetectionAdapter(snapshotProvider: { await provider.read() }, clock: { F.now }, timeout: 0.1)
            let before = try F.observation(await adapter.observe())
            let start = ContinuousClock.now
            let pending = Task { await adapter.observe() }
            await provider.waitUntilSuspended()
            if cancel { pending.cancel() }
            #expect(await pending.value == .unavailable(.timedOut))
            #expect(start.duration(to: .now) < .seconds(1))
            for _ in 0..<20 { #expect(await adapter.observe() == .unavailable(.timedOut)) }
            #expect(await provider.reads == 2) // One initial read, one outstanding read.
            await provider.release(F.read())
            let recovered = try await recover(adapter)
            #expect(recovered.callToken != before.callToken)
            let steady = try F.observation(await adapter.observe())
            #expect(steady.callToken == recovered.callToken)
        }
    }

    @Test func newerBusyObservationInvalidatesEarlierInFlightCompletion() async throws {
        let provider = TelegramCallDetectionSuspendedFixture(initial: F.read())
        let adapter = TelegramCallDetectionAdapter(snapshotProvider: { await provider.read() }, clock: { F.now }, timeout: 2)
        let before = try F.observation(await adapter.observe())
        let pending = Task { await adapter.observe() }
        await provider.waitUntilSuspended()
        #expect(await adapter.observe() == .unavailable(.timedOut))
        await provider.release(F.read())
        #expect(await pending.value == .unavailable(.ambiguous))
        let after = try await recover(adapter)
        #expect(after.callToken != before.callToken)
    }

    @Test func lateProviderCompletionIsRejectedEvenWhenTimeoutTimerIsDeferred() async throws {
        let gate = TelegramCallDetectionReadGate(provider: {
            try? await Task.sleep(for: .milliseconds(40))
            return F.read()
        }, scheduleTimeout: { _, _ in /* Deliberately defer timer delivery. */ })
        #expect(await gate.read(timeout: 0.005) == .unavailable(.timedOut))
    }

    @Test func synchronousBlockingProviderCannotStarveObservationDeadline() async throws {
        let fixture = TelegramCallDetectionBlockingFixture()
        // Cleanup watchdog makes a joined/blocking implementation fail boundedly.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { fixture.release() }
        let adapter = TelegramCallDetectionAdapter(snapshotProvider: { fixture.read() }, clock: { F.now }, timeout: 0.05)
        let start = ContinuousClock.now
        let pending = Task { await adapter.observe() }
        let startedLimit = ContinuousClock.now.advanced(by: .seconds(1))
        while !fixture.started && ContinuousClock.now < startedLimit { try await Task.sleep(for: .milliseconds(1)) }
        #expect(fixture.started)
        let result = await pending.value
        let returnedBeforeRelease = !fixture.released
        fixture.release()
        #expect(result == .unavailable(.timedOut))
        #expect(returnedBeforeRelease)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    private func recover(_ adapter: TelegramCallDetectionAdapter) async throws -> CallDetectionObservation {
        for _ in 0..<100 {
            let result = await adapter.observe()
            if case .observation(let observation) = result { return observation }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TelegramCallDetectionTestFailure.expectedObservation
    }
}

private final class TelegramCallDetectionReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class TelegramCallDetectionBlockingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let barrier = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didRelease = false
    var started: Bool { lock.withLock { didStart } }
    var released: Bool { lock.withLock { didRelease } }

    func read() -> TelegramCallDetectionReadResult {
        lock.withLock { didStart = true }
        barrier.wait()
        return TelegramCallDetectionFixtures.read()
    }

    func release() {
        let signal = lock.withLock {
            if didRelease { return false }
            didRelease = true
            return true
        }
        if signal { barrier.signal() }
    }
}

/// Deliberately ignores cancellation, but every test releases the continuation.
/// If the real gate launches additional reads, reads increments and tests fail.
private actor TelegramCallDetectionSuspendedFixture {
    private var initial: TelegramCallDetectionReadResult?
    private var recovered: TelegramCallDetectionReadResult?
    private var continuation: CheckedContinuation<TelegramCallDetectionReadResult, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    init(initial: TelegramCallDetectionReadResult) { self.initial = initial }

    func read() async -> TelegramCallDetectionReadResult {
        reads += 1
        if let result = initial { initial = nil; return result }
        if let recovered { return recovered }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = started
            started.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release(_ result: TelegramCallDetectionReadResult) {
        recovered = result
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
