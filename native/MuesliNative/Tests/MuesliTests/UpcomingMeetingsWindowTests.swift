import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Upcoming meetings window")
struct UpcomingMeetingsWindowTests {
    @Test("today only ends at the next local day")
    func todayOnlyEndsAtNextLocalDay() throws {
        let now = try date(year: 2026, month: 4, day: 10, hour: 15)
        let end = try #require(UpcomingMeetingsWindow.endDate(from: now, calendar: calendar, dayCount: 1))
        let expected = try date(year: 2026, month: 4, day: 11, hour: 0)

        #expect(end == expected)
    }

    @Test("two and three day windows count calendar days")
    func multiDayWindowsCountCalendarDays() throws {
        let now = try date(year: 2026, month: 4, day: 10, hour: 23)
        let twoDayEnd = try date(year: 2026, month: 4, day: 12, hour: 0)
        let threeDayEnd = try date(year: 2026, month: 4, day: 13, hour: 0)

        #expect(UpcomingMeetingsWindow.endDate(from: now, calendar: calendar, dayCount: 2) == twoDayEnd)
        #expect(UpcomingMeetingsWindow.endDate(from: now, calendar: calendar, dayCount: 3) == threeDayEnd)
    }

    @Test("invalid day counts resolve to three days")
    func invalidDayCountsResolveToDefault() throws {
        let now = try date(year: 2026, month: 4, day: 10, hour: 9)
        let defaultEnd = try date(year: 2026, month: 4, day: 13, hour: 0)

        #expect(UpcomingMeetingsWindow.resolve(dayCount: nil) == .threeDays)
        #expect(UpcomingMeetingsWindow.resolve(dayCount: 7) == .threeDays)
        #expect(UpcomingMeetingsWindow.endDate(from: now, calendar: calendar, dayCount: 7) == defaultEnd)
    }

    @Test("config decodes the persisted day count")
    func configDecodesPersistedDayCount() throws {
        let data = #"{"upcoming_meetings_day_count":1}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.upcomingMeetingsDayCount == 1)
    }

    @Test("config falls back for invalid persisted day count")
    func configFallsBackForInvalidPersistedDayCount() throws {
        let data = #"{"upcoming_meetings_day_count":99}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.upcomingMeetingsDayCount == UpcomingMeetingsWindow.defaultDayCount)
    }

    @Test("hidden events outside narrowed windows are preserved")
    func hiddenEventsOutsideNarrowedWindowsArePreserved() {
        let staleIDs = UpcomingMeetingsWindow.staleHiddenEventIDs(
            hiddenIDs: ["today", "tomorrow"],
            visibleEventIDs: ["today"],
            dayCount: UpcomingMeetingsWindow.today.dayCount
        )

        #expect(staleIDs.isEmpty)
    }

    @Test("hidden events missing from the widest window are stale")
    func hiddenEventsMissingFromWidestWindowAreStale() {
        let staleIDs = UpcomingMeetingsWindow.staleHiddenEventIDs(
            hiddenIDs: ["today", "deleted"],
            visibleEventIDs: ["today"],
            dayCount: UpcomingMeetingsWindow.defaultDayCount
        )

        #expect(staleIDs == ["deleted"])
    }

    @Test("hidden events are preserved after incomplete source refresh")
    func hiddenEventsArePreservedAfterIncompleteSourceRefresh() {
        let staleIDs = UpcomingMeetingsWindow.staleHiddenEventIDs(
            hiddenIDs: ["google-event"],
            visibleEventIDs: [],
            dayCount: UpcomingMeetingsWindow.defaultDayCount,
            canConfirmMissingEvents: false
        )

        #expect(staleIDs.isEmpty)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        let components = DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0)!,
            year: year,
            month: month,
            day: day,
            hour: hour
        )
        return try #require(calendar.date(from: components))
    }
}
