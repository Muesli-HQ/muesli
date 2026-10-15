import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Shutdown deadline")
struct ShutdownDeadlineTests {
    @Test("work that finishes in time returns at once and reports success")
    func finishesInTime() async {
        let started = Date()
        let finished = await ShutdownDeadline.run(seconds: 5) {}
        #expect(finished)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("work that never finishes is abandoned at the deadline")
    func abandonsStuckWork() async {
        let started = Date()
        let stuck = StuckWork()
        let finished = await ShutdownDeadline.run(seconds: 0.2) {
            // Ignores cancellation, like a job blocked on something that never answers.
            await stuck.park()
        }
        // The deadline abandoned the job; resume it so the test leaves no suspended task behind.
        stuck.release()
        #expect(!finished)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.2 && elapsed < 2)
    }

    @Test("work that finishes just after the deadline does not resume twice")
    func resumesOnce() async {
        let finished = await ShutdownDeadline.run(seconds: 0.1) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        #expect(!finished)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}

/// Holds a job suspended until the test releases it.
private final class StuckWork: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
