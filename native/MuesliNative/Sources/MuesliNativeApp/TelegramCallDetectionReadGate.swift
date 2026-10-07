import Dispatch
import Foundation

/// A timed-out provider can ignore cancellation. Keep its single-flight slot
/// until it physically returns, without joining it or launching more providers.
final class TelegramCallDetectionReadGate: @unchecked Sendable {
    typealias Provider = @Sendable () async -> TelegramCallDetectionReadResult
    typealias TimeoutScheduler = @Sendable (TimeInterval, DispatchWorkItem) -> Void
    private let lock = NSLock()
    private var activeID: UUID?
    private let provider: Provider
    private let scheduleTimeout: TimeoutScheduler

    init(
        provider: @escaping Provider,
        scheduleTimeout: @escaping TimeoutScheduler = { timeout, timer in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        }
    ) {
        self.provider = provider
        self.scheduleTimeout = scheduleTimeout
    }

    private func acquire(_ id: UUID) -> Bool {
        lock.withLock {
            guard activeID == nil else { return false }
            activeID = id
            return true
        }
    }

    private func release(_ id: UUID) {
        lock.withLock { if activeID == id { activeID = nil } }
    }

    func read(timeout: TimeInterval) async -> TelegramCallDetectionReadResult {
        let request = TelegramCallDetectionReadRequest(timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard acquire(request.id) else {
                    continuation.resume(returning: .unavailable(.timedOut))
                    return
                }
                guard request.install(continuation) else {
                    release(request.id)
                    return
                }
                let timer = DispatchWorkItem { request.finish(.unavailable(.timedOut)) }
                request.install(timer)
                scheduleTimeout(timeout, timer)
                let task = Task.detached(priority: .utility) { [self] in
                    let result = await provider()
                    release(request.id)
                    request.finish(result, fromProvider: true)
                }
                request.install(task)
            }
        } onCancel: {
            request.finish(.unavailable(.timedOut))
        }
    }
}

/// Every mutable field is protected by lock; no continuation resumes under it.
/// Cancellation may arrive before continuation/task installation.
private final class TelegramCallDetectionReadRequest: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var outcome: TelegramCallDetectionReadResult?
    private var continuation: CheckedContinuation<TelegramCallDetectionReadResult, Never>?
    private var task: Task<Void, Never>?
    private var timer: DispatchWorkItem?

    init(timeout: TimeInterval) {
        deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    }

    func install(_ continuation: CheckedContinuation<TelegramCallDetectionReadResult, Never>) -> Bool {
        let existing = lock.withLock { () -> TelegramCallDetectionReadResult? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let existing {
            continuation.resume(returning: existing)
            return false
        }
        return true
    }

    func install(_ task: Task<Void, Never>) {
        let completed = lock.withLock {
            if outcome != nil { return true }
            self.task = task
            return false
        }
        if completed { task.cancel() }
    }

    func install(_ timer: DispatchWorkItem) {
        let completed = lock.withLock {
            if outcome != nil { return true }
            self.timer = timer
            return false
        }
        if completed { timer.cancel() }
    }

    func finish(_ result: TelegramCallDetectionReadResult, fromProvider: Bool = false) {
        let resources = lock.withLock { () -> (
            CheckedContinuation<TelegramCallDetectionReadResult, Never>?, Task<Void, Never>?, DispatchWorkItem?, TelegramCallDetectionReadResult
        )? in
            guard outcome == nil else { return nil }
            // Timer scheduling is only a wakeup. Even if its queue is delayed,
            // provider data completed after the absolute deadline cannot win.
            let accepted: TelegramCallDetectionReadResult = fromProvider && ContinuousClock.now >= deadline
                ? .unavailable(.timedOut) : result
            outcome = accepted
            let resources = (continuation, task, timer, accepted)
            continuation = nil
            task = nil
            timer = nil
            return resources
        }
        guard let resources else { return }
        resources.1?.cancel()
        resources.2?.cancel()
        resources.0?.resume(returning: resources.3)
    }
}
