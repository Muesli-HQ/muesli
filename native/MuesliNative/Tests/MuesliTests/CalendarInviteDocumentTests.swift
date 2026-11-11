import Foundation
import EventKit
import Testing
@testable import MuesliNativeApp

@Suite("Calendar invite documents")
@MainActor
struct CalendarInviteDocumentTests {
    @Test func attachmentTitlesAndDeduplication() {
        let documents = CalendarInviteDocument.extract(
            attachments: [["fileUrl": "https://drive.google.com/open?id=abc", "title": "Design brief"]],
            text: "<a href=\"https://docs.google.com/document/d/abc/edit?usp=sharing\">Brief</a> https://docs.google.com/document/d/abc/view")
        #expect(documents.count == 1)
        #expect(documents.first?.title == "Design brief")
    }

    @Test func wrappedLinksAndConferenceSeparation() {
        let documents = CalendarInviteDocument.extract(text: """
        <a href="https://www.google.com/url?q=https%3A%2F%2Fdocs.google.com%2Fspreadsheets%2Fd%2Fsheet%2Fedit&amp;sa=D">Budget &amp; forecast</a>
        https://meet.google.com/abc-defg-hij
        https://example.com/agenda.pdf
        """)
        #expect(documents.contains { $0.title == "Budget & forecast" && $0.url.host == "docs.google.com" && $0.symbol == "tablecells" })
        #expect(!documents.contains { $0.url.host == "meet.google.com" })
        #expect(documents.contains { $0.title == "agenda" })
        #expect(CalendarInviteDocument.safeURL("https://nam01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fbrief")?.absoluteString == "https://example.com/brief")
    }

    @Test func ignoresDefaultMeetBoilerplate() {
        let documents = CalendarInviteDocument.extract(text: """
        https://meet.google.com/abc-defg-hij
        https://tel.meet/abc-defg-hij?pin=123456
        https://support.google.com/meet/answer/7317473
        https://www.google.com/url?q=https%3A%2F%2Ftel.meet%2Fabc-defg-hij
        <a href="https://docs.google.com/forms/d/form-id/viewform">form</a>
        <a href="https://docs.google.com/spreadsheets/d/sheet-id/edit">Google Sheet</a>
        """)
        #expect(documents.map(\.title) == ["Google form", "Google spreadsheet"])
        #expect(documents.allSatisfy { $0.needsResolvedTitle })
        #expect(!CalendarInviteDocument.isConferenceBoilerplate(URL(string: "https://support.google.com/docs/answer/1")!))
    }

    @Test func wrappedConferenceDiscovery() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.url = URL(string: "https://www.google.com/url?q=https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij")
        #expect(CalendarMonitor.extractMeetingURL(from: event)?.host == "meet.google.com")
        #expect(CalendarMonitor.findMeetingURL(in: "https://www.google.com/url?q=https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij")?.host == "meet.google.com")
        #expect(CalendarMonitor.findMeetingURL(in: "https://nam01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij")?.host == "meet.google.com")
    }

    @Test func rejectsUnsafeLinks() {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "https://user:secret@example.com/doc",
                      "https://www.google.com/url?q=javascript%3Aalert(1)", "https://www.google.com/url?q=file%3A%2F%2F%2Ftmp%2Fa"] {
            #expect(CalendarInviteDocument.safeURL(value) == nil)
        }
        #expect(CalendarInviteDocument.extract(eventURL: URL(string: "file:///tmp/private")).isEmpty)
        #expect(!CalendarMonitor.isMeetingURL(URL(string: "https://evilzoom.us/path")!))
        #expect(!CalendarMonitor.isMeetingURL(URL(string: "file://meet.google.com/path")!))
    }

    @Test func eventURLAndFallbackTitles() {
        let documents = CalendarInviteDocument.extract(text: "https://docs.google.com/presentation/d/slides/edit",
                                                        eventURL: URL(string: "https://example.com/context"))
        #expect(documents.map(\.title) == ["Google presentation", "example.com"])
        #expect(documents.first?.symbol == "rectangle.on.rectangle")
    }

    @Test func mergedInvitesPreferProvidedTitles() {
        let fallback = CalendarInviteDocument.extract(text: "https://docs.google.com/document/d/abc/edit")
        let titled = CalendarInviteDocument.extract(attachments: [["fileUrl": "https://drive.google.com/file/d/abc/view", "title": "Plan"]])
        #expect(CalendarInviteDocument.merge(fallback + titled).map(\.title) == ["Plan"])
        let now = Date()
        var ek = UnifiedCalendarEvent(id: "ek", title: "Review", startDate: now, endDate: now.addingTimeInterval(1800), isAllDay: false, source: .eventKit)
        var google = UnifiedCalendarEvent(id: "g", title: "Review", startDate: now, endDate: now.addingTimeInterval(1800), isAllDay: false, source: .googleCalendar)
        ek.documents = fallback
        google.documents = titled
        #expect(GoogleCalendarClient.mergeEvents(eventKit: [ek], google: [google]).first?.documents.map(\.title) == ["Plan"])
    }
}
