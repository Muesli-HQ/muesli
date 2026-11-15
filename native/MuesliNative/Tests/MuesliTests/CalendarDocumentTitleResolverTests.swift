import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Calendar document titles")
@MainActor
struct CalendarDocumentTitleResolverTests {
    @Test func extractsRealTitleAndRejectsSignInPages() {
        #expect(CalendarDocumentTitleResolver.pageTitle("<head><title>Quarterly plan &amp; budget - Google Sheets</title></head>") == "Quarterly plan & budget")
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Team&#39;s plan &#x2014; 2026</title>") == "Team's plan — 2026")
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Sign in - Google Accounts</title>") == nil)
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Google Sheets</title>") == nil)
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Access denied</title>") == nil)
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Google Docs: Sign-in</title>") == nil)
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Login flow redesign - Google Docs</title>") == "Login flow redesign")
        #expect(CalendarDocumentTitleResolver.pageTitle("<title>Request access workflow - Google Sheets</title>") == "Request access workflow")
    }

    @Test func limitsMetadataDestinations() {
        for url in ["https://docs.google.com/document/d/id/edit", "https://forms.gle/example", "https://workspace.atlassian.net/wiki/page"] {
            #expect(CalendarDocumentTitleResolver.supportsMetadata(URL(string: url)!))
        }
        for url in ["http://docs.google.com/document/d/id/edit", "https://docs.google.com:8443/path", "https://localhost/path", "https://127.0.0.1/path", "https://docs.google.com.evil.test/path", "https://accounts.google.com/login", "https://user:password@docs.google.com/path"] {
            #expect(!CalendarDocumentTitleResolver.supportsMetadata(URL(string: url)!))
        }
    }

    @Test func resolvesGenericTitlesButPreservesInviteLabelsAndCachesFailures() async throws {
        let counter = MetadataCounter()
        let resolver = CalendarDocumentTitleResolver(fetch: { url in
            await counter.increment()
            return url.path.contains("private") ? nil : "Quarterly plan"
        })
        let documents = CalendarInviteDocument.extract(text: """
        <a href="https://docs.google.com/spreadsheets/d/public/edit">Google Sheet</a>
        <a href="https://docs.google.com/document/d/private/edit">Document</a>
        <a href="https://docs.google.com/document/d/named/edit">Invite-provided agenda</a>
        """)
        #expect(await resolver.resolve(documents))
        let first = try #require(documents.first)
        #expect(resolver.title(for: first) == "Quarterly plan")
        #expect(resolver.title(for: documents[1]) == "Google document")
        #expect(resolver.title(for: documents[2]) == "Invite-provided agenda")
        #expect(await counter.count == 2)
        #expect(!(await resolver.resolve(documents)))
        #expect(await counter.count == 2)
    }
}

private actor MetadataCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
