import Testing
@testable import MuesliNativeApp

@Suite
struct CleanupFormattingTests {
    @Test func preservesListsAndParagraphs() {
        for text in [
            "- Latency\n- Formatting",
            "- Latency\n\n- Formatting",
            "- Latency\n  - Formatting\n    - Nested item",
            "1. Latency\n\n2. Formatting",
            "First paragraph.\n\nSecond paragraph.",
            "Heading\n\t- Tab-indented item"
        ] {
            #expect(Qwen3PostProcessorOutputCleaner.clean(text) == text)
            #expect(TranscriptCleanupClient.cleanOutput(text) == text)
            #expect(MuesliCleanupV2Prompt.guardedOutput(text, input: text) == text)
        }
    }

    @Test func normalizesInlineWhitespaceWithoutFlatteningLayout() {
        let raw = "First  paragraph .\r\n\r\n- One  item\r\n  - Nested  item  \r\n"
        #expect(TranscriptCleanupClient.cleanOutput(raw) == "First paragraph.\n\n- One item\n  - Nested item")
        #expect(TranscriptCleanupClient.cleanOutput("<think>Ignore this</think>\n- One\n\n- Two") == "- One\n\n- Two")
        #expect(TranscriptCleanupClient.cleanOutput("One\n\n\n\nTwo") == "One\n\nTwo")
    }
}
