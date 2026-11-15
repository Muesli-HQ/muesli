import Foundation

/// Calendar time, not recording duration. Callers supply the visibility-filtered cache.
enum CalendarMenuPresentation {
    static func ordered(_ events: [UnifiedCalendarEvent], now: Date) -> [UnifiedCalendarEvent] {
        events.filter { !$0.isAllDay && $0.endDate > now && $0.endDate > $0.startDate }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.resolvedCalendarOccurrence.identityKey < $1.resolvedCalendarOccurrence.identityKey
            }
    }

    static func featured(_ events: [UnifiedCalendarEvent], now: Date, calendar: Calendar = .current,
                         activeOccurrenceKey: String? = nil) -> UnifiedCalendarEvent? {
        let events = ordered(events, now: now)
        let ongoing = events.filter { $0.startDate <= now }
        if let key = activeOccurrenceKey,
           let active = ongoing.first(where: { $0.resolvedCalendarOccurrence.identityKey == key }) { return active }
        return ongoing.first ?? events.first { calendar.isDate($0.startDate, inSameDayAs: now) }
    }

    static func time(_ event: UnifiedCalendarEvent, now: Date) -> String {
        let ongoing = event.startDate <= now
        let minutes = max(1, Int(ceil((ongoing ? event.endDate : event.startDate).timeIntervalSince(now) / 60)))
        let duration = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m")
        return ongoing ? "\(duration) left" : "in \(duration)"
    }

    static func label(_ event: UnifiedCalendarEvent, now: Date, style: CalendarMenuLabelStyle) -> String? {
        guard style != .iconOnly else { return nil }
        let timing = time(event, now: now)
        guard style == .titleAndTime else { return timing }
        let title = event.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let display = title.isEmpty ? "Meeting" : title
        return "\(display.count > 20 ? String(display.prefix(18)) + "…" : display) · \(timing)"
    }

    static func nextRefresh(_ events: [UnifiedCalendarEvent], now: Date) -> Date {
        let minute = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        return events.flatMap { [$0.startDate, $0.endDate] }.filter { $0 > now }.min().map { min($0, minute) } ?? minute
    }
}

enum CalendarMenuLabelStyle: String, Codable, CaseIterable {
    case titleAndTime = "title_and_time"
    case timeOnly = "time_only"
    case iconOnly = "icon_only"

    var title: String {
        switch self {
        case .titleAndTime: return "Title + time"
        case .timeOnly: return "Time only"
        case .iconOnly: return "Icon only"
        }
    }
}
