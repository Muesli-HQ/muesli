import Foundation
import AppKit
import MuesliCore
import SwiftUI
import Testing
@testable import MuesliNativeApp

// Exercise AppKit's copy/cut actions without changing the system clipboard.
private final class ClipboardNoteView: PlaceholderTextView {
    let board = NSPasteboard.withUniqueName()
    override var selectionPasteboard: NSPasteboard { board }
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        super.writeSelection(to: board, types: types)
    }
}

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

    @Test("formatting visibility follows text selection and clears at the caret")
    @MainActor
    func formattingSelectionVisibility() async {
        let coordinator = MarkdownRichTextEditor.Coordinator(
            text: .constant("Notes"), command: .constant(nil), onTextChange: nil
        )
        let textView = NSTextView(frame: .zero)
        textView.string = "Notes"
        var selected: Bool?
        var publications = 0
        coordinator.onSelectionChange = { selected = $0; publications += 1 }
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        #expect(selected == nil) // No SwiftUI state writes during an AppKit update.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(selected == true)
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(publications == 1)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(selected == false)
        #expect(publications == 2)
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

    @Test("list actions work at an empty note or blank-line caret", arguments: [false, true], [false, true])
    @MainActor
    func listActionsAtCaret(checkbox: Bool, blankLine: Bool) async {
        let source = blankLine ? "Existing note\n" : ""
        var markdown = source
        let coordinator = MarkdownRichTextEditor.Coordinator(
            text: Binding(get: { markdown }, set: { markdown = $0 }),
            command: .constant(nil), onTextChange: nil
        )
        let textView = NSTextView(frame: .zero)
        coordinator.apply(markdown: source, to: textView)
        textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        coordinator.schedule(MarkdownEditorCommand(kind: checkbox ? .checkbox : .bullet), in: textView)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(textView.string == source + (checkbox ? "☐ " : "• "))
        #expect(markdown == source + (checkbox ? "- [ ] " : "- "))
        #expect(textView.selectedRange().length == 0)
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
    @Test("note images survive editor serialization with surrounding Unicode")
    @MainActor
    func imageMarkdownRoundTrip() {
        let id = UUID()
        let source = "😀 before ![Image](muesli-note-image:\(id.uuidString)) after"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView(frame: .zero)
        coordinator.apply(markdown: source, to: view)
        #expect(coordinator.serializedMarkdown(from: view) == source)
    }

    @Test("summary notes with headings and lists round-trip in the image editor")
    @MainActor
    func summaryMarkdownRoundTrip() {
        let id = UUID()
        let source = "## Summary\n- **Decision:** ship\n- Owner: Priya\n\n### Details\nSee [notes](https://example.com)\n![Image](muesli-note-image:\(id.uuidString))"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView(frame: .zero)
        coordinator.apply(markdown: source, to: view)
        #expect(coordinator.serializedMarkdown(from: view) == source)
    }

    @Test("editing an existing summary preserves raw Markdown around images")
    @MainActor
    func rawSummaryMarkdownRoundTrip() {
        let source = "## Summary\n```swift\nlet value = 2 * 3\n```\n> Quote\n| A | B |\n![Image](muesli-note-image:\(UUID().uuidString))"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil),
            onTextChange: nil, renderMarkdownFormatting: false)
        let view = NSTextView(frame: .zero)
        coordinator.apply(markdown: source, to: view)
        #expect(coordinator.serializedMarkdown(from: view) == source)
    }

    @Test("editing beside an image reuses the attachment")
    @MainActor
    func imageAttachmentIsReusedDuringTyping() throws {
        let source = "Before ![Image](muesli-note-image:\(UUID().uuidString)) after"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView(frame: .zero)
        view.delegate = coordinator
        coordinator.apply(markdown: source, to: view)
        let index = (view.string as NSString).range(of: "\u{fffc}").location
        let original = try #require(view.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)
        view.insertText("!", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        let current = try #require(view.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)
        #expect(current === original)
        #expect(coordinator.serializedMarkdown(from: view) == source + "!")
    }

    @Test("moving an image preserves the reference and surrounding Unicode")
    @MainActor
    func imageMovesInBothDirections() {
        let marker = "![Image](muesli-note-image:\(UUID().uuidString))"
        let source = "😀 first \(marker) last"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView(frame: .zero)
        view.isEditable = true
        view.delegate = coordinator
        coordinator.apply(markdown: source, to: view)
        let image = (view.string as NSString).range(of: "\u{fffc}")
        #expect(NoteImageMove.move(in: view, source: image, destination: 0))
        #expect(coordinator.serializedMarkdown(from: view) == "\(marker)😀 first  last")
        #expect(NoteImageMove.move(in: view, source: NSRange(location: 0, length: 1), destination: (view.string as NSString).length))
        #expect(coordinator.serializedMarkdown(from: view) == "😀 first  last\(marker)")
        let last = (view.string as NSString).range(of: "\u{fffc}")
        #expect(!NoteImageMove.move(in: view, source: last, destination: last.location))
        #expect(!NoteImageMove.move(in: view, source: NSRange(location: 0, length: 1), destination: last.location))
    }

    @Test("pointer hit testing recognizes the whole image")
    @MainActor
    func imageHitTesting() throws {
        let marker = "![Image](muesli-note-image:\(UUID().uuidString))"
        let source = "Text before\n\(marker)\nText after"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        view.textContainerInset = NSSize(width: 34, height: 30)
        coordinator.apply(markdown: source, to: view)
        let storage = try #require(view.textStorage)
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let expected = (storage.string as NSString).range(of: "\u{fffc}")
        let attachment = try #require(storage.attribute(.attachment, at: expected.location, effectiveRange: nil) as? NSTextAttachment)
        attachment.bounds = NSRect(x: 0, y: 0, width: 500, height: 250)
        storage.addAttribute(.attachment, value: attachment, range: expected)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: expected.location)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        #expect(rect.width > 0 && rect.height > 0)
        for fraction in [0.1, 0.5, 0.9] {
            let point = NSPoint(x: rect.minX + rect.width * fraction + view.textContainerOrigin.x,
                                y: rect.midY + view.textContainerOrigin.y)
            #expect(NoteImageMove.imageRange(in: view, at: point) == expected)
        }
        #expect(NoteImageMove.imageRange(in: view, at: NSPoint(x: 0, y: 0)) == nil)
        view.setSelectedRange(expected)
        let selection = try #require(NoteImageMove.selectedImageBounds(in: view))
        #expect(selection.width == rect.width && selection.height == rect.height)
        view.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(NoteImageMove.selectedImageBounds(in: view) == nil)
    }

    @Test("typing beside a pasted image never duplicates it")
    @MainActor
    func typingAfterImagePreservesText() {
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(""), command: .constant(nil), onTextChange: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: window.contentView!.bounds)
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = coordinator
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        coordinator.apply(markdown: "", to: view)
        let reference = MeetingNoteImages.Reference(id: UUID(), range: NSRange(location: 0, length: 0))
        coordinator.insertImageReference(reference, into: view, replacing: NSRange(location: 0, length: 0))
        for character in "Hello" { view.insertText(String(character), replacementRange: view.selectedRange()) }
        #expect(coordinator.serializedMarkdown(from: view) == reference.markdown + "Hello")
        #expect(MeetingNoteImages.references(in: coordinator.serializedMarkdown(from: view)).count == 1)
    }

    @Test("list formatting retains inline images", arguments: [MarkdownEditorCommand.Kind.bullet, .checkbox])
    @MainActor
    func listFormattingRetainsImage(command: MarkdownEditorCommand.Kind) {
        let marker = "![Image](muesli-note-image:\(UUID().uuidString))"
        let source = "Before \(marker) after"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isEditable = true
        view.delegate = coordinator
        coordinator.apply(markdown: source, to: view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.perform(command, in: view)
        #expect(coordinator.serializedMarkdown(from: view).contains(marker))
        #expect((view.string as NSString).range(of: "\u{fffc}").location != NSNotFound)
    }

    @Test("list commands keep the caret after an unterminated line", arguments: [MarkdownEditorCommand.Kind.bullet, .checkbox])
    @MainActor
    func listCaretAtEnd(command: MarkdownEditorCommand.Kind) {
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant("Notes"), command: .constant(nil), onTextChange: nil)
        let view = NSTextView()
        coordinator.apply(markdown: "Notes", to: view)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.perform(command, in: view)
        #expect(view.selectedRange().location == (view.string as NSString).length)
        view.insertText("!", replacementRange: view.selectedRange())
        #expect(view.string.hasSuffix("Notes!"))
    }

    @Test("heading formatting includes the last character", arguments: ["Notes", "Notes\n", "Notes\r\n"])
    @MainActor
    func headingIncludesLastCharacter(source: String) throws {
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView()
        coordinator.apply(markdown: source, to: view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.perform(.heading, in: view)
        let first = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let last = try #require(view.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(first == last)
        #expect(coordinator.serializedMarkdown(from: view).hasPrefix("# Notes"))
    }

    @Test("image-leading headings preserve their marker")
    @MainActor
    func imageLeadingHeadingRoundTrip() {
        let source = "# ![Image](muesli-note-image:\(UUID().uuidString)) Caption"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let view = NSTextView()
        coordinator.apply(markdown: source, to: view)
        #expect(coordinator.serializedMarkdown(from: view) == source)
    }

    @Test("pasting an image is one undoable edit")
    @MainActor
    func imagePasteCanBeUndone() throws {
        let source = "Before after"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: window.contentView!.bounds)
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = coordinator
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        coordinator.apply(markdown: source, to: view)
        let reference = MeetingNoteImages.Reference(id: UUID(), range: NSRange(location: 0, length: 0))
        coordinator.insertImageReference(reference, into: view, replacing: NSRange(location: 7, length: 0))
        #expect(coordinator.serializedMarkdown(from: view) == "Before \(reference.markdown)after")
        let undo = try #require(view.undoManager)
        undo.undo()
        #expect(coordinator.serializedMarkdown(from: view) == source)
        undo.redo()
        #expect(coordinator.serializedMarkdown(from: view) == "Before \(reference.markdown)after")
    }

    @Test("moving an image is undoable")
    @MainActor
    func imageMoveCanBeUndone() throws {
        let marker = "![Image](muesli-note-image:\(UUID().uuidString))"
        let source = "Before \(marker) after"
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: window.contentView!.bounds)
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = coordinator
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        coordinator.apply(markdown: source, to: view)
        let image = (view.string as NSString).range(of: "\u{fffc}")
        let undo = try #require(view.undoManager)
        undo.beginUndoGrouping()
        #expect(NoteImageMove.move(in: view, source: image, destination: 0))
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        undo.undo()
        #expect(coordinator.serializedMarkdown(from: view) == source)
        #expect(undo.canRedo)
        undo.redo()
        #expect(coordinator.serializedMarkdown(from: view) == "\(marker)Before  after")
    }

    @Test("meeting notes group markdown tables and preserve source line positions")
    func noteTableBlocks() {
        let markdown = "Heading\n| Model | Score |\n| --- | ---: |\n| **A** | 42 |\nAfter\n```\n| no | table |\n| --- | --- |\n```"
        let blocks = MeetingNotesView.blocks(markdown)
        #expect(blocks.count == 7)
        #expect(blocks[1].start == 1)
        #expect(blocks[1].count == 3)
        #expect(blocks[1].table == [["Model", "Score"], ["**A**", "42"]])
        #expect(blocks.dropFirst(2).allSatisfy { $0.table == nil })
    }

    @Test("copy and cut preserve inline images through saving and reopening", arguments: [false, true])
    @MainActor
    func clipboardImageRoundTrip(cut: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        var image = try MeetingNoteImages.save(bytes, supportDirectory: root)
        image.width = 320
        let fragment = "before \(image.markdown)\nafter"
        let source = "[\(fragment)]"
        let view = ClipboardNoteView()
        defer { view.board.releaseGlobally() }
        let coordinator = MarkdownRichTextEditor.Coordinator(text: .constant(source), command: .constant(nil), onTextChange: nil)
        view.delegate = coordinator
        coordinator.apply(markdown: source, to: view)
        view.setSelectedRange(NSRange(location: 1, length: (view.string as NSString).length - 2))
        if cut { view.cut(nil) } else { view.copy(nil) }
        let remaining = cut ? "[]" : source
        #expect(coordinator.serializedMarkdown(from: view) == remaining)
        try #require(view.board.string(forType: PlaceholderTextView.noteSelectionType) == fragment)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.paste(nil)

        let store = DictationStore(databaseURL: root.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        let id = try store.createLiveMeeting(title: "Clipboard test", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: coordinator.currentMarkdown)
        let saved = try #require(try DictationStore(databaseURL: store.resolvedDatabaseURL).meeting(id: id)?.manualNotes)
        #expect(saved == remaining + fragment)
        let reopened = NSTextView()
        let reader = MarkdownRichTextEditor.Coordinator(text: .constant(saved), command: .constant(nil), onTextChange: nil)
        reader.apply(markdown: saved, to: reopened)
        #expect(reader.serializedMarkdown(from: reopened) == saved)
        let storage = try #require(reopened.textStorage)
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            if value is NSTextAttachment { count += run.length }
        }
        #expect(count == (cut ? 1 : 2))
        #expect(try MeetingNoteImages.inputs(in: saved, supportDirectory: root).map(\.data) == [bytes])
    }

    @Test("reopening independently sized copies loads one shared image at both widths")
    @MainActor
    func reopenedCopiesHaveSavedWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 320,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        var image = try MeetingNoteImages.save(bytes, supportDirectory: root)
        let original = image.markdown
        image.width = 160
        let notes = original + "\n" + image.markdown
        let store = DictationStore(databaseURL: root.appendingPathComponent("meeting.db"))
        try store.migrateIfNeeded()
        let id = try store.createLiveMeeting(title: "Image widths", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: notes)
        let saved = try #require(try DictationStore(databaseURL: store.resolvedDatabaseURL).meeting(id: id)?.manualNotes)
        let reader = MarkdownRichTextEditor.Coordinator(text: .constant(saved), command: .constant(nil),
            onTextChange: nil, imageSupportDirectory: root)
        let view = NSTextView()
        reader.textView = view
        reader.apply(markdown: saved, to: view)
        let storage = try #require(view.textStorage)
        func attachment(at index: Int) -> NSTextAttachment? {
            storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while attachment(at: 0)?.bounds.width == 32 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(attachment(at: 0))
        let second = try #require(attachment(at: 2))
        #expect(first.bounds.size == NSSize(width: 500, height: 250))
        #expect(second.bounds.size == NSSize(width: 160, height: 80))
        #expect(first.image === second.image)
        #expect(reader.serializedMarkdown(from: view) == notes)
        #expect(try MeetingNoteImages.inputs(in: saved, supportDirectory: root).map(\.data) == [bytes])
    }

    @Test("note assets are validated, resolved, and exported with relative paths")
    @MainActor
    func imageStorageAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let reference = try MeetingNoteImages.save(data, supportDirectory: root)
        let markdown = "Before \(reference.markdown) after \(reference.markdown)"
        let inputs = try MeetingNoteImages.inputs(in: markdown, supportDirectory: root)
        #expect(inputs.count == 1)
        #expect(inputs[0].data == data)
        #expect(inputs[0].mediaType == "image/png")
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        let tiffReference = try MeetingNoteImages.save(tiff, supportDirectory: root)
        let compatible = try #require(MeetingNoteImages.inputs(in: tiffReference.markdown, supportDirectory: root).first)
        #expect(compatible.mediaType == "image/jpeg")
        #expect(compatible.data.count <= MeetingNoteImages.maximumSummaryImageBytes)
        #expect(try Data(contentsOf: MeetingNoteImages.url(for: tiffReference.id, supportDirectory: root)) == tiff)
        let resized = "![Image](muesli-note-image:\(reference.id.uuidString)?width=320)"
        #expect(MeetingNoteImages.references(in: resized).first?.width == 320)
        let destination = root.appendingPathComponent("A meeting.md")
        let exported = try MeetingNoteImages.exportMarkdown(markdown, to: destination, supportDirectory: root)
        #expect(exported.contains("A%20meeting-assets/\(reference.id.uuidString).png"))
        #expect(!exported.contains("muesli-note-image:"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A meeting-assets/\(reference.id.uuidString).png").path))
        let pdf = MeetingExporter.buildAttributedString(from: markdown, supportDirectory: root)
        var attachmentCount = 0
        pdf.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pdf.length)) { value, _, _ in
            if value is NSTextAttachment { attachmentCount += 1 }
        }
        #expect(attachmentCount == 2)
        try FileManager.default.removeItem(at: MeetingNoteImages.url(for: reference.id, supportDirectory: root))
        #expect(throws: ChatFileError.self) { try MeetingNoteImages.inputs(in: markdown, supportDirectory: root) }
        let missing = root.appendingPathComponent("Missing.md")
        let placeholder = try MeetingNoteImages.exportMarkdown(markdown, to: missing, supportDirectory: root)
        #expect(placeholder.contains("[Image unavailable on this device]"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Missing-assets").path))
    }

}
