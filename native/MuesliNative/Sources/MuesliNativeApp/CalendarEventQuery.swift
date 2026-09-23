import Foundation

/// Runs synchronous calendar reads off the main actor and only returns the latest result.
@MainActor
final class CalendarEventQuery {
    struct Result {
        let events: [UnifiedCalendarEvent]
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var pending: Task<[UnifiedCalendarEvent], Never>?

    func load(_ read: @escaping @Sendable () -> [UnifiedCalendarEvent]) async -> Result? {
        invalidate()
        let token = generation
        guard !Task.isCancelled else { return nil }
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return [UnifiedCalendarEvent]() }
            return read()
        }
        pending = task
        let events = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard token == generation else { return nil }
        pending = nil
        guard !Task.isCancelled, !task.isCancelled else { return nil }
        return Result(events: events, generation: token)
    }

    /// Recheck at the publication site after crossing an async boundary.
    func isCurrent(_ result: Result) -> Bool {
        result.generation == generation
    }

    /// Invalidates in-flight results; EventKit's synchronous call itself cannot be interrupted.
    func invalidate() {
        generation &+= 1
        pending?.cancel()
        pending = nil
    }
}
