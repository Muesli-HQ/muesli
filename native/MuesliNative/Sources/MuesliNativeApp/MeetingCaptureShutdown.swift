import Foundation

/// Native shutdowns run independently. A deadline releases finalization, while
/// onQuiesced releases capture ownership only when BOTH drivers really return.
/// Already finalized chunks can be saved even if a driver is still blocked.
enum MeetingCaptureShutdown {
    struct Result {
        let microphone: URL?
        let systemAudio: URL?
        let timedOut: Bool
    }

    static func stop(
        timeout: TimeInterval = 12,
        microphone: @escaping () async -> URL?,
        systemAudio: @escaping () async -> URL?,
        onQuiesced: @escaping () -> Void = {}
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let operation = Operation(
                microphone: microphone, systemAudio: systemAudio,
                continuation: continuation, onQuiesced: onQuiesced
            )
            operation.start(timeout: timeout)
        }
    }

    // Each driver closure is called once on its dedicated queue. Result and
    // completion ownership are protected by the lock; callbacks run outside it.
    private final class Operation: @unchecked Sendable {
        let microphone: () async -> URL?
        let systemAudio: () async -> URL?
        let onQuiesced: () -> Void
        let lock = NSLock()
        var continuation: CheckedContinuation<Result, Never>?
        var micURL: URL?
        var systemURL: URL?
        var completed = 0
        var deadline: DispatchWorkItem?

        init(microphone: @escaping () async -> URL?, systemAudio: @escaping () async -> URL?,
             continuation: CheckedContinuation<Result, Never>, onQuiesced: @escaping () -> Void) {
            self.microphone = microphone
            self.systemAudio = systemAudio
            self.continuation = continuation
            self.onQuiesced = onQuiesced
        }

        func start(timeout: TimeInterval) {
            let item = DispatchWorkItem { [weak self] in self?.expire() }
            deadline = item
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: item)
            Task.detached { [self] in
                finish(url: await microphone(), isMicrophone: true)
            }
            Task.detached { [self] in
                finish(url: await systemAudio(), isMicrophone: false)
            }
        }

        func finish(url: URL?, isMicrophone: Bool) {
            lock.lock()
            if isMicrophone { micURL = url } else { systemURL = url }
            completed += 1
            guard completed == 2 else { lock.unlock(); return }
            deadline?.cancel()
            deadline = nil
            let waiter = continuation
            continuation = nil
            let result = Result(microphone: micURL, systemAudio: systemURL, timedOut: false)
            lock.unlock()
            onQuiesced()
            waiter?.resume(returning: result)
        }

        func expire() {
            lock.lock()
            let waiter = continuation
            continuation = nil
            let result = Result(microphone: micURL, systemAudio: systemURL, timedOut: true)
            lock.unlock()
            waiter?.resume(returning: result)
        }
    }
}
