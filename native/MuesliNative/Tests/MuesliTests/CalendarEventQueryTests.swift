import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Calendar event background queries")
@MainActor
struct CalendarEventQueryTests {
    /// A controllable synchronous query, independent of calendar accounts and permissions.
    private final class Gate: @unchecked Sendable {
        let started: AsyncStream<Void>
        let signal: AsyncStream<Void>.Continuation
        let release = DispatchSemaphore(value: 0)
        init() {
            (started, signal) = AsyncStream<Void>.makeStream()
        }
        func read() -> [UnifiedCalendarEvent] {
            #expect(!Thread.isMainThread)
            signal.yield(())
            #expect(release.wait(timeout: .now() + 10) == .success)
            return []
        }
        func waitUntilStarted() async {
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    @Test("query work runs off the main thread and returns events")
    func backgroundRead() async {
        let query = CalendarEventQuery()
        let result = await query.load {
            #expect(!Thread.isMainThread)
            return [UnifiedCalendarEvent(id: "new", title: "Meeting", startDate: .distantPast,
                                         endDate: .distantFuture, isAllDay: false, source: .eventKit)]
        }
        #expect(result?.events.map(\.id) == ["new"])
    }

    @Test("an older overlapping query cannot replace the newest result")
    func overlappingReads() async {
        let query = CalendarEventQuery()
        let gate = Gate()
        let older = Task { await query.load { gate.read() } }
        await gate.waitUntilStarted()
        let latest = await query.load {
            [UnifiedCalendarEvent(id: "latest", title: "Updated", startDate: .distantPast,
                                  endDate: .distantFuture, isAllDay: false, source: .eventKit)]
        }
        gate.release.signal()
        #expect(await older.value == nil)
        #expect(latest?.events.map(\.id) == ["latest"])
    }

    @Test("a completed result becomes stale before delayed publication")
    func delayedPublication() async throws {
        let query = CalendarEventQuery()
        let earlier = try #require(await query.load { [] })
        #expect(query.isCurrent(earlier))
        let latest = try #require(await query.load { [] })
        #expect(!query.isCurrent(earlier))
        #expect(query.isCurrent(latest))
    }

    @Test("cancelled or invalidated reads cannot publish their result", arguments: [false, true])
    func cancelledReads(invalidate: Bool) async {
        let query = CalendarEventQuery()
        let gate = Gate()
        let task = Task { await query.load { gate.read() } }
        await gate.waitUntilStarted()
        if invalidate { query.invalidate() } else { task.cancel() }
        gate.release.signal()
        #expect(await task.value == nil)
        #expect(await query.load { [] } != nil)
    }
}
