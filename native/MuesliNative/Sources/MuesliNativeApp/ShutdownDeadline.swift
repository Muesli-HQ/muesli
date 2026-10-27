import Foundation

/// Runs the work that has to finish before the app quits, and gives up on it after a deadline. A step
/// that waits on something that never finishes (a transcription job, a network call) otherwise leaves
/// the app frozen in the middle of quitting, which only a force quit ends.
enum ShutdownDeadline {
    /// Returns when `operation` finishes or after `seconds`, whichever comes first. Returns whether the
    /// operation finished in time. An operation that overruns is left running; the app exits around it.
    @discardableResult
    static func run(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            Task {
                await operation()
                gate.resume(finished: true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.resume(finished: false)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(finished: Bool) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: finished)
        }
    }
}
