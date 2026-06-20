import Foundation

/// Serialises Suggested-Words analysis triggers **without a timer**.
///
/// In this LSUIElement app App Nap can suspend `Task.sleep`, so a debounce sleep
/// could leave the section stale until a manual refresh. Instead of debouncing we
/// coalesce: triggers arrive from several event sources (each completed dictation,
/// the Dictionary tab-open/focus backstop, the launch warmup, manual refresh) and
/// a burst collapses into at most two passes over fresh data — the pass already in
/// flight, plus one rerun that picks up everything that arrived while it ran.
///
/// Pure state machine: the caller owns the actual async analysis. All access is
/// expected to be serialised by the caller (the controller is `@MainActor`).
struct SuggestionAnalysisCoalescer {
    /// True while a run loop is active (between the first `onTrigger` that returns
    /// `true` and the `onRunFinished` that returns `false`).
    private(set) var isRunning = false

    /// Set when a trigger arrives mid-run; consumed by the next `onRunFinished`.
    private var rerunRequested = false

    /// Record a trigger.
    ///
    /// - Returns: `true` if the caller should start the run loop now; `false` if a
    ///   run is already active (a single rerun is queued instead, so any number of
    ///   triggers during a run cause exactly one extra pass).
    mutating func onTrigger() -> Bool {
        guard !isRunning else {
            rerunRequested = true
            return false
        }
        isRunning = true
        return true
    }

    /// Call after each analysis pass completes.
    ///
    /// - Returns: `true` if another pass should run immediately (a trigger arrived
    ///   while the just-finished pass was running), `false` if the loop should stop.
    mutating func onRunFinished() -> Bool {
        if rerunRequested {
            rerunRequested = false
            return true
        }
        isRunning = false
        return false
    }
}
