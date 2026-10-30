import Foundation
import AppKit
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat presentation")
struct MeetingChatPresentationTests {
    private let source = MeetingChatCitation(
        sourceKey: "S1", meetingID: 1, title: "Planning", startDate: .distantPast,
        kind: .transcript, excerpt: "Ship Friday", range: .init(location: 0, length: 11), revision: "r1"
    )

    @Test func inlineCitationsRemainInteractiveWithoutAllowingModelLinks() {
        let rendered = MeetingChatView.attributedAnswer(
            "**Ship Friday** [[S1]] [external](https://example.com) [forged](muesli-citation:///S2)",
            citations: [source]
        )
        let links = rendered.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(links.first?.absoluteString == "muesli-citation:///S1")
        #expect(String(rendered.characters).contains("Ship Friday"))
    }

    @Test func answerWhitespaceAndLiteralBlockMarkersSurviveInlineParsing() {
        let rendered = MeetingChatView.attributedAnswer("First line\n\nSecond line\n- literal", citations: [])
        #expect(String(rendered.characters) == "First line\n\nSecond line\n- literal")
    }
    @Test func tablesPreserveCitationsEscapedPipesAndCodeSpans() {
        let parsed = MeetingChatMarkdownBlock.parse("""
        | Meeting | Decision |
        | :--- | ---: |
        | Planning | A \\| B [[S1]] |
        | Follow-up | `A|B` |
        """)
        #expect(parsed == [.table([["Meeting", "Decision"], ["Planning", "A | B [[S1]]"], ["Follow-up", "`A|B`"]])])
    }

    @Test func fencedCodeNeverBecomesATableAndIncompleteTablesRemainText() {
        let parsed = MeetingChatMarkdownBlock.parse("```text\nA | B\n--- | ---\n```\nA | B\nnot a divider")
        #expect(parsed == [.code("A | B\n--- | ---"), .line("A | B"), .line("not a divider")])
    }
    @Test func meetingMentionsUseCaretAndUnicodeSafeRanges() throws {
        let text = "Compare 🗓️ @revamp with last week"
        let location = ("Compare 🗓️ @revamp" as NSString).length
        let mention = try #require(MeetingChatMentionQuery.find(in: text, selection: NSRange(location: location, length: 0)))
        #expect(mention.query == "revamp")
        #expect(mention.removing(from: text) == "Compare 🗓️  with last week")
    }

    @Test func emailsSelectionsAndNewlinesDoNotTriggerMeetingAutocomplete() {
        for text in ["person@example.com", "@revamp\nNext question"] {
            #expect(MeetingChatMentionQuery.find(in: text, selection: NSRange(location: (text as NSString).length, length: 0)) == nil)
        }
        #expect(MeetingChatMentionQuery.find(in: "@revamp", selection: NSRange(location: 0, length: 7)) == nil)
        #expect(MeetingChatMentionQuery.find(in: "@", selection: NSRange(location: 1, length: 0))?.query == "")
    }

    @Test func staleMentionCannotDeleteChangedDraft() throws {
        let mention = try #require(MeetingChatMentionQuery.find(in: "@revamp", selection: NSRange(location: 7, length: 0)))
        #expect(mention.removing(from: "@review") == "@review")
    }
    @Test func waitingCopyNeverReplacesRealToolOrValidationPhases() {
        for phase in ["Finding meeting context", "Searching meetings", "Reading meeting", "Checking sources", "Retrying answer format"] {
            #expect(MeetingChatWaitingStatus.label(phase: phase, elapsed: 30) == phase)
        }
    }

    @Test func providerWaitingCopyCyclesWithoutInventingToolProgress() {
        let phrases = ["Thinking", "Preparing your answer"]
        #expect(MeetingChatWaitingStatus.label(phase: "Writing answer", elapsed: 0, phrases: phrases) == "Thinking…")
        #expect(MeetingChatWaitingStatus.label(phase: "Writing answer", elapsed: 5, phrases: phrases) == "Preparing your answer…")
        #expect(MeetingChatWaitingStatus.label(phase: "Writing answer", elapsed: 10, phrases: phrases) == "Thinking…")
    }
    @Test func composerGrowsWithContentButKeepsLongDraftsBounded() {
        let short = MeetingChatComposerLayout.height(for: "Hello", width: 500)
        let multiline = MeetingChatComposerLayout.height(for: "First line\nSecond line\nThird line", width: 500)
        let long = MeetingChatComposerLayout.height(for: String(repeating: "Long question about meetings. ", count: 100), width: 300)
        // Keep a compact single line while accommodating the bundled font's metrics.
        #expect(short >= 34 && short <= 40)
        let label = NSTextField(labelWithString: "Hello")
        label.font = AppFonts.regular(14)
        #expect(short >= label.intrinsicContentSize.height + 16)
        #expect(multiline > short)
        #expect(long == 144)
    }

    @Test func citationReferencesKeepVisibleBrackets() {
        let rendered = MeetingChatView.attributedAnswer("Ship Friday [[S1]]", citations: [source])
        #expect(String(rendered.characters) == "Ship Friday [1]")
        #expect(rendered.runs.compactMap(\.link).count == 1)
    }
    @Test(arguments: [false, true])
    func presetAndRestoredDraftsKeepAdaptiveTextColor(resetUndo: Bool) throws {
        let editor = MeetingChatUndoTestEditor()
        editor.isRichText = false
        editor.typingAttributes = [.foregroundColor: NSColor.black]
        MeetingChatComposerTextSync.apply("List my next steps", to: editor, resetUndo: resetUndo)
        let color = try #require(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(color == .labelColor)
        #expect(editor.typingAttributes[.foregroundColor] as? NSColor == .labelColor)
        #expect(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == AppFonts.font(size: 14))
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let resolved = color.usingColorSpace(.deviceRGB)!
                #expect(name == .darkAqua ? resolved.redComponent > 0.8 : resolved.redComponent < 0.2)
            }
        }
    }

    @Test func mentionEditsPreserveTypingUndoAndRedo() throws {
        let editor = MeetingChatUndoTestEditor()
        editor.isRichText = false
        editor.allowsUndo = true
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("Question ", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        MeetingChatComposerTextSync.apply("Question @meeting", to: editor, resetUndo: false)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        MeetingChatComposerTextSync.apply("Question ", to: editor, resetUndo: false)
        undo.endUndoGrouping()
        undo.undo()
        #expect(editor.string == "Question @meeting")
        undo.undo()
        #expect(editor.string == "Question ")
        undo.undo()
        #expect(editor.string.isEmpty)
        undo.redo(); undo.redo(); undo.redo()
        #expect(editor.string == "Question ")
    }

    @Test func chatSwitchAndSubmissionClearUndoEvenForIdenticalDrafts() throws {
        let editor = MeetingChatUndoTestEditor()
        editor.isRichText = false
        editor.allowsUndo = true
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        for replacement in ["Same draft", ""] {
            editor.string = ""
            undo.beginUndoGrouping()
            editor.insertText("Same draft", replacementRange: NSRange(location: 0, length: 0))
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
            #expect(undo.canUndo)
            MeetingChatComposerTextSync.apply(replacement, to: editor, resetUndo: true)
            #expect(editor.string == replacement)
            #expect(!undo.canUndo)
            #expect(!undo.canRedo)
        }
    }
}


@MainActor
private final class MeetingChatUndoTestEditor: NSTextView {
    private let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}
