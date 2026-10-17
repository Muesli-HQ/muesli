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
}
