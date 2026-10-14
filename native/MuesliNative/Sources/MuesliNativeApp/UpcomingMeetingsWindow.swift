import Foundation

enum UpcomingMeetingsWindow: Int, CaseIterable, Identifiable {
    case sixHours = 6
    case twelveHours = 12
    case today = 1
    case twoDays = 2
    case threeDays = 3

    static let defaultDayCount = UpcomingMeetingsWindow.today.rawValue

    static var maxDayCount: Int {
        allCases.map(\.dayCount).max() ?? defaultDayCount
    }

    var id: Int { rawValue }
    var dayCount: Int { hourCount == nil ? rawValue : 1 }
    var hourCount: Int? {
        switch self {
        case .sixHours: return 6
        case .twelveHours: return 12
        default: return nil
        }
    }
    var settingID: String { hourCount.map { "hours_\($0)" } ?? String(dayCount) }
    static func fromSettingID(_ id: String) -> Self? {
        allCases.first { $0.settingID == id }
    }

    var label: String {
        switch self {
        case .sixHours: return "Next 6 hours"
        case .twelveHours: return "Next 12 hours"
        case .today:
            return "Today only"
        case .twoDays:
            return "Two days"
        case .threeDays:
            return "Three days"
        }
    }

    static func resolve(dayCount: Int?, hourCount: Int? = nil) -> UpcomingMeetingsWindow {
        if hourCount == 6 { return .sixHours }
        if hourCount == 12 { return .twelveHours }
        guard let dayCount, let window = UpcomingMeetingsWindow(rawValue: dayCount), window.hourCount == nil else {
            return .today
        }
        return window
    }

    static func endDate(
        from now: Date = Date(),
        calendar: Calendar = .current,
        dayCount: Int,
        hourCount: Int? = nil
    ) -> Date? {
        let window = resolve(dayCount: dayCount, hourCount: hourCount)
        if let hours = window.hourCount {
            return now.addingTimeInterval(TimeInterval(hours * 60 * 60))
        }
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: window.dayCount, to: startOfToday)
    }

    static func staleHiddenEventIDs(
        hiddenIDs: Set<String>,
        visibleEventIDs: Set<String>,
        dayCount: Int,
        canConfirmMissingEvents: Bool = true,
        canConfirmMissingEventID: ((String) -> Bool)? = nil
    ) -> Set<String> {
        guard canConfirmMissingEvents || canConfirmMissingEventID != nil else {
            return []
        }

        let resolvedDayCount = resolve(dayCount: dayCount).dayCount
        guard resolvedDayCount >= maxDayCount else {
            return []
        }

        return hiddenIDs.filter { hiddenID in
            guard !visibleEventIDs.contains(hiddenID) else { return false }
            return canConfirmMissingEventID?(hiddenID) ?? canConfirmMissingEvents
        }
    }
}
