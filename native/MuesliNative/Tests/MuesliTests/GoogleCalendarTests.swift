import Testing
import EventKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Google Calendar integration")
@MainActor
struct GoogleCalendarTests {

    // MARK: - Credentials parsing

    @Test("loads credentials from valid JSON")
    func loadsValidCredentials() throws {
        let json = """
        {"client_id": "test-id.apps.googleusercontent.com", "client_secret": "test-secret"}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-creds-\(UUID()).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let clientId = parsed["client_id"] as? String
        let clientSecret = parsed["client_secret"] as? String

        #expect(clientId == "test-id.apps.googleusercontent.com")
        #expect(clientSecret == "test-secret")
    }

    @Test("verified defaults to false when missing from JSON")
    func verifiedDefaultsFalse() throws {
        let json = """
        {"client_id": "id", "client_secret": "secret"}
        """
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let verified = parsed["verified"] as? Bool ?? false
        #expect(verified == false)
    }

    @Test("verified reads true from JSON")
    func verifiedReadsTrue() throws {
        let json = """
        {"client_id": "id", "client_secret": "secret", "verified": true}
        """
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let verified = parsed["verified"] as? Bool ?? false
        #expect(verified == true)
    }

    // MARK: - Event JSON parsing

    @Test("parses timed event from Google Calendar API response")
    func parsesTimedEvent() {
        let item: [String: Any] = [
            "id": "event123",
            "summary": "Sprint Planning",
            "start": ["dateTime": "2026-04-10T14:00:00+05:30"],
            "end": ["dateTime": "2026-04-10T15:00:00+05:30"],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event != nil)
        #expect(event?.id == "event123")
        #expect(event?.title == "Sprint Planning")
        #expect(event?.isAllDay == false)
        #expect(event?.source == .googleCalendar)
    }

    @Test("parses all-day event from Google Calendar API response")
    func parsesAllDayEvent() {
        let item: [String: Any] = [
            "id": "allday1",
            "summary": "Company Holiday",
            "start": ["date": "2026-04-10"],
            "end": ["date": "2026-04-11"],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event != nil)
        #expect(event?.isAllDay == true)
        #expect(event?.title == "Company Holiday")
    }

    @Test("returns nil for event missing summary")
    func returnsNilMissingSummary() {
        let item: [String: Any] = [
            "id": "no-title",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]

        #expect(GoogleCalendarClient().parseEvent(item, calendarID: "primary") == nil)
    }

    @Test("returns nil for event missing id")
    func returnsNilMissingId() {
        let item: [String: Any] = [
            "summary": "Test",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]

        #expect(GoogleCalendarClient().parseEvent(item, calendarID: "primary") == nil)
    }

    // MARK: - Meeting URL extraction

    @Test("parses hangoutLink from Google Calendar event")
    func parsesHangoutLink() {
        let item: [String: Any] = [
            "id": "meet1",
            "summary": "Team Sync",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
            "hangoutLink": "https://meet.google.com/abc-defg-hij",
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.meetingURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("parses conferenceData video entryPoint from Google Calendar event")
    func parsesConferenceDataURL() {
        let item: [String: Any] = [
            "id": "zoom1",
            "summary": "Client Call",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
            "conferenceData": [
                "entryPoints": [
                    ["entryPointType": "video", "uri": "https://us02web.zoom.us/j/123456789"],
                ],
            ],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.meetingURL?.absoluteString == "https://us02web.zoom.us/j/123456789")
    }

    @Test("meetingURL is nil when no conference link present")
    func noMeetingURLWhenAbsent() {
        let item: [String: Any] = [
            "id": "plain1",
            "summary": "Lunch",
            "start": ["dateTime": "2026-04-10T12:00:00Z"],
            "end": ["dateTime": "2026-04-10T13:00:00Z"],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.meetingURL == nil)
    }

    @Test("CalendarMonitor extracts Zoom URL from text")
    func extractsZoomURL() {
        let url = CalendarMonitor.findMeetingURL(in: "Join at https://us02web.zoom.us/j/123456789?pwd=abc please")
        #expect(url?.host?.contains("zoom.us") == true)
    }

    @Test("CalendarMonitor extracts Google Meet URL from text")
    func extractsGoogleMeetURL() {
        let url = CalendarMonitor.findMeetingURL(in: "https://meet.google.com/abc-defg-hij")
        #expect(url?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("CalendarMonitor returns nil for text without meeting URLs")
    func returnsNilForNonMeetingText() {
        let url = CalendarMonitor.findMeetingURL(in: "Conference room 3B on the second floor")
        #expect(url == nil)
    }

    // MARK: - EventKit occurrence identity

    @Test("EventKit one-off event identity survives rescheduling")
    func eventKitOneOffIdentitySurvivesRescheduling() {
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        let originalStart = date("2026-04-10T14:00:00Z")
        event.startDate = originalStart
        event.endDate = originalStart.addingTimeInterval(30 * 60)

        let originalReference = CalendarMonitor.occurrenceReference(
            for: event,
            eventID: "one-off-event",
            startDate: originalStart
        )

        let movedStart = originalStart.addingTimeInterval(90 * 60)
        event.startDate = movedStart
        event.endDate = movedStart.addingTimeInterval(30 * 60)
        let movedReference = CalendarMonitor.occurrenceReference(
            for: event,
            eventID: "one-off-event",
            startDate: movedStart
        )

        #expect(originalReference.seriesID == nil)
        #expect(movedReference.seriesID == nil)
        #expect(originalReference.identityKey == movedReference.identityKey)
    }

    @Test("EventKit recurrence uses the server-stable series identifier")
    func eventKitRecurrenceUsesExternalSeriesIdentifier() throws {
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        let start = date("2026-04-10T14:00:00Z")
        event.startDate = start
        event.endDate = start.addingTimeInterval(30 * 60)
        event.addRecurrenceRule(
            EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        )

        let externalIdentifier = try #require(event.calendarItemExternalIdentifier)
        let reference = CalendarMonitor.occurrenceReference(
            for: event,
            eventID: "store-local-event-id",
            startDate: start
        )

        #expect(reference.seriesID == externalIdentifier)
        #expect(reference.seriesID != reference.eventID)
        #expect(reference.originalStartTime == event.occurrenceDate)
    }

    // MARK: - Merge & dedup

    @Test("merges EventKit and Google events without duplicates")
    func mergesWithoutDuplicates() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Standup", startDate: date("2026-04-10T09:00:00Z"), endDate: date("2026-04-10T09:15:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Design Review", startDate: date("2026-04-10T10:00:00Z"), endDate: date("2026-04-10T11:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 2)
        #expect(merged[0].title == "Standup")
        #expect(merged[1].title == "Design Review")
    }

    @Test("deduplicates events with same title and close start time")
    func deduplicatesByTitleAndTime() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Sprint Planning", startDate: date("2026-04-10T14:00:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Sprint Planning", startDate: date("2026-04-10T14:02:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 1)
        #expect(merged[0].source == .eventKit)
    }

    @Test("keeps events with same title but different times")
    func keepsSameTitleDifferentTimes() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Standup", startDate: date("2026-04-10T09:00:00Z"), endDate: date("2026-04-10T09:15:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Standup", startDate: date("2026-04-11T09:00:00Z"), endDate: date("2026-04-11T09:15:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 2)
    }

    @Test("merged events are sorted by start date")
    func mergedSortedByStartDate() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Late", startDate: date("2026-04-10T16:00:00Z"), endDate: date("2026-04-10T17:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Early", startDate: date("2026-04-10T08:00:00Z"), endDate: date("2026-04-10T09:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged[0].title == "Early")
        #expect(merged[1].title == "Late")
    }

    // MARK: - Cached meeting detection event selection

    @Test("cached meeting detection ignores recently ended events")
    func cachedDetectionIgnoresRecentlyEndedEvents() {
        let now = date("2026-04-10T10:08:00Z")
        let events = [
            UnifiedCalendarEvent(id: "ended", title: "Already done", startDate: date("2026-04-10T09:50:00Z"), endDate: date("2026-04-10T10:00:00Z"), isAllDay: false, source: .eventKit),
        ]

        let selected = selectCurrentOrNearbyCachedCalendarEvent(from: events, now: now)
        #expect(selected == nil)
    }

    @Test("cached meeting detection prefers active over upcoming events")
    func cachedDetectionPrefersActiveEvent() {
        let now = date("2026-04-10T10:02:00Z")
        let events = [
            UnifiedCalendarEvent(id: "upcoming", title: "Next call", startDate: date("2026-04-10T10:04:00Z"), endDate: date("2026-04-10T10:30:00Z"), isAllDay: false, source: .googleCalendar),
            UnifiedCalendarEvent(id: "active", title: "Current call", startDate: date("2026-04-10T09:55:00Z"), endDate: date("2026-04-10T10:20:00Z"), isAllDay: false, source: .eventKit),
        ]

        let selected = selectCurrentOrNearbyCachedCalendarEvent(from: events, now: now)
        #expect(selected?.id == "active")
        #expect(selected?.title == "Current call")
    }

    @Test("cached meeting detection can select imminent future events")
    func cachedDetectionSelectsImminentFutureEvent() {
        let now = date("2026-04-10T10:00:00Z")
        let events = [
            UnifiedCalendarEvent(id: "later", title: "Later call", startDate: date("2026-04-10T10:20:00Z"), endDate: date("2026-04-10T11:00:00Z"), isAllDay: false, source: .eventKit),
            UnifiedCalendarEvent(id: "soon", title: "Soon call", startDate: date("2026-04-10T10:03:00Z"), endDate: date("2026-04-10T10:30:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let selected = selectCurrentOrNearbyCachedCalendarEvent(from: events, now: now)
        #expect(selected?.id == "soon")
        #expect(selected?.title == "Soon call")
    }

    // MARK: - parseCalendarListEntry

    @Test("parses a calendarList entry with summary, primary flag, and color")
    func parsesCalendarListEntry() {
        let entry: [String: Any] = [
            "id": "primary",
            "summary": "spencer@dockstreet.com",
            "primary": true,
            "backgroundColor": "#9fe1e7",
        ]
        let summary = GoogleCalendarClient.parseCalendarListEntry(entry)
        #expect(summary?.id == "primary")
        #expect(summary?.summary == "spencer@dockstreet.com")
        #expect(summary?.isPrimary == true)
        #expect(summary?.colorHex == "9fe1e7")
    }

    @Test("calendarList entry prefers summaryOverride when present")
    func calendarListPrefersOverride() {
        let entry: [String: Any] = [
            "id": "team@dockstreet.com",
            "summary": "team@dockstreet.com",
            "summaryOverride": "Team Standup",
        ]
        let summary = GoogleCalendarClient.parseCalendarListEntry(entry)
        #expect(summary?.summary == "Team Standup")
        #expect(summary?.isPrimary == false)
    }

    @Test("calendarList entry returns nil when id missing")
    func calendarListNilWithoutID() {
        let entry: [String: Any] = ["summary": "no id"]
        #expect(GoogleCalendarClient.parseCalendarListEntry(entry) == nil)
    }

    @Test("parsed event records the calendarID")
    func parsedEventCarriesCalendarID() {
        let item: [String: Any] = [
            "id": "ev1",
            "summary": "Sync",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]
        let event = GoogleCalendarClient().parseEvent(item, calendarID: "team@dockstreet.com")
        #expect(event?.calendarID == "team@dockstreet.com")
    }

    @Test("parsed recurring event keeps its immutable occurrence identity")
    func parsedRecurringEventCarriesOriginalStartTime() throws {
        let item: [String: Any] = [
            "id": "series_20260410T140000Z",
            "recurringEventId": "series",
            "summary": "Daily sync",
            "originalStartTime": ["dateTime": "2026-04-10T14:00:00Z"],
            "start": ["dateTime": "2026-04-10T15:30:00Z"],
            "end": ["dateTime": "2026-04-10T16:00:00Z"],
        ]

        let event = try #require(
            GoogleCalendarClient().parseEvent(item, calendarID: "team@dockstreet.com")
        )
        let occurrence = try #require(event.calendarOccurrence)

        #expect(occurrence.provider == .googleCalendar)
        #expect(occurrence.calendarID == "team@dockstreet.com")
        #expect(occurrence.eventID == "series_20260410T140000Z")
        #expect(occurrence.seriesID == "series")
        #expect(occurrence.originalStartTime == date("2026-04-10T14:00:00Z"))
        #expect(event.startDate == date("2026-04-10T15:30:00Z"))
    }

    @Test("calendar placeholders deduplicate one occurrence but allow the next recurrence")
    func calendarPlaceholderOccurrenceDeduplication() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-calendar-occurrence-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let firstStart = date("2026-04-10T14:00:00Z")
        let firstOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "work",
            eventID: "shared-series-id",
            seriesID: "shared-series-id",
            originalStartTime: firstStart
        )
        let firstEvent = UnifiedCalendarEvent(
            id: "shared-series-id",
            title: "Daily sync",
            startDate: firstStart,
            endDate: firstStart.addingTimeInterval(30 * 60),
            isAllDay: false,
            source: .eventKit,
            calendarID: "work",
            calendarOccurrence: firstOccurrence
        )
        controller.createMeetingFromCalendarEvent(firstEvent, folderID: nil)
        controller.createMeetingFromCalendarEvent(firstEvent, folderID: nil)

        let nextStart = firstStart.addingTimeInterval(24 * 60 * 60)
        let nextOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "work",
            eventID: "shared-series-id",
            seriesID: "shared-series-id",
            originalStartTime: nextStart
        )
        let nextEvent = UnifiedCalendarEvent(
            id: "shared-series-id",
            title: "Daily sync",
            startDate: nextStart,
            endDate: nextStart.addingTimeInterval(30 * 60),
            isAllDay: false,
            source: .eventKit,
            calendarID: "work",
            calendarOccurrence: nextOccurrence
        )
        controller.createMeetingFromCalendarEvent(nextEvent, folderID: nil)

        let meetings = try store.recentMeetings(limit: 10)
        #expect(meetings.count == 2)
        #expect(Set(meetings.compactMap(\.calendarOccurrence?.identityKey)) == Set([
            firstOccurrence.identityKey,
            nextOccurrence.identityKey,
        ]))
    }

    @Test("event sync cache resets when upcoming window changes")
    func eventSyncCacheResetsWhenWindowChanges() {
        let client = GoogleCalendarClient()

        #expect(client.resetEventSyncIfNeededForWindow(daysAhead: 1))
        #expect(!client.resetEventSyncIfNeededForWindow(daysAhead: 1))
        #expect(client.resetEventSyncIfNeededForWindow(daysAhead: 3))

        client.resetSync()
        #expect(client.resetEventSyncIfNeededForWindow(daysAhead: 3))
    }

    @Test("event sync cache resets when upcoming window advances to a new local day")
    func eventSyncCacheResetsWhenWindowDayChanges() {
        let client = GoogleCalendarClient()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        #expect(client.resetEventSyncIfNeededForWindow(
            daysAhead: 3,
            now: date("2026-04-10T21:00:00Z"),
            calendar: calendar
        ))
        #expect(!client.resetEventSyncIfNeededForWindow(
            daysAhead: 3,
            now: date("2026-04-10T23:00:00Z"),
            calendar: calendar
        ))
        #expect(client.resetEventSyncIfNeededForWindow(
            daysAhead: 3,
            now: date("2026-04-11T00:01:00Z"),
            calendar: calendar
        ))
    }

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

}
