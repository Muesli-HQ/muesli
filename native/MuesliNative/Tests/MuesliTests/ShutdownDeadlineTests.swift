import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Shutdown deadline")
struct ShutdownDeadlineTests {
    @Test("confirmed quit lets AppKit run async shutdown and its fallback deadline")
    func appKitTerminationRunLoop() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("scripts/test_application_termination.sh").path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        #expect(status == 0)
    }

    @Test("work that finishes in time returns at once and reports success")
    func finishesInTime() async {
        let started = Date()
        let finished = await ShutdownDeadline.run(seconds: 5) {}
        #expect(finished)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("work that never finishes is abandoned at the deadline")
    @MainActor
    func abandonsStuckWork() async {
        let started = Date()
        let stuck = StuckWork()
        let finished = await ShutdownDeadline.run(seconds: 0.2) { @MainActor in
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

/// Holds a job suspended until the test releases it. A release that arrives first is kept, so
/// a job that parks late returns at once instead of hanging.
private final class StuckWork: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
