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
        let sparkleBundle = Bundle(for: SPUStandardUpdaterController.self)
        // Fail closed if a future static linkage resolves Sparkle to the app.
        return sparkleBundle != Bundle.main && Bundle(for: type) == sparkleBundle
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

/// One bounded recovery attempt per manual check. Once presented, the user's
/// subsequent focus/minimize choices take precedence over recovery.
@MainActor
final class SparkleUpdateFocusRecovery {
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    @discardableResult
    func start(
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        focus: @escaping @MainActor () -> Bool
    ) -> Task<Void, Never> {
        cancel()
        let next = Task { @MainActor in
            // Relative intervals preserve the original 80ms–2.5s retry window.
            for delay: UInt64 in [80_000_000, 160_000_000, 360_000_000, 600_000_000, 1_300_000_000] {
                do { try await sleep(delay) }
                catch { return }
                guard !Task.isCancelled else { return }
                if focus() { return }
            }
        }
        task = next
        return next
    }

    deinit { task?.cancel() }
}
