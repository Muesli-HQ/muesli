import Foundation

/// Serializes concurrent async inference calls against a shared model instance
/// (e.g. one actor's CoreML session used by multiple callers) so requests queue
/// instead of racing.
public actor InferenceGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isProcessing = false
    private var waiters: [Waiter] = []

    public init() {}

    public func acquire() async throws {
        try Task.checkCancellation()
        if !isProcessing {
            isProcessing = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard acquired else { throw CancellationError() }
    }

    public func release() {
        if waiters.isEmpty {
            isProcessing = false
            return
        }

        waiters.removeFirst().continuation.resume(returning: true)
    }

    public func queuedWaiterCount() -> Int {
        waiters.count
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
