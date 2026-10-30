import Foundation

/// One winner across provider, deadline and caller cancellation. Lock ownership covers
/// every field; the continuation is resumed once, outside the lock. Unlike a task group,
/// completion does not wait for an uncooperative provider to leave its read operation.
final class ChatwootCallDetectionDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ChatwootCallDetectionSnapshotResult?
    private var continuation: CheckedContinuation<ChatwootCallDetectionSnapshotResult, Never>?

    func resolve(_ value: ChatwootCallDetectionSnapshotResult) {
        let waiter = lock.withLock { () -> CheckedContinuation<ChatwootCallDetectionSnapshotResult, Never>? in
            guard result == nil else { return nil }
            result = value
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(returning: value)
    }

    func value() async -> ChatwootCallDetectionSnapshotResult {
        await withCheckedContinuation { waiter in
            let completed = lock.withLock { () -> ChatwootCallDetectionSnapshotResult? in
                if let result { return result }
                continuation = waiter
                return nil
            }
            if let completed { waiter.resume(returning: completed) }
        }
    }
}
