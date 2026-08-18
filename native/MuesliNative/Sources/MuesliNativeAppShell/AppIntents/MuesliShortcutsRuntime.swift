import Foundation
import MuesliNativeApp

@available(macOS 13.0, *)
enum MuesliShortcutsRuntime {
    /// Resolves the running controller. Shortcuts/Siri can cold-launch the
    /// app, and `MuesliController.current` is only set once
    /// `applicationDidFinishLaunching` runs, so wait briefly instead of
    /// failing with a spurious "not running" while the app is mid-launch.
    @MainActor
    static func waitForController(timeout: TimeInterval = 5) async throws -> MuesliController {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let controller = MuesliController.current { return controller }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let controller = MuesliController.current else {
            throw MuesliShortcutsError.notRunning
        }
        return controller
    }
}
