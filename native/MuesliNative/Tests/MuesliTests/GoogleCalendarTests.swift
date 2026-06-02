import Testing
import Foundation
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

    @Test("parses organizer and attendee emails from Google Calendar event")
    func parsesEventAttendees() {
        let item: [String: Any] = [
            "id": "attendees1",
            "summary": "Client Call",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
            "organizer": ["displayName": "Sam Gaddis", "email": "sam@runpoint.ai"],
            "attendees": [
                ["displayName": "Pat Prospect", "email": "pat@example.com"],
                ["displayName": "Conference Room", "email": "room@example.com", "resource": true],
                ["displayName": "Sam Gaddis", "email": "sam@runpoint.ai"],
            ],
        ]

        let event = GoogleCalendarClient().parseEvent(item, calendarID: "primary")
        #expect(event?.attendees.map(\.markdownLabel) == [
            "Sam Gaddis <sam@runpoint.ai>",
            "Pat Prospect <pat@example.com>",
        ])
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

    @Test("dedupe preserves Google attendees when EventKit has none")
    func dedupePreservesGoogleAttendees() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Sprint Planning", startDate: date("2026-04-10T14:00:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(
                id: "g1",
                title: "Sprint Planning",
                startDate: date("2026-04-10T14:02:00Z"),
                endDate: date("2026-04-10T15:00:00Z"),
                isAllDay: false,
                source: .googleCalendar,
                attendees: [CalendarEventAttendee(name: "Pat Prospect", email: "pat@example.com")]
            ),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 1)
        #expect(merged[0].attendees.map(\.markdownLabel) == ["Pat Prospect <pat@example.com>"])
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

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

}
