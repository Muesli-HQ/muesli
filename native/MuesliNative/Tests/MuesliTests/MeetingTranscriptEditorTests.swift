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
}
