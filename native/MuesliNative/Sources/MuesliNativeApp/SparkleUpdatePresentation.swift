import AppKit
import Sparkle

@MainActor
enum SparkleUpdatePresentation {
    static func afterMenuTracking(_ action: @escaping @MainActor @Sendable () -> Void) {
        // Unlike dispatching to the main queue, a default-mode block cannot
        // run inside NSMenu's event-tracking loop.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { action() }
        }
    }

    static func belongsToSparkle(_ type: AnyClass) -> Bool {
        Bundle(for: type) == Bundle(for: SPUStandardUpdaterController.self)
    }

    static func isUpdaterWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized else { return false }
        // Sparkle uses standard AppKit window classes for some dialogs, but
        // their window controllers belong to Sparkle. Never match app titles.
        return belongsToSparkle(type(of: window)) || window.windowController.map {
            belongsToSparkle(type(of: $0))
        } == true
    }
}
