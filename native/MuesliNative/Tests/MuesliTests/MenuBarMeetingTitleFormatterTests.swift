import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Menu bar meeting title formatter")
struct MenuBarMeetingTitleFormatterTests {
    private let stockholmSummer = TimeZone(secondsFromGMT: 2 * 60 * 60)!

    @Test("long titles are truncated before the start time")
    func longTitleKeepsStartTimeVisible() {
        let formatted = MenuBarMeetingTitleFormatter.title(
            for: "Quarterly Product Strategy Review and Planning Session",
            startDate: date(hour: 9, minute: 30),
            maxLength: 30,
            timeZone: stockholmSummer
        )

        #expect(formatted.hasPrefix(" Quarterly Product"))
        #expect(formatted.count <= 30)
        #expect(formatted.hasSuffix(" · 09:30"))
        #expect(formatted.contains("… · 09:30"))
    }

    @Test("short titles keep the full title")
    func shortTitleKeepsFullTitle() {
        let formatted = MenuBarMeetingTitleFormatter.title(
            for: "Design sync",
            startDate: date(hour: 14, minute: 5),
            maxLength: 30,
            timeZone: stockholmSummer
        )

        #expect(formatted == " Design sync · 14:05")
    }

    @Test("empty titles fall back to Meeting")
    func emptyTitleFallsBackToMeeting() {
        let formatted = MenuBarMeetingTitleFormatter.title(
            for: "   ",
            startDate: date(hour: 8, minute: 0),
            maxLength: 30,
            timeZone: stockholmSummer
        )

        #expect(formatted == " Meeting · 08:00")
    }

    private func date(hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = stockholmSummer
        return calendar.date(from: DateComponents(
            timeZone: stockholmSummer,
            year: 2026,
            month: 5,
            day: 12,
            hour: hour,
            minute: minute
        ))!
    }
}
