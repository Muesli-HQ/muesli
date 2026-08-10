import Foundation
import AppKit
import SwiftUI
import Testing
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

    @Test("the rich editor renders and round-trips inline Markdown")
    @MainActor
    func richEditorRendersAndRoundTripsInlineMarkdown() {
        let source = "Owner: **Priya**, *urgent*, `swift test`, [spec](https://example.com)"
        var boundMarkdown = ""
        var command: MarkdownEditorCommand?
        let coordinator = MarkdownRichTextEditor.Coordinator(
            text: Binding(
                get: { boundMarkdown },
                set: { boundMarkdown = $0 }
            ),
            command: Binding(
                get: { command },
                set: { command = $0 }
            ),
            onTextChange: nil
        )
        let textView = NSTextView(frame: .zero)

        coordinator.apply(markdown: source, to: textView)

        #expect(textView.string == "Owner: Priya, urgent, swift test, spec")
        #expect(coordinator.serializedMarkdown(from: textView) == source)
    }

    @Test("completed inline markers render during typing")
    @MainActor
    func completedInlineMarkersRenderDuringTyping() {
        var boundMarkdown = ""
        var command: MarkdownEditorCommand?
        let coordinator = MarkdownRichTextEditor.Coordinator(
            text: Binding(
                get: { boundMarkdown },
                set: { boundMarkdown = $0 }
            ),
            command: Binding(
                get: { command },
                set: { command = $0 }
            ),
            onTextChange: nil
        )
        let textView = NSTextView(frame: .zero)
        coordinator.apply(markdown: "Owner: ", to: textView)
        textView.textStorage?.append(NSAttributedString(string: "**Priya**", attributes: coordinator.bodyAttributes()))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textView.string == "Owner: Priya")
        #expect(coordinator.serializedMarkdown(from: textView) == "Owner: **Priya**")
    }

    @Test("the bullet command transforms every selected line")
    @MainActor
    func bulletCommandTransformsSelectedLines() async {
        let source = "Still Not showing up\nWhy\nIs this\nHappening"
        var boundMarkdown = source
        var command: MarkdownEditorCommand?
        var changeCount = 0
        let coordinator = MarkdownRichTextEditor.Coordinator(
            text: Binding(
                get: { boundMarkdown },
                set: { boundMarkdown = $0 }
            ),
            command: Binding(
                get: { command },
                set: { command = $0 }
            ),
            onTextChange: { _ in changeCount += 1 }
        )
        let textView = NSTextView(frame: .zero)
        coordinator.apply(markdown: source, to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        let bulletCommand = MarkdownEditorCommand(kind: .bullet)
        command = bulletCommand

        // SwiftUI can call updateNSView repeatedly before the queued command
        // runs; the same command ID must still be delivered exactly once.
        coordinator.schedule(bulletCommand, in: textView)
        coordinator.schedule(bulletCommand, in: textView)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(textView.string == "• Still Not showing up\n• Why\n• Is this\n• Happening")
        #expect(boundMarkdown == "- Still Not showing up\n- Why\n- Is this\n- Happening")
        #expect(changeCount == 1)
        #expect(command == nil)
    }
}
