import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeechSegment")
struct SpeechSegmentTests {

    @Test("stores start, end, text")
    func basicConstruction() {
        let segment = SpeechSegment(start: 1.5, end: 3.0, text: "Hello world")
        #expect(segment.start == 1.5)
        #expect(segment.end == 3.0)
        #expect(segment.text == "Hello world")
    }
}

@Suite("SpeechTranscriptionResult")
struct SpeechTranscriptionResultTests {

    @Test("stores text and segments")
    func basicConstruction() {
        let result = SpeechTranscriptionResult(
            text: "Full text",
            segments: [
                SpeechSegment(start: 0, end: 1, text: "Full"),
                SpeechSegment(start: 1, end: 2, text: "text"),
            ]
        )
        #expect(result.text == "Full text")
        #expect(result.segments.count == 2)
    }

    @Test("empty result")
    func emptyResult() {
        let result = SpeechTranscriptionResult(text: "", segments: [])
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }
}

@Suite("Qwen3 inference gate")
struct Qwen3InferenceGateTests {

    @Test("cancelled waiter is removed before next slot")
    func cancelledWaiterDoesNotConsumeSlot() async throws {
        let gate = Qwen3InferenceGate()
        try await gate.acquire()

        let cancelled = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        #expect(await gate.queuedWaiterCount() == 1)

        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queuedWaiterCount() == 0)

        let next = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        await gate.release()
        #expect(try await next.value)

        do {
            _ = try await cancelled.value
            Issue.record("Cancelled waiter unexpectedly acquired the inference slot")
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("Cancelled waiter failed with unexpected error: \(error)")
        }
    }
}

@Suite("TranscriptionCoordinator routing")
struct TranscriptionCoordinatorTests {

    @Test("coordinator initializes without crash")
    func initDoesNotCrash() {
        let _ = TranscriptionCoordinator()
    }

    @Test("backend routing covers all known backends")
    func allBackendsCovered() {
        let backends = Set(BackendOption.all.map(\.backend))
        #expect(backends == TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.union(["fluidaudio"]))
    }
}

@Suite("CohereTranscribeLanguage")
struct CohereTranscribeLanguageTests {

    @Test("english prompt ids match the current default prompt")
    func englishPromptIds() {
        #expect(
            CohereTranscribeLanguage.english.promptIds == [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13]
        )
    }

    @Test("german prompt ids swap in the german language token")
    func germanPromptIds() {
        #expect(
            CohereTranscribeLanguage.german.promptIds == [13764, 7, 4, 16, 76, 76, 5, 9, 11, 13]
        )
    }

    @Test("unset and unsupported codes fall back to english")
    func resolvedFallbacks() {
        #expect(CohereTranscribeLanguage.resolved(nil) == .english)
        #expect(CohereTranscribeLanguage.resolved("xx") == .english)
    }
}

@Suite("CohereTranscribeUtils")
struct CohereTranscribeUtilsTests {

    @Test("single transcript returns unchanged")
    func singleTranscript() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts(["Hello world"])
        #expect(result == "Hello world")
    }

    @Test("empty list returns empty string")
    func emptyList() {
        #expect(CohereTranscribeUtils.mergeOverlappingTranscripts([]) == "")
    }

    @Test("no overlap joins with space")
    func noOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The quick brown fox",
            "jumped over the lazy dog",
        ])
        #expect(result == "The quick brown fox jumped over the lazy dog")
    }

    @Test("exact trigram overlap deduplicates")
    func exactOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "I went to the store and bought some milk",
            "and bought some milk then came home",
        ])
        #expect(result == "I went to the store and bought some milk then came home")
    }

    @Test("case-insensitive trigram matching")
    func caseInsensitive() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The Model Works well",
            "the model works well on device",
        ])
        #expect(result == "The Model Works well on device")
    }

    @Test("cleanTranscript strips endoftext token")
    func stripsEndOfText() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello world<|endoftext|>garbage after")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript strips special tokens")
    func stripsSpecialTokens() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello<|nospeech|> world<|pnc|>")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript trims repeated suffix")
    func trimsRepeatedSuffix() {
        // Split on ". " produces: ["First", "Second", "Third", "Fourth", "Second", "more"]
        // Position 4 "Second" matches position 1 "Second", i-j=3 ≤ 3 → truncate at position 4
        let result = CohereTranscribeUtils.cleanTranscript(
            "First. Second. Third. Fourth. Second. more text"
        )
        #expect(result == "First. Second. Third. Fourth.")
    }

    @Test("cleanTranscript passes normal text unchanged")
    func normalTextUnchanged() {
        #expect(CohereTranscribeUtils.cleanTranscript("Normal transcription text.") == "Normal transcription text.")
    }
}

@Suite("TranscriptionEngineArtifactsFilter")
struct TranscriptionEngineArtifactsFilterTests {

    @Test("returns empty string for known artifact")
    func blankAudioArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[blank_audio]") == "")
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[BLANK_AUDIO]") == "")
    }

    @Test("trims surrounding whitespace before matching")
    func trailingWhitespace() {
        #expect(TranscriptionEngineArtifactsFilter.apply("  [blank_audio]  \n") == "")
    }

    @Test("passes through normal transcription unchanged")
    func normalTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello world") == "Hello world")
    }

    @Test("passes through empty string unchanged")
    func emptyTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("") == "")
    }

    @Test("does not strip artifact when it appears mid-sentence")
    func midSentenceNotStripped() {
        let text = "Hello [blank_audio] world"
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == text)
    }

    @Test("strips leaked prompt suffix from transcript")
    func stripsLeakedPromptSuffix() {
        let text = """
        I'm testing local dictation. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "I'm testing local dictation."
        )
    }

    @Test("strips leaked prompt prefix from transcript")
    func stripsLeakedPromptPrefix() {
        let text = "Transcribe the spoken audio accurately. Testing whether this works or not."
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "Testing whether this works or not."
        )
    }

    @Test("removes pure prompt leakage entirely")
    func removesPurePromptLeakage() {
        let text = """
        Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "")
    }
}

@Suite("Qwen3 post-processing output cleanup")
struct Qwen3PostProcessingOutputCleanerTests {

    @Test("removes think tags")
    func stripsThinkTags() {
        let raw = "<think>reasoning</think>Clean transcript"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "Clean transcript")
    }

    @Test("removes chat markup")
    func stripsChatMarkup() {
        let raw = "<|im_start|>assistant Hello world <|im_end|>"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "assistant Hello world")
    }

    @Test("removes leaked list-formatting instruction")
    func stripsLeakedPromptInstruction() {
        let raw = """
        If the speaker is dictating a list, such as saying "first point", "second point", or "bullet point", format each item on its own line.
        First point is ship it
        """
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "First point is ship it")
    }

    @Test("rejects assistant-style analysis output")
    func rejectsAssistantStyleAnalysisOutput() {
        let cleaned = """
        The user is asking about the system prompt.

        Analysis:
        This is a question.

        Action Plan:
        1. Answer the question.
        """
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects runaway output")
    func rejectsRunawayOutput() {
        let cleaned = String(repeating: "Remove the filler word like. ", count: 40)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects oversized cleanup output")
    func rejectsOversizedCleanupOutput() {
        let input = String(repeating: "Please ship this note. ", count: 10)
        let cleaned = String(repeating: "Please ship this note with unrelated additions. ", count: 12)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: input
        ))
    }

    @Test("rejects short-input hallucination expansion")
    func rejectsShortInputHallucinationExpansion() {
        let cleaned = String(repeating: "This unrelated response should not replace a short dictation. ", count: 3)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "um yeah"
        ))
    }

    @Test("rejects placeholder punctuation cleanup output")
    func rejectsPlaceholderPunctuationCleanupOutput() {
        for cleaned in ["...", ". . .", "---", "??"] {
            #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
                cleaned: cleaned,
                input: "Please send the update to Priyanka."
            ))
        }
    }

    @Test("accepts short legitimate cleanup output")
    func acceptsShortLegitimateCleanupOutput() {
        for cleaned in ["OK.", "Sure.", "No."] {
            #expect(!Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
                cleaned: cleaned,
                input: "okay sounds good"
            ))
        }
    }

    @Test("hosted cleanup sanitizer preserves dictated labels and quotes")
    func hostedCleanupSanitizerPreservesLabelsAndQuotes() {
        let raw = """
        Subject: "Muesli launch notes"

        Body: Ask Priyanka to review the "AI Models" settings copy.
        """

        let cleaned = TranscriptCleanupClient.cleanOutput(raw)

        #expect(cleaned.contains(#"Subject: "Muesli launch notes""#))
        #expect(cleaned.contains(#"Body: Ask Priyanka to review the "AI Models" settings copy."#))
        #expect(!Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: #"Subject quote Muesli launch notes body ask Priyanka to review the quote AI Models quote settings copy"#
        ))
    }
}
