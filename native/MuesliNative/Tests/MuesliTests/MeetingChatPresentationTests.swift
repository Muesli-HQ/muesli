import Foundation
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
        #expect(short == 34)
        #expect(multiline > short)
        #expect(long == 144)
    }

    @Test func citationReferencesKeepVisibleBrackets() {
        let rendered = MeetingChatView.attributedAnswer("Ship Friday [[S1]]", citations: [source])
        #expect(String(rendered.characters) == "Ship Friday [1]")
        #expect(rendered.runs.compactMap(\.link).count == 1)
    }
}
