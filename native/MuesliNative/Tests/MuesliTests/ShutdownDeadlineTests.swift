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
        let finished = await ShutdownDeadline.run(seconds: 0.2) {
            // Ignores cancellation, like a job blocked on something that never answers.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
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
