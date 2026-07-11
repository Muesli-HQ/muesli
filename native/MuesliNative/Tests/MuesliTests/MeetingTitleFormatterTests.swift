import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting title formats")
struct MeetingTitleFormatterTests {
    @Test("default format preserves the generated title")
    func defaultFormat() {
        let formatted = MeetingTitleFormatter.format(
            pattern: MeetingTitleFormatter.defaultPattern,
            generatedTitle: "Sprint planning",
            startTime: Date(timeIntervalSince1970: 0),
            context: .empty
        )

        #expect(formatted == "Sprint planning")
    }

    @Test("default format preserves title punctuation")
    func defaultFormatPreservesTitlePunctuation() {
        let formatted = MeetingTitleFormatter.format(
            pattern: MeetingTitleFormatter.defaultPattern,
            generatedTitle: "Weekly Sync:",
            startTime: Date(timeIntervalSince1970: 0),
            context: .empty
        )

        #expect(formatted == "Weekly Sync:")
    }

    @Test("format supports context tokens and literal project text")
    func contextAndLiteralTokens() {
        let formatted = MeetingTitleFormatter.format(
            pattern: "Muesli · {app} · {window}",
            generatedTitle: "Ignored generated title",
            startTime: Date(timeIntervalSince1970: 0),
            context: MeetingTitleContext(appName: "Chrome", windowTitle: "Weekly sync - Google Meet")
        )

        #expect(formatted == "Muesli · Chrome · Weekly sync - Google Meet")
    }

    @Test("format supports date and time tokens")
    func dateAndTimeTokens() {
        let formatted = MeetingTitleFormatter.format(
            pattern: "{date} {time}",
            generatedTitle: "Ignored generated title",
            startTime: Date(timeIntervalSince1970: 0),
            context: .empty
        )

        #expect(formatted.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil)
    }

    @Test("missing context falls back to the generated title")
    func missingContextFallsBack() {
        let formatted = MeetingTitleFormatter.format(
            pattern: "{window}",
            generatedTitle: "Meeting",
            startTime: Date(timeIntervalSince1970: 0),
            context: .empty
        )

        #expect(formatted == "Meeting")
    }

    @Test("missing context removes only its adjacent separator")
    func missingContextRemovesAdjacentSeparator() {
        let formatted = MeetingTitleFormatter.format(
            pattern: "{title} · {window}",
            generatedTitle: "Weekly Sync",
            startTime: Date(timeIntervalSince1970: 0),
            context: .empty
        )

        #expect(formatted == "Weekly Sync")
    }
}
