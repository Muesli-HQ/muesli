import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("MeetingNotesView inline markdown")
struct MeetingNotesInlineMarkdownTests {

    private func rendered(_ markdown: String) -> String {
        String(MeetingNotesView.inline(markdown).characters)
    }

    @Test("bold, italic, and code markers are consumed")
    func inlineMarkersAreParsed() {
        #expect(rendered("Shipped **today** as agreed") == "Shipped today as agreed")
        #expect(rendered("Marked *urgent* by Priya") == "Marked urgent by Priya")
        #expect(rendered("Run `swift test` first") == "Run swift test first")
    }

    @Test("bold applies emphasis rather than dropping the text")
    func boldCarriesEmphasis() {
        let attributed = MeetingNotesView.inline("Owner: **Priya**")
        let bolded = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }

        #expect(bolded.count == 1)
        #expect(bolded.map { String(attributed[$0.range].characters) } == ["Priya"])
    }

    @Test("italic applies emphasis")
    func italicCarriesEmphasis() {
        let attributed = MeetingNotesView.inline("Marked *urgent*")
        let italics = attributed.runs.filter { $0.inlinePresentationIntent == .emphasized }

        #expect(italics.map { String(attributed[$0.range].characters) } == ["urgent"])
    }

    @Test("a link keeps its label and resolves its destination")
    func linksResolve() {
        let attributed = MeetingNotesView.inline("See [the spec](https://example.com)")

        #expect(String(attributed.characters) == "See the spec")
        #expect(attributed.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    @Test("plain text is unchanged")
    func plainTextUnchanged() {
        #expect(rendered("No formatting here") == "No formatting here")
        #expect(rendered("") == "")
    }

    @Test("block markers in body text stay literal")
    func blockMarkersAreNotReinterpreted() {
        // Headings and bullets are matched by the line renderer, so the inline
        // parser must not swallow these when they appear mid-note.
        #expect(rendered("Ticket #123 was closed") == "Ticket #123 was closed")
        #expect(rendered("Use - for bullets") == "Use - for bullets")
        #expect(rendered("Costs 50% - 60% more") == "Costs 50% - 60% more")
    }

    @Test("unmatched markers are left as written")
    func unmatchedMarkersSurvive() {
        #expect(rendered("2 * 3 * 4 equals 24") == "2 * 3 * 4 equals 24")
        #expect(rendered("An unclosed **bold") == "An unclosed **bold")
    }

    @Test("leading and trailing whitespace is preserved")
    func whitespaceIsPreserved() {
        // inlineOnlyPreservingWhitespace keeps indentation the caller relies on.
        #expect(rendered("  indented note  ") == "  indented note  ")
    }
}
