import Foundation
import Testing
@testable import MuesliNativeApp

actor WeChatCallDetectionControlledProvider: WeChatCallDetectionSnapshotProviding {
    private(set) var started = 0
    private var pending: [Int: CheckedContinuation<WeChatCallDetectionSnapshotResult, Never>] = [:]
    private var closed = false

    func snapshot() async -> WeChatCallDetectionSnapshotResult {
        guard !closed else { return .unavailable(.timedOut) }
        started += 1
        let id = started
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func waitForStarts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while started < count {
            guard !closed, !Task.isCancelled, ContinuousClock.now < deadline else {
                throw WeChatCallDetectionTestFailure.probeDidNotStart
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func finish(_ id: Int, with result: WeChatCallDetectionSnapshotResult) {
        pending.removeValue(forKey: id)?.resume(returning: result)
    }
    func close() {
        closed = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: .unavailable(.timedOut)) }
    }
}

enum WeChatCallDetectionTestFailure: Error { case missingObservation, probeDidNotStart }
func weChatCallDetectionToken(_ result: CallDetectionResult) throws -> String {
    guard case .observation(let observation) = result else { throw WeChatCallDetectionTestFailure.missingObservation }
    return observation.callToken
}

private enum WeChatCallDetectionTaskOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case watchdogExpired
}

private actor WeChatCallDetectionTaskRace<Value: Sendable> {
    private var outcome: WeChatCallDetectionTaskOutcome<Value>?
    private var continuation: CheckedContinuation<WeChatCallDetectionTaskOutcome<Value>, Never>?
    private var watchdogStarted = false

    func wait() async -> WeChatCallDetectionTaskOutcome<Value> {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ value: Value) {
        guard outcome == nil, !watchdogStarted else { return }
        finish(.completed(value))
    }

    func beginWatchdog() -> Bool {
        guard outcome == nil, !watchdogStarted else { return false }
        watchdogStarted = true
        return true
    }

    func completeWatchdog() {
        guard outcome == nil, watchdogStarted else { return }
        finish(.watchdogExpired)
    }

    private func finish(_ outcome: WeChatCallDetectionTaskOutcome<Value>) {
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

func weChatCallDetectionTaskValue<Value: Sendable>(
    _ task: Task<Value, Never>,
    watchdog: Duration = .seconds(3),
    onWatchdog: @escaping @Sendable () async -> Void
) async -> Value? {
    let race = WeChatCallDetectionTaskRace<Value>()
    let resultTask = Task {
        let result = await task.value
        await race.complete(result)
    }
    let watchdogTask = Task {
        do {
            try await Task.sleep(for: watchdog)
        } catch {
            return
        }
        guard await race.beginWatchdog() else { return }
        task.cancel()
        await onWatchdog()
        await race.completeWatchdog()
    }

    let outcome = await race.wait()
    watchdogTask.cancel()
    resultTask.cancel()
    switch outcome {
    case .completed(let value):
        return value
    case .watchdogExpired:
        Issue.record("WeChat adapter did not finish before the test watchdog; the adapter was cancelled and the controlled provider closed")
        return nil
    }
}

final class WeChatCallDetectionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = WeChatCallDetectionFixtures.now
    func now() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date = date.addingTimeInterval(interval) } }
}

@Suite("WeChat synthetic lifecycle; no recording admission evidence")
struct WeChatCallDetectionLifecycleTests {
    @Test func sameConnectedSessionKeepsTokenAndRestartedScopesRotateIt() async throws {
        let sources = [
            WeChatCallDetectionFixtures.source(),
            WeChatCallDetectionFixtures.source(),
            WeChatCallDetectionFixtures.source(pid: 43, launch: "process-generation-2"),
            WeChatCallDetectionFixtures.source(pid: 43, launch: "process-generation-3"),
            WeChatCallDetectionFixtures.source(pid: 43, launch: "process-generation-3", surface: "document-generation-2")
        ]
        let provider = WeChatCallDetectionSequenceProvider(sources.map {
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(source: $0)])
        } + [WeChatCallDetectionFixtures.snapshot([
            WeChatCallDetectionFixtures.surface(source: sources.last!, generation: "session-generation-2")
        ])])
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now })
        var tokens: [String] = []
        for _ in 0..<6 { tokens.append(try weChatCallDetectionToken(await adapter.observe())) }
        #expect(tokens[0] == tokens[1])
        for index in 2..<tokens.count { #expect(tokens[index] != tokens[index - 1]) }
        #expect(tokens.allSatisfy { UUID(uuidString: $0) != nil })
    }

    @Test func endedRingingVoiceNotesAndFailuresBreakConnectedContinuity() async throws {
        let breaks: [WeChatCallDetectionSnapshotResult] = [
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(activity: .ended)]),
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(activity: .ringing)]),
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(activity: .voiceNotePlayback)]),
            .unavailable(.permissionRequired), .unavailable(.ambiguous), .unavailable(.sourceMismatch),
            WeChatCallDetectionFixtures.snapshot(age: 6)
        ]
        for interruption in breaks {
            let provider = WeChatCallDetectionSequenceProvider([
                WeChatCallDetectionFixtures.snapshot(), interruption, WeChatCallDetectionFixtures.snapshot()
            ])
            let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now })
            let first = try weChatCallDetectionToken(await adapter.observe())
            _ = await adapter.observe()
            let reconnected = try weChatCallDetectionToken(await adapter.observe())
            #expect(first != reconnected)
        }
    }

    @Test func uncooperativeProviderTimesOutWithoutWaitingForItsExit() async throws {
        let provider = WeChatCallDetectionControlledProvider()
        defer { Task { await provider.close() } }
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now }, timeout: .seconds(1))
        let task = Task { await adapter.observe() }
        try await provider.waitForStarts(1)
        guard let result = await weChatCallDetectionTaskValue(task, onWatchdog: { await provider.close() }) else { return }
        #expect(result == .unavailable(.timedOut))
        // Releasing after observe returned proves timeout didn't await provider teardown.
        await provider.finish(1, with: WeChatCallDetectionFixtures.snapshot())
    }

    @Test func cancellationBeforeAndDuringCollectionNeverReturnsPositive() async throws {
        let immediate = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot()).observe()
        }
        let immediateResult = await immediate.value
        #expect(immediateResult == .unavailable(.timedOut))

        let provider = WeChatCallDetectionControlledProvider()
        defer { Task { await provider.close() } }
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now })
        let task = Task { await adapter.observe() }
        try await provider.waitForStarts(1)
        task.cancel()
        guard let result = await weChatCallDetectionTaskValue(task, onWatchdog: { await provider.close() }) else { return }
        #expect(result == .unavailable(.timedOut))
        await provider.finish(1, with: WeChatCallDetectionFixtures.snapshot())
    }

    @Test func timedOutLatePositiveCannotRestorePreviousSessionToken() async throws {
        let provider = WeChatCallDetectionControlledProvider()
        defer { Task { await provider.close() } }
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now }, timeout: .seconds(1))
        let firstTask = Task { await adapter.observe() }
        try await provider.waitForStarts(1)
        await provider.finish(1, with: WeChatCallDetectionFixtures.snapshot())
        let first = try weChatCallDetectionToken(await firstTask.value)
        let timeoutTask = Task { await adapter.observe() }
        try await provider.waitForStarts(2)
        guard let timeout = await weChatCallDetectionTaskValue(timeoutTask, onWatchdog: { await provider.close() }) else { return }
        #expect(timeout == .unavailable(.timedOut))
        await provider.finish(2, with: WeChatCallDetectionFixtures.snapshot())
        let reconnectTask = Task { await adapter.observe() }
        try await provider.waitForStarts(3)
        await provider.finish(3, with: WeChatCallDetectionFixtures.snapshot())
        let reconnected = try weChatCallDetectionToken(await reconnectTask.value)
        #expect(first != reconnected)
    }

    @Test func clockIsCheckedAfterCollectionWithoutRestampingSnapshot() async throws {
        let clock = WeChatCallDetectionTestClock()
        let provider = WeChatCallDetectionControlledProvider()
        defer { Task { await provider.close() } }
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { clock.now() })
        let task = Task { await adapter.observe() }
        try await provider.waitForStarts(1)
        clock.advance(6)
        await provider.finish(1, with: WeChatCallDetectionFixtures.snapshot())
        let result = await task.value
        #expect(result == .unavailable(.stale))
    }

    @Test func supersededCallbackCannotReturnPositiveOrClearNewerToken() async throws {
        let provider = WeChatCallDetectionControlledProvider()
        defer { Task { await provider.close() } }
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now })
        let olderTask = Task { await adapter.observe() }
        try await provider.waitForStarts(1)
        let newerTask = Task { await adapter.observe() }
        try await provider.waitForStarts(2)
        await provider.finish(2, with: WeChatCallDetectionFixtures.snapshot())
        let newer = try weChatCallDetectionToken(await newerTask.value)
        await provider.finish(1, with: .unavailable(.permissionRequired))
        let obsolete = await olderTask.value
        #expect(obsolete == .unavailable(.stale))
        let stableTask = Task { await adapter.observe() }
        try await provider.waitForStarts(3)
        await provider.finish(3, with: WeChatCallDetectionFixtures.snapshot())
        let stable = try weChatCallDetectionToken(await stableTask.value)
        #expect(newer == stable)
    }
}
