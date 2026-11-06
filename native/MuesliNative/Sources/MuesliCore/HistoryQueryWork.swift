import Foundation
import SQLite3

/// One budget spans projection, execution and dependency publication. Owned by
/// a single retrieval operation; never shared between concurrent queries.
package final class HistoryQueryWork {
    package struct Limit: LocalizedError {
        package init() {}
        package var errorDescription: String? {
            "History query exceeded its work limit. No partial analysis was returned."
        }
    }
    private let deadline: TimeInterval
    private let maximumRows: Int
    private var rows = 0
    package var remainingRows: Int { maximumRows - rows }
    package init(seconds: TimeInterval = 10, maximumRows: Int = 100_000) {
        deadline = ProcessInfo.processInfo.systemUptime + seconds
        self.maximumRows = maximumRows
    }
    package func check() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Limit() }
    }
    package func account(rows count: Int) throws {
        try check()
        guard count >= 0, count <= maximumRows - rows else { throw Limit() }
        rows += count
    }
    package func limited(to seconds: TimeInterval) -> HistoryQueryWork {
        .init(seconds: min(seconds, deadline - ProcessInfo.processInfo.systemUptime), maximumRows: maximumRows)
    }
    /// Install on an exclusively owned connection. In particular, bound the time
    /// a dependency transaction can hold the application's single writer lock.
    package func withProgress<T>(db: OpaquePointer?, seconds: TimeInterval? = nil,
                                 _ operation: () throws -> T) throws -> T {
        let watch = Watch(work: self, deadline: min(deadline,
            seconds.map { ProcessInfo.processInfo.systemUptime + $0 } ?? deadline))
        try watch.check()
        sqlite3_progress_handler(db, 1000, { raw in
            let watch = Unmanaged<Watch>.fromOpaque(raw!).takeUnretainedValue()
            return (try? watch.check()) == nil ? 1 : 0
        }, Unmanaged.passUnretained(watch).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(watch) {} }
        do {
            let result = try operation()
            try watch.check()
            return result
        } catch {
            try watch.check() // Preserve cancellation/limit instead of SQLITE_INTERRUPT.
            throw error
        }
    }
    private final class Watch {
        let work: HistoryQueryWork
        let deadline: TimeInterval
        init(work: HistoryQueryWork, deadline: TimeInterval) { self.work = work; self.deadline = deadline }
        func check() throws {
            try work.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Limit() }
        }
    }
}
