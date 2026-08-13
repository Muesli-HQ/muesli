import Foundation
import MuesliCore

// MARK: - Shared Calendar Event Model

struct UnifiedCalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let source: CalendarSource
    /// Identifier of the calendar this event belongs to.
    /// EventKit: `EKCalendar.calendarIdentifier`. Google: the calendar list `id`.
    /// Optional because legacy events deserialized from older state may not have it.
    var calendarID: String? = nil
    var calendarOccurrence: CalendarOccurrenceReference? = nil
    var meetingURL: URL? = nil

    enum CalendarSource: String {
        case eventKit
        case googleCalendar

        var occurrenceProvider: CalendarOccurrenceReference.Provider {
            switch self {
            case .eventKit:
                return .eventKit
            case .googleCalendar:
                return .googleCalendar
            }
        }
    }

    var resolvedCalendarOccurrence: CalendarOccurrenceReference {
        calendarOccurrence ?? CalendarOccurrenceReference(
            provider: source.occurrenceProvider,
            calendarID: calendarID,
            eventID: id,
            originalStartTime: startDate
        )
    }

    /// Drop events whose `calendarID` is in `disabledCalendarIDs`. Events with `nil`
    /// calendarID always pass through (they predate per-calendar filtering).
    static func filter(
        _ events: [UnifiedCalendarEvent],
        disabledCalendarIDs: Set<String>
    ) -> [UnifiedCalendarEvent] {
        guard !disabledCalendarIDs.isEmpty else { return events }
        return events.filter { event in
            guard let id = event.calendarID else { return true }
            return !disabledCalendarIDs.contains(id)
        }
    }
}

// MARK: - Google Calendar List Model

struct GoogleCalendarSummary: Identifiable, Equatable {
    let id: String
    let summary: String
    let isPrimary: Bool
    let colorHex: String?
}

struct GoogleCalendarFetchResult {
    let events: [UnifiedCalendarEvent]
    let wasComplete: Bool
}

enum GoogleCalendarClientError: Error, LocalizedError {
    case requestFailed(String)
    case staleRequest

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return "Google Calendar request failed: \(message)"
        case .staleRequest:
            return "Google Calendar request was superseded"
        }
    }
}

// MARK: - Google Calendar API Client

@MainActor
final class GoogleCalendarClient {
    private let auth = GoogleCalendarAuthManager.shared

    private static let baseURL = "https://www.googleapis.com/calendar/v3"
    private static let primaryCalendarID = "primary"

    private struct EventWindowScope: Equatable {
        let dayCount: Int
        let startOfDay: Date

        func covers(_ scope: EventWindowScope, calendar: Calendar = .current) -> Bool {
            guard
                let end = calendar.date(byAdding: .day, value: dayCount, to: startOfDay),
                let scopeEnd = calendar.date(byAdding: .day, value: scope.dayCount, to: scope.startOfDay)
            else {
                return false
            }
            return startOfDay <= scope.startOfDay && end >= scopeEnd
        }

        func overlaps(_ scope: EventWindowScope, calendar: Calendar = .current) -> Bool {
            guard
                let end = calendar.date(byAdding: .day, value: dayCount, to: startOfDay),
                let scopeEnd = calendar.date(byAdding: .day, value: scope.dayCount, to: scope.startOfDay)
            else {
                return false
            }
            return startOfDay < scopeEnd && scope.startOfDay < end
        }
    }

    /// Stored sync token per calendar from last full fetch — subsequent requests
    /// return only changes for that calendar.
    private var syncTokens: [String: String] = [:]
    /// Cached events keyed by calendar ID, then by event ID. A 410 (sync token
    /// expired) for one calendar invalidates only that calendar's cache.
    private var cachedEventsByCalendar: [String: [String: UnifiedCalendarEvent]] = [:]
    /// Window/day represented by each per-calendar event cache.
    private var cachedEventScopesByCalendar: [String: EventWindowScope] = [:]
    /// The event window used for the current sync tokens. Google incremental
    /// sync does not include a new time range, so changing the selected window
    /// requires a full re-fetch.
    private var cachedEventWindowDayCount: Int?
    /// The local day that anchored the current event window. The selected
    /// window may stay at the same day count while the query range advances at
    /// midnight, which also requires a full re-fetch.
    private var cachedEventWindowStartOfDay: Date?
    /// Last fetched calendar list. Refreshed each time `fetchUpcomingEvents` runs
    /// so calendars added in the Google web UI get picked up automatically.
    private var cachedCalendarList: [GoogleCalendarSummary] = []
    private var upcomingEventsFetchGeneration = 0

    /// Fetch upcoming events from every Google calendar the user can read,
    /// minus any in `disabledCalendarIDs`. Refreshes the calendar list on each
    /// call so newly-added calendars show up; per-calendar sync tokens keep
    /// each event fetch incremental.
    func fetchUpcomingEvents(
        daysAhead: Int = UpcomingMeetingsWindow.defaultDayCount,
        disabledCalendarIDs: Set<String> = [],
        now: Date = Date()
    ) async throws -> GoogleCalendarFetchResult {
        upcomingEventsFetchGeneration += 1
        let fetchGeneration = upcomingEventsFetchGeneration
        var completedAllFetches = true

        let resolvedDayCount = UpcomingMeetingsWindow.resolve(dayCount: daysAhead).dayCount
        let windowScope = EventWindowScope(
            dayCount: resolvedDayCount,
            startOfDay: Calendar.current.startOfDay(for: now)
        )
        resetEventSyncIfNeededForWindow(daysAhead: resolvedDayCount, now: now)

        guard let future = UpcomingMeetingsWindow.endDate(from: now, dayCount: resolvedDayCount) else {
            throw GoogleCalendarClientError.requestFailed("invalid upcoming events window")
        }

        // Refresh the calendar list. If this fails, fall back to whatever we
        // last saw — better to return something than nothing.
        do {
            let calendarList = try await fetchCalendarList()
            try ensureCurrentFetch(fetchGeneration)
            cachedCalendarList = calendarList
        } catch {
            try ensureCurrentFetch(fetchGeneration)
            if cachedCalendarList.isEmpty {
                // First call ever and we can't list — try the primary calendar
                // directly so users with read-only access at least see something.
                cachedCalendarList = [GoogleCalendarSummary(
                    id: Self.primaryCalendarID,
                    summary: "Primary",
                    isPrimary: true,
                    colorHex: nil
                )]
            }
            fputs("[google-cal] calendarList fetch failed, using cached list: \(error)\n", stderr)
            completedAllFetches = false
        }

        let enabled = cachedCalendarList.filter { !disabledCalendarIDs.contains($0.id) }
        var failedCalendarIDs = Set<String>()
        // Drop cached events for any calendar that's now disabled or absent so
        // we don't leak stale events into the merged result.
        let keepIDs = Set(enabled.map(\.id))
        let calendarIDsToRemove = cachedEventsByCalendar.keys.filter { !keepIDs.contains($0) }
        for calID in calendarIDsToRemove {
            try ensureCurrentFetch(fetchGeneration)
            cachedEventsByCalendar.removeValue(forKey: calID)
            cachedEventScopesByCalendar.removeValue(forKey: calID)
            syncTokens.removeValue(forKey: calID)
        }

        for calendar in enabled {
            do {
                try await fetchEvents(
                    forCalendarID: calendar.id,
                    daysAhead: resolvedDayCount,
                    windowScope: windowScope,
                    fetchGeneration: fetchGeneration,
                    now: now
                )
            } catch let authError as GoogleCalendarAuthError {
                throw authError
            } catch GoogleCalendarClientError.staleRequest {
                throw GoogleCalendarClientError.staleRequest
            } catch {
                try ensureCurrentFetch(fetchGeneration)
                fputs("[google-cal] events fetch failed for \(calendar.id), keeping cached events: \(error)\n", stderr)
                failedCalendarIDs.insert(calendar.id)
                completedAllFetches = false
            }
        }

        let merged = cachedEventsByCalendar
            .filter { calendarID, _ in
                guard let cachedScope = cachedEventScopesByCalendar[calendarID] else {
                    return false
                }
                if cachedScope == windowScope {
                    return true
                }
                guard failedCalendarIDs.contains(calendarID) else {
                    return false
                }
                return cachedScope.covers(windowScope) ||
                    (cachedScope.dayCount == windowScope.dayCount && cachedScope.overlaps(windowScope))
            }
            .values
            .flatMap { $0.values }
            .filter { $0.endDate > now && $0.startDate < future }
        return GoogleCalendarFetchResult(
            events: merged.sorted { $0.startDate < $1.startDate },
            wasComplete: completedAllFetches
        )
    }

    /// Fetch events for a single calendar, populating `cachedEventsByCalendar[calendarID]`.
    /// Uses the per-calendar sync token if present; falls back to a windowed query otherwise.
    /// Handles pagination, 401 refresh, and 410 sync-token expiry per calendar.
    private func fetchEvents(
        forCalendarID calendarID: String,
        daysAhead: Int,
        windowScope: EventWindowScope,
        fetchGeneration: Int,
        now: Date,
        isRetry: Bool = false
    ) async throws {
        var token = try await auth.validAccessToken()
        let isoFormatter = Self.isoFormatter

        let isFullWindowFetch = syncTokens[calendarID] == nil
        var bucket = isFullWindowFetch ? [:] : cachedEventsByCalendar[calendarID] ?? [:]
        var pageToken: String? = nil
        var tokenRetried = false

        let escapedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID

        repeat {
            var components = URLComponents(string: "\(Self.baseURL)/calendars/\(escapedID)/events")!

            if let pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
            } else if let syncToken = syncTokens[calendarID] {
                components.queryItems = [URLQueryItem(name: "syncToken", value: syncToken)]
            } else {
                guard let future = UpcomingMeetingsWindow.endDate(from: now, dayCount: daysAhead) else {
                    throw GoogleCalendarClientError.requestFailed("invalid upcoming events window")
                }
                components.queryItems = [
                    URLQueryItem(name: "timeMin", value: isoFormatter.string(from: now)),
                    URLQueryItem(name: "timeMax", value: isoFormatter.string(from: future)),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "maxResults", value: "250"),
                ]
            }

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 410 {
                guard !isRetry else {
                    fputs("[google-cal] 410 on full re-fetch for \(calendarID), giving up\n", stderr)
                    throw GoogleCalendarClientError.requestFailed("events sync token expired during full re-fetch")
                }
                fputs("[google-cal] sync token expired for \(calendarID), performing full re-fetch\n", stderr)
                try ensureCurrentFetch(fetchGeneration)
                syncTokens.removeValue(forKey: calendarID)
                return try await fetchEvents(
                    forCalendarID: calendarID,
                    daysAhead: daysAhead,
                    windowScope: windowScope,
                    fetchGeneration: fetchGeneration,
                    now: now,
                    isRetry: true
                )
            }

            if statusCode == 401 && !tokenRetried {
                tokenRetried = true
                token = try await auth.validAccessToken()
                continue
            }

            guard statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                fputs("[google-cal] API error \(statusCode) for \(calendarID): \(body.prefix(200))\n", stderr)
                if statusCode == 401 || statusCode == 403 {
                    throw GoogleCalendarAuthError.notAuthenticated
                }
                throw GoogleCalendarClientError.requestFailed("events returned \(statusCode)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GoogleCalendarClientError.requestFailed("events returned malformed JSON")
            }

            if let items = json["items"] as? [[String: Any]] {
                for item in items {
                    guard let id = item["id"] as? String else { continue }
                    if item["status"] as? String == "cancelled" {
                        bucket.removeValue(forKey: id)
                        continue
                    }
                    if let event = parseEvent(item, calendarID: calendarID) {
                        bucket[id] = event
                    }
                }
            }
            if let nextPage = json["nextPageToken"] as? String {
                pageToken = nextPage
            } else {
                pageToken = nil
                try ensureCurrentFetch(fetchGeneration)
                if let newSyncToken = json["nextSyncToken"] as? String {
                    syncTokens[calendarID] = newSyncToken
                }
                cachedEventsByCalendar[calendarID] = bucket
                cachedEventScopesByCalendar[calendarID] = windowScope
            }
        } while pageToken != nil
    }

    private func ensureCurrentFetch(_ fetchGeneration: Int) throws {
        guard fetchGeneration == upcomingEventsFetchGeneration else {
            throw GoogleCalendarClientError.staleRequest
        }
    }

    /// Enumerate every Google calendar the authenticated user can read.
    /// Does not touch the event cache — purely descriptive.
    func fetchCalendarList() async throws -> [GoogleCalendarSummary] {
        var token = try await auth.validAccessToken()
        var pageToken: String? = nil
        var tokenRetried = false
        var results: [GoogleCalendarSummary] = []

        repeat {
            var components = URLComponents(string: "\(Self.baseURL)/users/me/calendarList")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "minAccessRole", value: "reader"),
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 401 && !tokenRetried {
                tokenRetried = true
                token = try await auth.validAccessToken()
                continue
            }

            guard statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                fputs("[google-cal] calendarList error \(statusCode): \(body.prefix(200))\n", stderr)
                if statusCode == 401 || statusCode == 403 {
                    throw GoogleCalendarAuthError.notAuthenticated
                }
                throw GoogleCalendarClientError.requestFailed("calendarList returned \(statusCode)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GoogleCalendarClientError.requestFailed("calendarList returned malformed JSON")
            }
            if let entries = json["items"] as? [[String: Any]] {
                for entry in entries {
                    if let summary = Self.parseCalendarListEntry(entry) {
                        results.append(summary)
                    }
                }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        return results.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.summary.localizedCaseInsensitiveCompare(rhs.summary) == .orderedAscending
        }
    }

    /// Parse a single `calendarList` entry. Static + pure for tests.
    static func parseCalendarListEntry(_ entry: [String: Any]) -> GoogleCalendarSummary? {
        guard let id = entry["id"] as? String else { return nil }
        let summary = (entry["summaryOverride"] as? String)
            ?? (entry["summary"] as? String)
            ?? id
        let isPrimary = (entry["primary"] as? Bool) ?? false
        let bgColor = entry["backgroundColor"] as? String
        let colorHex = bgColor?.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return GoogleCalendarSummary(
            id: id,
            summary: summary,
            isPrimary: isPrimary,
            colorHex: colorHex
        )
    }

    /// Clear cached state (call on sign-out).
    func resetSync() {
        syncTokens.removeAll()
        cachedEventsByCalendar.removeAll()
        cachedEventScopesByCalendar.removeAll()
        cachedEventWindowDayCount = nil
        cachedEventWindowStartOfDay = nil
        cachedCalendarList.removeAll()
    }

    @discardableResult
    func resetEventSyncIfNeededForWindow(
        daysAhead: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let resolvedDayCount = UpcomingMeetingsWindow.resolve(dayCount: daysAhead).dayCount
        let windowStartOfDay = calendar.startOfDay(for: now)
        guard cachedEventWindowDayCount != resolvedDayCount ||
            cachedEventWindowStartOfDay != windowStartOfDay else { return false }
        syncTokens.removeAll()
        cachedEventWindowDayCount = resolvedDayCount
        cachedEventWindowStartOfDay = windowStartOfDay
        return true
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    func parseEvent(_ item: [String: Any], calendarID: String) -> UnifiedCalendarEvent? {
        guard let id = item["id"] as? String,
              let summary = item["summary"] as? String else { return nil }

        let startDict = item["start"] as? [String: Any] ?? [:]
        let endDict = item["end"] as? [String: Any] ?? [:]

        let isoFormatter = Self.isoFormatter
        let dateOnlyFormatter = Self.dateOnlyFormatter

        let startDate: Date
        let endDate: Date
        let isAllDay: Bool

        if let dateTimeStr = startDict["dateTime"] as? String,
           let start = isoFormatter.date(from: dateTimeStr) {
            startDate = start
            isAllDay = false
            if let endStr = endDict["dateTime"] as? String, let end = isoFormatter.date(from: endStr) {
                endDate = end
            } else {
                endDate = start.addingTimeInterval(3600)
            }
        } else if let dateStr = startDict["date"] as? String,
                  let start = dateOnlyFormatter.date(from: dateStr) {
            startDate = start
            isAllDay = true
            if let endStr = endDict["date"] as? String, let end = dateOnlyFormatter.date(from: endStr) {
                endDate = end
            } else {
                endDate = start.addingTimeInterval(86400)
            }
        } else {
            return nil
        }

        // Extract meeting URL from hangoutLink or conferenceData
        let meetingURL: URL? = {
            if let hangout = item["hangoutLink"] as? String, let url = URL(string: hangout) {
                return url
            }
            if let confData = item["conferenceData"] as? [String: Any],
               let entryPoints = confData["entryPoints"] as? [[String: Any]] {
                for ep in entryPoints {
                    if ep["entryPointType"] as? String == "video",
                       let uri = ep["uri"] as? String, let url = URL(string: uri) {
                        return url
                    }
                }
            }
            return nil
        }()
        let recurringEventID = item["recurringEventId"] as? String
        let originalStartTime: Date = {
            guard let originalStart = item["originalStartTime"] as? [String: Any] else {
                return startDate
            }
            if let value = originalStart["dateTime"] as? String,
               let date = isoFormatter.date(from: value) {
                return date
            }
            if let value = originalStart["date"] as? String,
               let date = dateOnlyFormatter.date(from: value) {
                return date
            }
            return startDate
        }()
        let occurrence = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: calendarID,
            eventID: id,
            seriesID: recurringEventID,
            originalStartTime: originalStartTime
        )

        return UnifiedCalendarEvent(
            id: id,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            source: .googleCalendar,
            calendarID: calendarID,
            calendarOccurrence: occurrence,
            meetingURL: meetingURL
        )
    }

    // MARK: - Merge & Deduplicate

    /// Merge EventKit and Google Calendar events, deduplicating by title + start time proximity.
    /// When an EventKit event deduplicates a Google Calendar event, the Google event's
    /// meetingURL is preserved if the EventKit version has none (hangoutLink/conferenceData
    /// from the API is richer than what EventKit syncs).
    static func mergeEvents(
        eventKit: [UnifiedCalendarEvent],
        google: [UnifiedCalendarEvent]
    ) -> [UnifiedCalendarEvent] {
        var merged = eventKit

        for gEvent in google {
            if let idx = merged.firstIndex(where: { ekEvent in
                ekEvent.title.lowercased() == gEvent.title.lowercased()
                    && abs(ekEvent.startDate.timeIntervalSince(gEvent.startDate)) < 300
            }) {
                // Prefer Google Calendar's meetingURL when EventKit doesn't have one
                if merged[idx].meetingURL == nil, gEvent.meetingURL != nil {
                    merged[idx].meetingURL = gEvent.meetingURL
                }
            } else {
                merged.append(gEvent)
            }
        }

        return merged.sorted { $0.startDate < $1.startDate }
    }
}
