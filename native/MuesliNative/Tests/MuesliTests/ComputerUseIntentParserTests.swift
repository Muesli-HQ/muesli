import Testing
@testable import MuesliNativeApp

@Suite("Computer Use intent parser")
struct ComputerUseIntentParserTests {
    @Test("parses open app commands")
    func parsesOpenApp() {
        let parsed = ComputerUseIntentParser.parse("Muesli, open the Slack app")

        #expect(parsed?.intent == .openApp(name: "slack"))
        #expect(parsed?.requiresConfirmation == false)
    }

    @Test("parses focus app commands")
    func parsesFocusApp() {
        let parsed = ComputerUseIntentParser.parse("please switch to Google Chrome")

        #expect(parsed?.intent == .focusApp(name: "google chrome"))
    }

    @Test("parses click commands and removes common element suffixes")
    func parsesClickLabel() {
        let parsed = ComputerUseIntentParser.parse("click the continue button")

        #expect(parsed?.intent == .click(label: "continue"))
        #expect(parsed?.requiresConfirmation == false)
    }

    @Test("parses computer use invocation prefix")
    func parsesComputerUsePrefix() {
        let parsed = ComputerUseIntentParser.parse("computer use click the continue button")

        #expect(parsed?.intent == .click(label: "continue"))
    }

    @Test("marks risky click targets for confirmation")
    func marksRiskyClicks() {
        let parsed = ComputerUseIntentParser.parse("click Send")

        #expect(parsed?.intent == .click(label: "send"))
        #expect(parsed?.requiresConfirmation == true)
    }

    @Test("parses type text commands")
    func parsesTypeText() {
        let parsed = ComputerUseIntentParser.parse("type hello world")

        #expect(parsed?.intent == .typeText("hello world"))
    }

    @Test("parses paste text commands and strips filler")
    func parsesPasteText() {
        let parsed = ComputerUseIntentParser.parse("paste the text quarterly update")

        #expect(parsed?.intent == .pasteText("quarterly update"))
    }

    @Test("parses scroll direction with default page count")
    func parsesScrollDefaultPages() {
        let parsed = ComputerUseIntentParser.parse("scroll down")

        #expect(parsed?.intent == .scroll(direction: .down, pages: 1))
    }

    @Test("parses scroll page count")
    func parsesScrollPageCount() {
        let parsed = ComputerUseIntentParser.parse("scroll down two pages")

        #expect(parsed?.intent == .scroll(direction: .down, pages: 2))
    }

    @Test("parses simple key press")
    func parsesSimpleKeyPress() {
        let parsed = ComputerUseIntentParser.parse("press escape")

        #expect(parsed?.intent == .pressKey(ComputerUseKeyCommand(modifiers: [], key: "escape")))
        #expect(parsed?.requiresConfirmation == false)
    }

    @Test("parses modified key press")
    func parsesModifiedKeyPress() {
        let parsed = ComputerUseIntentParser.parse("press command shift p")

        #expect(parsed?.intent == .pressKey(ComputerUseKeyCommand(modifiers: [.command, .shift], key: "p")))
    }

    @Test("marks close and quit hotkeys for confirmation")
    func marksRiskyHotkeys() {
        let close = ComputerUseIntentParser.parse("press command w")
        let quit = ComputerUseIntentParser.parse("press command q")

        #expect(close?.requiresConfirmation == true)
        #expect(quit?.requiresConfirmation == true)
    }

    @Test("returns nil for unsupported commands")
    func returnsNilForUnsupportedCommands() {
        let parsed = ComputerUseIntentParser.parse("what is on my screen")

        #expect(parsed == nil)
    }

    @Test("returns nil for empty or prefix-only commands")
    func returnsNilForEmptyCommands() {
        #expect(ComputerUseIntentParser.parse("") == nil)
        #expect(ComputerUseIntentParser.parse("hey muesli") == nil)
    }
}
