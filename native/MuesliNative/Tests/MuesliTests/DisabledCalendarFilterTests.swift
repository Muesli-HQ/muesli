import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Per-calendar disable filter")
@MainActor
struct DisabledCalendarFilterTests {

    @Test("empty disabled set returns events unchanged")
    func emptyDisabledSetPassesEverythingThrough() {
        let events = [
            event(id: "a", calendarID: "cal-1"),
            event(id: "b", calendarID: "cal-2"),
        ]
        let filtered = UnifiedCalendarEvent.filter(events, disabledCalendarIDs: [])
        #expect(filtered.count == 2)
        #expect(filtered.map(\.id) == ["a", "b"])
    }

    @Test("matching calendar IDs are filtered out")
    func partialDisableDropsMatchingEvents() {
        let events = [
            event(id: "a", calendarID: "cal-1"),
            event(id: "b", calendarID: "cal-2"),
            event(id: "c", calendarID: "cal-3"),
        ]
        let filtered = UnifiedCalendarEvent.filter(events, disabledCalendarIDs: ["cal-2"])
        #expect(filtered.map(\.id) == ["a", "c"])
    }

    @Test("disabling all calendars returns empty")
    func disablingAllCalendarsEmptiesResult() {
        let events = [
            event(id: "a", calendarID: "cal-1"),
            event(id: "b", calendarID: "cal-2"),
        ]
        let filtered = UnifiedCalendarEvent.filter(events, disabledCalendarIDs: ["cal-1", "cal-2"])
        #expect(filtered.isEmpty)
    }

    @Test("unknown disabled IDs have no effect")
    func unknownDisabledIDsAreIgnored() {
        let events = [event(id: "a", calendarID: "cal-1")]
        let filtered = UnifiedCalendarEvent.filter(events, disabledCalendarIDs: ["never-existed"])
        #expect(filtered.count == 1)
    }

    @Test("events with nil calendarID always pass through")
    func nilCalendarIDPassesThrough() {
        let events = [
            event(id: "legacy", calendarID: nil),
            event(id: "modern", calendarID: "cal-1"),
        ]
        let filtered = UnifiedCalendarEvent.filter(events, disabledCalendarIDs: ["cal-1"])
        #expect(filtered.map(\.id) == ["legacy"])
    }

    // MARK: - Helpers

    private func event(id: String, calendarID: String?) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id,
            title: "Event \(id)",
            startDate: Date(timeIntervalSince1970: 1_770_000_000),
            endDate: Date(timeIntervalSince1970: 1_770_003_600),
            isAllDay: false,
            source: .eventKit,
            calendarID: calendarID
        )
    }
}
