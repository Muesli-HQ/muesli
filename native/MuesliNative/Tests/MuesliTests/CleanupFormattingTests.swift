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

    @Test func finalArtifactPassPreservesFormattedCleanupExactly() {
        let text = "  Heading\r\n\r\n- First  column\r\n  - Nested item\r\n\t- Tab-indented item\r\n\r\n    code    alignment\r\n"
        #expect(TranscriptionEngineArtifactsFilter.applyPreservingLayout(text) == text)
    }

    @Test func finalArtifactPassRemovesCuesWithoutFlatteningSurroundingLayout() {
        let text = "Heading\n\n- First *crickets* item\n  - [cheers] Nested  item\n\t- Tab item <|nospeech|>\n\nLast [applause], sentence."
        let expected = "Heading\n\n- First item\n  - Nested  item\n\t- Tab item\n\nLast, sentence."
        #expect(TranscriptionEngineArtifactsFilter.applyPreservingLayout(text) == expected)
        #expect(TranscriptionEngineArtifactsFilter.applyPreservingLayout("  [cheers] Nested\n\t[applause] Item") == "  Nested\n\tItem")
        #expect(TranscriptionEngineArtifactsFilter.applyPreservingLayout("Hello\n[cheers]\n\nWorld") == "Hello\n\n\nWorld")
        #expect(TranscriptionEngineArtifactsFilter.applyPreservingLayout("> quoted speech [music]") == "> quoted speech")
        #expect(TranscriptionEngineArtifactsFilter.applyPreservingLayout("[cheers]\n*crickets*") == "")
        let segments = TranscriptionEngineArtifactsFilter.apply(to: [
            .init(start: 0, end: 1, text: text),
            .init(start: 1, end: 2, text: "[cheers]\n*crickets*")
        ], preservingLayout: true)
        #expect(segments.count == 1)
        #expect(segments.first?.text == expected)
        #expect(segments.first?.start == 0)
        #expect(segments.first?.end == 1)
    }

    @Test func finalDictationPreservesCustomWordMultilineExpansion() async {
        let replacement = "First paragraph.\n\n- First item\n  - Nested item\n\t- Tab-indented item\n\nLast paragraph. *crickets*"
        let result = await TranscriptionCoordinator().finalizeDictationTranscript(
            .init(text: "shortcut", segments: []), backend: .whisperLargeTurbo,
            customWords: [["word": "shortcut", "replacement": replacement, "matchingThreshold": 1.0]]
        )
        #expect(result.text == "First paragraph.\n\n- First item\n  - Nested item\n\t- Tab-indented item\n\nLast paragraph.")
    }
}
