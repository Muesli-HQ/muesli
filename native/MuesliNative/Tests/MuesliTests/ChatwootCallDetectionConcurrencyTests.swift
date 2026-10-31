import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Chatwoot bounded observation", .timeLimit(.minutes(1)))
struct ChatwootCallDetectionConcurrencyTests {
    @Test func noncooperativeReadTimesOutAndCannotAccumulateOrPublishLatePositive() async throws {
        let provider = ChatwootCallDetectionBlockedProvider()
        let adapter = ChatwootCallDetectionAdapter(provider: provider,
                                                  now: { ChatwootCallDetectionFixture.now }, timeout: .milliseconds(40))
        let clock = ContinuousClock()
        let start = clock.now
        let first = Task { await adapter.observe() }
        await provider.waitForRead()
        #expect(await first.value == .unavailable(.timedOut))
        #expect(start.duration(to: clock.now) < .seconds(2))
        #expect(await adapter.observe() == .unavailable(.timedOut))
        #expect(await provider.readCount == 1)
        await provider.release()
        let recovered = try ChatwootCallDetectionFixture.observation(await recover(adapter))
        #expect(recovered.observedAt == ChatwootCallDetectionFixture.now)
        #expect(await provider.readCount == 2)
    }

    @Test func callerCancellationReturnsWithoutWaitingForProvider() async throws {
        let provider = ChatwootCallDetectionBlockedProvider()
        let adapter = ChatwootCallDetectionAdapter(provider: provider,
                                                  now: { ChatwootCallDetectionFixture.now }, timeout: .seconds(2))
        let task = Task { await adapter.observe() }
        await provider.waitForRead()
        task.cancel()
        #expect(await task.value == .unavailable(.timedOut))
        #expect(await adapter.observe() == .unavailable(.timedOut))
        #expect(await provider.readCount == 1)
        await provider.release()
        _ = try ChatwootCallDetectionFixture.observation(await recover(adapter))
    }

    @Test func overlappingObserveInvalidatesOlderRequestInsteadOfReturningItsPositive() async throws {
        let provider = ChatwootCallDetectionBlockedProvider()
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let first = Task { await adapter.observe() }
        await provider.waitForRead()
        #expect(await adapter.observe() == .unavailable(.timedOut))
        await provider.release()
        #expect(await first.value == .unavailable(.timedOut))
        _ = try ChatwootCallDetectionFixture.observation(await recover(adapter))
    }

    @Test func timeoutCancelsCooperativeReadAndAllowsFreshObservation() async throws {
        let provider = ChatwootCallDetectionCooperativeProvider()
        let adapter = ChatwootCallDetectionAdapter(provider: provider,
                                                  now: { ChatwootCallDetectionFixture.now }, timeout: .milliseconds(40))
        let task = Task { await adapter.observe() }
        await provider.waitForRead()
        #expect(await task.value == .unavailable(.timedOut))
        // Verify cancellation/drain before a recovery observe can cancel an overlapping read.
        await provider.waitForFirstReadToFinish()
        #expect(await provider.cancelledReads == 1)
        #expect(await provider.readCount == 1)
        _ = try ChatwootCallDetectionFixture.observation(await recover(adapter))
        #expect(await provider.readCount == 2)
    }

    @Test func callerCancellationPropagatesToCooperativeProviderWithoutManualRelease() async throws {
        let provider = ChatwootCallDetectionCooperativeProvider()
        let adapter = ChatwootCallDetectionAdapter(provider: provider,
                                                  now: { ChatwootCallDetectionFixture.now }, timeout: .seconds(2))
        let task = Task { await adapter.observe() }
        await provider.waitForRead()
        task.cancel()
        #expect(await task.value == .unavailable(.timedOut))
        // Verify cancellation/drain before a recovery observe can cancel an overlapping read.
        await provider.waitForFirstReadToFinish()
        #expect(await provider.cancelledReads == 1)
        #expect(await provider.readCount == 1)
        _ = try ChatwootCallDetectionFixture.observation(await recover(adapter))
    }

    @Test func delayedReadDoesNotRefreshSnapshotTimestamp() async {
        let clock = ChatwootCallDetectionTestDateClock(ChatwootCallDetectionFixture.now)
        let provider = ChatwootCallDetectionBlockedProvider()
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { clock.now() }, timeout: .seconds(2))
        let task = Task { await adapter.observe() }
        await provider.waitForRead()
        clock.set(ChatwootCallDetectionFixture.now.addingTimeInterval(6))
        await provider.release()
        #expect(await task.value == .unavailable(.stale))
    }

    @Test func alreadyCancelledObserveNeverCallsProvider() async {
        let provider = ChatwootCallDetectionFixtureProvider(ChatwootCallDetectionFixture().result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await adapter.observe()
        }
        #expect(await task.value == .unavailable(.timedOut))
        #expect(await provider.readCount == 0)
    }

    private func recover(_ adapter: ChatwootCallDetectionAdapter) async -> CallDetectionResult {
        for _ in 0..<100 {
            let result = await adapter.observe()
            if result != .unavailable(.timedOut) { return result }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Provider did not drain within recovery deadline")
        return .unavailable(.timedOut)
    }
}

actor ChatwootCallDetectionBlockedProvider: ChatwootCallDetectionSnapshotProviding {
    private(set) var readCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func waitForRead() async {
        if readCount > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        blocked?.resume()
        blocked = nil
    }
    func snapshot(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionSnapshotResult {
        readCount += 1
        if readCount == 1 {
            // Deliberately ignores Task cancellation; only the controlled release ends this read.
            await withCheckedContinuation { continuation in
                blocked = continuation
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
        return ChatwootCallDetectionFixture().result
    }
}

final class ChatwootCallDetectionTestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

actor ChatwootCallDetectionCooperativeProvider: ChatwootCallDetectionSnapshotProviding {
    private(set) var readCount = 0
    private(set) var cancelledReads = 0
    private var firstReadFinished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func waitForRead() async {
        if readCount > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitForFirstReadToFinish() async {
        if firstReadFinished { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
    func snapshot(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionSnapshotResult {
        readCount += 1
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        if readCount == 1 {
            defer {
                firstReadFinished = true
                for waiter in finishWaiters { waiter.resume() }
                finishWaiters.removeAll()
            }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                cancelledReads += 1
                return .unavailable(.timedOut)
            } catch {
                return .unavailable(.unsupported)
            }
        }
        return ChatwootCallDetectionFixture().result
    }
}
