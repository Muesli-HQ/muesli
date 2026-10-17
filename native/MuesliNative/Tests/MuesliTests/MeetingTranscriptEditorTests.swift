import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Meeting transcript editor")
@MainActor
struct MeetingTranscriptEditorTests {
    @Test func copiesSelectedSpeakerTextWithoutEditorBoundary() {
        let editor = MeetingTranscriptEditor.Editor(frame: .zero)
        editor.string = "[00:00:01] Team: Example\u{2063}: Ship Friday."
        let source = editor.string as NSString
        editor.setSelectedRange(NSRange(location: 11, length: source.length - 11))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MeetingTranscriptEditorTests.\(UUID().uuidString)"))
        pasteboard.clearContents()

        #expect(editor.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "Team: Example: Ship Friday.")
    }

    @Test func pastesCopiedSpeakerRowsWithTheirSavedBoundary() {
        let internalType = NSPasteboard.PasteboardType("com.muesli.meeting-transcript-editor-selection")
        let source = "[00:00:01] Team: Example\u{2063}: Ship Friday."
        let editor = MeetingTranscriptEditor.Editor(frame: .zero)
        editor.string = source
        editor.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MeetingTranscriptEditorTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(editor.writeSelection(to: pasteboard, types: [.string, internalType]))
        #expect(pasteboard.string(forType: .string) == "[00:00:01] Team: Example: Ship Friday.")
        #expect(pasteboard.string(forType: internalType) == source)

        let pasted = MeetingTranscriptEditor.Editor(frame: .zero)
        pasted.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(pasted.readSelection(from: pasteboard, type: internalType))
        #expect(pasted.string == source)
    }

    @Test func pastesPartialSpeakerRowsAsPlainTextWithoutTheirBoundaryMarker() {
        let internalType = NSPasteboard.PasteboardType("com.muesli.meeting-transcript-editor-selection")
        let source = "[00:00:01] Team: Example\u{2063}: Ship Friday."
        let editor = MeetingTranscriptEditor.Editor(frame: .zero)
        editor.string = source
        let sourceText = source as NSString
        let selection = sourceText.range(of: "Example\u{2063}: Ship Friday.")
        #expect(selection.location != NSNotFound)
        guard selection.location != NSNotFound else { return }
        editor.setSelectedRange(selection)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MeetingTranscriptEditorTests.partial.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(editor.writeSelection(to: pasteboard, type: .string))
        #expect(!editor.writeSelection(to: pasteboard, type: internalType))
        #expect(pasteboard.string(forType: .string) == "Example: Ship Friday.")
        #expect(pasteboard.string(forType: internalType) == nil)
    }
}
