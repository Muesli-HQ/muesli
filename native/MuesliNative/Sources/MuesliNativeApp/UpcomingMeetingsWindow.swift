import Foundation

enum UpcomingMeetingsWindow: Int, CaseIterable, Identifiable {
    case today = 1
    case twoDays = 2
    case threeDays = 3

    static let defaultDayCount = UpcomingMeetingsWindow.threeDays.rawValue

    static var maxDayCount: Int {
        allCases.map(\.dayCount).max() ?? defaultDayCount
    }

    var id: Int { rawValue }
    var dayCount: Int { rawValue }

    var label: String {
        switch self {
        case .today:
            return "Today only"
        case .twoDays:
            return "Two days"
        case .threeDays:
            return "Three days"
        }
    }

    static func resolve(dayCount: Int?) -> UpcomingMeetingsWindow {
        guard let dayCount, let window = UpcomingMeetingsWindow(rawValue: dayCount) else {
            return .threeDays
        }
        return window
    }

    static func endDate(
        from now: Date = Date(),
        calendar: Calendar = .current,
        dayCount: Int
    ) -> Date? {
        let window = resolve(dayCount: dayCount)
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: window.dayCount, to: startOfToday)
    }

    static func staleHiddenEventIDs(
        hiddenIDs: Set<String>,
        visibleEventIDs: Set<String>,
        dayCount: Int,
        canConfirmMissingEvents: Bool = true
    ) -> Set<String> {
        guard canConfirmMissingEvents else {
            return []
        }

        let resolvedDayCount = resolve(dayCount: dayCount).dayCount
        guard resolvedDayCount >= maxDayCount else {
            return []
        }

        return hiddenIDs.subtracting(visibleEventIDs)
    }
}
