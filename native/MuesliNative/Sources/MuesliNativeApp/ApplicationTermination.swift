import AppKit

@MainActor
enum ApplicationTermination {
    /// Leave the main dispatch queue before AppKit enters its termination loop.
    /// Calling terminate from a MainActor task traps that queue inside AppKit,
    /// preventing async shutdown (and its deadline) from ever starting.
    static func request(
        afterTerminate: @escaping @MainActor @Sendable () -> Void = {},
        beforeTerminate: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                beforeTerminate()
                NSApplication.shared.terminate(nil)
                // AppKit may reject termination before consulting the delegate
                // (for example, a modal window can veto it). Let callers recover.
                afterTerminate()
            }
        }
    }
}
