import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Calendar menu timing")
struct CalendarMenuPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_799_755_200) // Fixed epoch; use UTC calendar below.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func event(_ id: String = "a", start: TimeInterval, end: TimeInterval, title: String = "Review", allDay: Bool = false) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(id: id, title: title, startDate: now.addingTimeInterval(start),
                             endDate: now.addingTimeInterval(end), isAllDay: allDay, source: .eventKit)
    }

    @Test func timingAndTruncation() {
        let next = event(start: 8100, end: 9900, title: String(repeating: "Long title ", count: 10))
        #expect(CalendarMenuPresentation.label(next, now: now, style: .titleAndTime) == "Long title Long ti… · in 2h 15m")
        #expect(CalendarMenuPresentation.label(next, now: now, style: .timeOnly) == "in 2h 15m")
        #expect(CalendarMenuPresentation.label(next, now: now, style: .iconOnly) == nil)
        #expect(CalendarMenuPresentation.time(event(start: -100, end: 1080), now: now) == "18m left")
        #expect(CalendarMenuPresentation.time(event(start: 1, end: 3600), now: now) == "in 1m")
        #expect(CalendarMenuPresentation.time(event(start: 3600, end: 7200), now: now) == "in 1h")
        #expect(CalendarMenuPresentation.label(event(start: 60, end: 120, title: "  "), now: now, style: .titleAndTime) == "Meeting · in 1m")
    }

    @Test func transitionsAndOverlaps() {
        let ending = event("ending", start: -3600, end: 0)
        let current = event("current", start: 0, end: 1800)
        let overlapping = event("overlap", start: -300, end: 900)
        let future = event("future", start: 3600, end: 7200)
        let events = [future, current, ending, overlapping]
        #expect(CalendarMenuPresentation.featured(events, now: now, calendar: calendar)?.id == "overlap")
        #expect(CalendarMenuPresentation.featured(events.reversed(), now: now, calendar: calendar)?.id == "overlap")
        #expect(CalendarMenuPresentation.featured(events, now: now, calendar: calendar,
                activeOccurrenceKey: current.resolvedCalendarOccurrence.identityKey)?.id == "current")
        #expect(CalendarMenuPresentation.featured([ending, current], now: now, calendar: calendar)?.id == "current")
        #expect(CalendarMenuPresentation.time(current, now: now) == "30m left")
        let tie = event("b", start: 0, end: 1800)
        #expect(CalendarMenuPresentation.featured([tie, current], now: now, calendar: calendar)?.id
                == CalendarMenuPresentation.featured([current, tie], now: now, calendar: calendar)?.id)
    }

    @Test func todayAndMidnight() {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let tomorrow = UnifiedCalendarEvent(id: "tomorrow", title: "Tomorrow", startDate: midnight,
                                           endDate: midnight.addingTimeInterval(3600), isAllDay: false, source: .eventKit)
        #expect(CalendarMenuPresentation.featured([tomorrow], now: midnight.addingTimeInterval(-1), calendar: calendar) == nil)
        #expect(CalendarMenuPresentation.featured([tomorrow], now: midnight, calendar: calendar)?.id == "tomorrow")
        #expect(CalendarMenuPresentation.featured([event(start: -100, end: 100, allDay: true)], now: now) == nil)
        #expect(CalendarMenuPresentation.featured([event(start: -100, end: 0)], now: now) == nil)
        #expect(CalendarMenuPresentation.featured([event(start: 100, end: 0)], now: now) == nil)
    }

    @Test func refreshBoundaries() {
        let minute = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        #expect(CalendarMenuPresentation.nextRefresh([], now: now) == minute)
        #expect(CalendarMenuPresentation.nextRefresh([event(start: 12, end: 120)], now: now) == now.addingTimeInterval(12))
        #expect(CalendarMenuPresentation.nextRefresh([event(start: -12, end: 3)], now: now) == now.addingTimeInterval(3))
    }

    @Test @MainActor func visibilityAndWindow() {
        let state = AppState()
        state.config.calendarMeetingLinksOnly = false
        state.config.disabledCalendarIDs = ["disabled"]
        state.config.upcomingMeetingsHourCount = 6
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let late = UnifiedCalendarEvent(id: "late", title: "Late", startDate: start, endDate: start.addingTimeInterval(1800), isAllDay: false, source: .eventKit)
        var disabled = late; disabled.calendarID = "disabled"
        state.upcomingCalendarEvents = [disabled]
        #expect(state.visibleMenuBarCalendarEvents.isEmpty)
        state.upcomingCalendarEvents = [late]
        #expect(state.visibleMenuBarCalendarEvents == [late])
        state.hiddenCalendarEventIDs = ["late"]
        #expect(state.visibleMenuBarCalendarEvents.isEmpty)
        state.hiddenCalendarEventIDs = []
        state.config.calendarMeetingLinksOnly = true
        #expect(state.visibleMenuBarCalendarEvents.isEmpty)
    }

    @Test func settingsCompatibility() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"show_next_meeting_in_menu_bar":false}"#.utf8))
        #expect(!old.showNextMeetingInMenuBar)
        #expect(old.calendarMenuLabelStyle == .titleAndTime)
        #expect(old.showInviteDocuments)
        var config = old
        config.calendarMenuLabelStyle = .timeOnly
        config.showInviteDocuments = false
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.calendarMenuLabelStyle == .timeOnly)
        #expect(!roundTrip.showInviteDocuments)
    }
}
