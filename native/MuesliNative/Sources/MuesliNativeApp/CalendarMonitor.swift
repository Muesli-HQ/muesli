import AppKit
import EventKit
import Foundation
import MuesliCore

struct UpcomingMeetingEvent {
    let id: String
    let title: String
    let startDate: Date
    var meetingURL: URL? = nil
}

/// A calendar exposed by EventKit (iCloud, On-My-Mac, Exchange, an Internet
/// Account–linked Google calendar, etc.). Used by Settings to show which
/// calendars Muesli is reading from and to drive per-calendar enable/disable.
struct AvailableCalendar: Identifiable, Equatable {
    let id: String           // EKCalendar.calendarIdentifier
    let title: String
    let sourceTitle: String  // e.g. "iCloud", "spencer@dockstreet.com"
    let colorHex: String?
    let typeLabel: String
}

final class CalendarMonitor {
    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    /// Called when EventKit detects a calendar change (event added, moved, deleted).
    /// Delivered via NotificationCenter — immune to App Nap timer suspension.
    var onCalendarChanged: (() -> Void)?

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            if !granted {
                fputs("[calendar] calendar access denied: \(error?.localizedDescription ?? "none")\n", stderr)
                return
            }
            DispatchQueue.main.async {
                self?.registerForChanges()
            }
        }
    }

    func stop() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    private func registerForChanges() {
        // EKEventStoreChangedNotification fires whenever any calendar event
        // is added, modified, or deleted — including synced changes from
        // Google Calendar, iCloud, Exchange, etc. This is push-based and
        // works regardless of App Nap or LSUIElement status.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.onCalendarChanged?()
        }
    }

    /// Returns the current calendar event if one is happening right now.
    func currentEvent() -> UpcomingMeetingEvent? {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(60), calendars: nil)
        let events = store.events(matching: predicate)
        for event in events {
            guard !event.isAllDay else { continue }
            guard let startDate = event.startDate, let endDate = event.endDate else { continue }
            if startDate <= now && endDate > now {
                return UpcomingMeetingEvent(
                    id: event.eventIdentifier ?? "",
                    title: event.title ?? "Meeting",
                    startDate: startDate,
                    meetingURL: Self.extractMeetingURL(from: event)
                )
            }
        }
        return nil
    }

    /// Returns the current or recently started event (within 15 minutes)
    /// for meeting detection. Prefers currently active events over nearby ones.
    func currentOrNearbyEvent() -> CalendarEventContext? {
        let now = Date()
        let searchStart = now.addingTimeInterval(-15 * 60)
        let searchEnd = now.addingTimeInterval(5 * 60)
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let events = store.events(matching: predicate)

        var nearby: CalendarEventContext?
        for event in events {
            guard !event.isAllDay else { continue }
            guard let startDate = event.startDate, let endDate = event.endDate else { continue }
            let ctx = CalendarEventContext(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting"
            )
            // Currently active — return immediately
            if startDate <= now && endDate > now {
                return ctx
            }
            // Recently started (within 15 min) or about to start (within 5 min)
            if nearby == nil {
                nearby = ctx
            }
        }
        return nearby
    }

    /// Returns upcoming timed events from the local macOS calendar (EventKit) for the next N days.
    /// All-day events are excluded — they're not useful for meeting recording.
    /// Events from calendars listed in `disabledCalendarIDs` are filtered out.
    func upcomingEvents(daysAhead: Int = 7, disabledCalendarIDs: Set<String> = []) -> [UnifiedCalendarEvent] {
        // Create a fresh EKEventStore each time to avoid stale cache.
        // EKEventStore instances cache calendar data and don't automatically
        // reflect external changes (e.g., events moved in Google Calendar).
        // Uses a local instance to avoid racing with currentEvent()/currentOrNearbyEvent().
        let freshStore = EKEventStore()
        let now = Date()
        guard let future = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else { return [] }
        let predicate = freshStore.predicateForEvents(withStart: now, end: future, calendars: nil)
        let events = freshStore.events(matching: predicate)
        let unified: [UnifiedCalendarEvent] = events.compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            guard !event.isAllDay else { return nil }
            return UnifiedCalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting",
                startDate: startDate,
                endDate: endDate,
                isAllDay: false,
                source: .eventKit,
                calendarID: event.calendar?.calendarIdentifier,
                meetingURL: Self.extractMeetingURL(from: event)
            )
        }
        return UnifiedCalendarEvent
            .filter(unified, disabledCalendarIDs: disabledCalendarIDs)
            .sorted { $0.startDate < $1.startDate }
    }

    /// Enumerate every event calendar EventKit exposes — iCloud, On-My-Mac,
    /// Exchange, and any Google account linked via System Settings > Internet
    /// Accounts. Used by Settings to surface which calendars Muesli is reading
    /// from and to power per-calendar enable/disable.
    func availableCalendars() -> [AvailableCalendar] {
        let freshStore = EKEventStore()
        return freshStore.calendars(for: .event)
            .map { cal in
                AvailableCalendar(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    sourceTitle: cal.source.title,
                    colorHex: Self.hexString(from: cal.cgColor),
                    typeLabel: Self.typeLabel(for: cal.type)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sourceTitle != rhs.sourceTitle { return lhs.sourceTitle < rhs.sourceTitle }
                return lhs.title < rhs.title
            }
    }

    private static func hexString(from cgColor: CGColor?) -> String? {
        guard let cgColor, let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "%02x%02x%02x", r, g, b)
    }

    private static func typeLabel(for type: EKCalendarType) -> String {
        switch type {
        case .local: return "Local"
        case .calDAV: return "CalDAV"
        case .exchange: return "Exchange"
        case .subscription: return "Subscription"
        case .birthday: return "Birthday"
        @unknown default: return "Calendar"
        }
    }

    // MARK: - Meeting URL Extraction

    /// Extract a meeting join URL from an EventKit event.
    /// Checks the event URL, location, and notes for known meeting link patterns.
    private static let meetingURLPattern: NSRegularExpression? = {
        let patterns = [
            "https://[a-z0-9.-]*zoom\\.us/j/[^\\s\"<>]+",
            "https://meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\\s\"<>]*",
            "https://teams\\.microsoft\\.com/l/meetup-join/[^\\s\"<>]+",
            "https://[a-z0-9.-]*webex\\.com/[^\\s\"<>]+/j\\.php[^\\s\"<>]*",
            "https://[a-z0-9.-]*chime\\.aws/[^\\s\"<>]+",
            "https://facetime\\.apple\\.com/join[^\\s\"<>]*",
            "https://app\\.slack\\.com/huddle/[A-Z0-9]+/[A-Z0-9]+",
        ]
        return try? NSRegularExpression(pattern: "(\(patterns.joined(separator: "|")))", options: .caseInsensitive)
    }()

    static func extractMeetingURL(from event: EKEvent) -> URL? {
        // 1. Explicit event URL (set by calendar provider)
        if let url = event.url, isMeetingURL(url) {
            return url
        }

        // 2. Search location field
        if let location = event.location, let url = findMeetingURL(in: location) {
            return url
        }

        // 3. Search notes/description
        if let notes = event.notes, let url = findMeetingURL(in: notes) {
            return url
        }

        return nil
    }

    private static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "chime.aws", "facetime.apple.com", "app.slack.com"]
        return meetingHosts.contains(where: { host.hasSuffix($0) })
    }

    static func findMeetingURL(in text: String) -> URL? {
        guard let regex = meetingURLPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[matchRange]))
    }

}
