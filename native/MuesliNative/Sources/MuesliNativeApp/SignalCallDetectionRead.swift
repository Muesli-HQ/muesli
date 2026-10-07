import Foundation

/// Return on timeout/cancellation even if the detached provider is still running.
/// A one-shot continuation delivers the winner; the adapter retains its read slot
/// until the provider finishes. A task group would wait for that uncooperative read.
private final class SignalCallDetectionReadRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SignalCallDetectionSnapshotRead, Never>?
    private var result: SignalCallDetectionSnapshotRead?
    private var tasks: [Task<Void, Never>] = []

    func install(_ value: CheckedContinuation<SignalCallDetectionSnapshotRead, Never>) {
        let completed = lock.withLock {
            if let result { return result }
            continuation = value
            return nil as SignalCallDetectionSnapshotRead?
        }
        if let completed { value.resume(returning: completed) }
    }

    func installTasks(_ values: [Task<Void, Never>]) {
        let retired = lock.withLock {
            guard result == nil else { return true }
            tasks = values
            return false
        }
        if retired { values.forEach { $0.cancel() } }
    }

    func resolve(_ value: SignalCallDetectionSnapshotRead) {
        let delivery = lock.withLock { () -> (CheckedContinuation<SignalCallDetectionSnapshotRead, Never>?, [Task<Void, Never>])? in
            guard result == nil else { return nil }
            result = value
            let delivery = (continuation, tasks)
            continuation = nil
            tasks = []
            return delivery
        }
        guard let delivery else { return }
        delivery.1.forEach { $0.cancel() }
        delivery.0?.resume(returning: value)
    }
}

enum SignalCallDetectionRead {
    static func perform(
        provider: any SignalCallDetectionSnapshotProvider, deadline: Date, timeout: TimeInterval,
        onProviderFinished: @escaping @Sendable () async -> Void
    ) async -> SignalCallDetectionSnapshotRead {
        let race = SignalCallDetectionReadRace()
        let clock = ContinuousClock()
        let expiresAt = clock.now.advanced(by: .seconds(timeout))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                let reader = Task.detached {
                    let value: SignalCallDetectionSnapshotRead
                    if Task.isCancelled { value = .unavailable(.timedOut) }
                    else { value = await provider.snapshot(deadline: deadline) }
                    await onProviderFinished()
                    race.resolve(clock.now < expiresAt ? value : .unavailable(.timedOut))
                }
                let timer = Task.detached {
                    do {
                        try await clock.sleep(until: expiresAt)
                        race.resolve(.unavailable(.timedOut))
                    } catch { /* Another result or cancellation already won. */ }
                }
                race.installTasks([reader, timer])
            }
        } onCancel: {
            race.resolve(.unavailable(.timedOut))
        }
    }
}
