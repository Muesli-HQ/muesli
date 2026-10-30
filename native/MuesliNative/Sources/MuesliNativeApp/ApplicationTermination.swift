import AppKit

@MainActor
enum ApplicationTermination {
    /// Leave the main dispatch queue before AppKit enters its termination loop.
    /// Calling terminate from a MainActor task traps that queue inside AppKit,
    /// preventing async shutdown (and its deadline) from ever starting.
    static func request(beforeTerminate: @escaping @MainActor @Sendable () -> Void = {}) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                beforeTerminate()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
