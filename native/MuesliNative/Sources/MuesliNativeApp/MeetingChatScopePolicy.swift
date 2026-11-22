import Foundation
import MuesliCore

enum MeetingChatScopePolicy {
    static var empty: MeetingChatScope { .init(selection: .meetings([])) }

    /// Mirrors the displayed meeting document/folder, never a stale sidebar ID.
    static func suggestedScope(tab: DashboardTab, navigation: MeetingsNavigationState,
        returnDestination: MeetingDetailReturnDestination, searchActive: Bool, folderID: Int64?
    ) -> MeetingChatScope {
        if case .document(let id) = navigation,
           searchActive || tab == .meetings || (tab == .timeline && returnDestination == .timeline) {
            return .init(selection: .meetings([id]))
        }
        if tab == .meetings, !searchActive, let folderID { return .init(selection: .folder(folderID)) }
        return empty
    }

    static func validDates(_ scope: MeetingChatScope, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
        if let start = scope.startDate, !start.timeIntervalSinceReferenceDate.isFinite || start >= tomorrow { return false }
        if let end = scope.endDateExclusive, !end.timeIntervalSinceReferenceDate.isFinite || end > tomorrow { return false }
        if let start = scope.startDate, let end = scope.endDateExclusive, start >= end { return false }
        return true
    }

    static let invalidDatesMessage = "Choose a valid date range ending today or earlier."

    static func dateBounds(meetings: [MeetingChatSourceChoice], now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let earliest = meetings.map(\.startDate).filter { $0 <= now }.min().map { calendar.startOfDay(for: $0) } ?? today
        return earliest...today
    }
}
