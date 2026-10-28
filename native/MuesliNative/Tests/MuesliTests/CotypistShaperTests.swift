import Testing
@testable import MuesliNativeApp

@Suite("Cotypist suggestion shaping")
struct CotypistShaperTests {
    private func completion(_ tokens: [(String, Double)], stop: CotypistCompletion.Stop = .limit) -> CotypistCompletion {
        CotypistCompletion(tokens: tokens.map { CotypistToken(text: $0.0, logprob: $0.1) }, stop: stop,
                           promptMs: 0, decodeMs: 0, reusedTokens: 0)
    }

    @Test("after a space, drops the leading space and keeps complete words")
    func afterSpace() throws {
        let raw = completion([(" file", -1.0), (" to", -0.5), (" you", -0.4), (" in", -0.3), (" a", -0.2), (" few", -0.2), (" mi", -0.1), ("nutes", -0.1), (".", -0.1), (" Thanks", -0.5)])
        let shaped = try CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false).get()
        #expect(shaped.text == "file to you in a few")
        #expect(shaped.firstWordLogProb == -1.0)
    }

    @Test("suggestion length and frequency settings set the word limit and the gate")
    func settings() throws {
        let raw = completion([(" file", -2.5), (" to", -0.5), (" you", -0.4), (" in", -0.3), (" a", -0.2)])
        let phrase = CotypistShaper.Thresholds(firstWord: CotypistModel.gemma4E2B.firstWordGate(.more, midWord: false),
                                               maxWords: CotypistSuggestionLength.phrase.maxWords)
        #expect(try CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false, thresholds: phrase).get().text == "file to you")
        let balanced = CotypistShaper.Thresholds(firstWord: CotypistModel.gemma4E2B.firstWordGate(.balanced, midWord: false))
        #expect(CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false, thresholds: balanced) == .failure(.lowConfidence(-2.5)))
        // Completing a half-typed word allows a looser gate than starting a new one; Fewer is stricter than More.
        for model in CotypistModel.allCases {
            #expect(model.firstWordGate(.balanced, midWord: true) <= model.firstWordGate(.balanced, midWord: false))
            #expect(model.firstWordGate(.fewer, midWord: false) > model.firstWordGate(.more, midWord: false))
        }
    }

    @Test("every model has a pinned, hashed download with its weights first; one is recommended and the default")
    func modelCatalog() throws {
        for model in CotypistModel.allCases {
            let release = try #require(model.release, "\(model.label) has no download")
            #expect(release.revision == model.revision && release.revision.count == 40)
            #expect(release.modelFilename == "model.safetensors")
            #expect(release.files.allSatisfy { $0.sha256?.count == 64 && ($0.expectedByteCount ?? 0) > 0 })
            #expect(model.directory.path.hasSuffix("/" + model.revision))
        }
        #expect(CotypistModel.allCases.filter(\.isRecommended) == [CotypistModel.defaultModel])
    }

    @Test("never shows a first word the token budget cut off")
    func truncatedFirstWord() {
        // One long word filling the whole budget: stage 1 asks for stage 2, which must not show it either.
        let raw = completion((0..<10).map { ($0 == 0 ? " anti" : "dis", -0.1) })
        #expect(CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false) == .failure(.empty))
    }

    @Test("rejects a first word below the gate")
    func gate() {
        let raw = completion([(" payment", -3.5), (" now", -0.5)])
        #expect(CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false) == .failure(.lowConfidence(-3.5)))
    }

    @Test("after a space, refuses to continue the previous word")
    func continuesPreviousWord() {
        let raw = completion([("ing", -0.2), (" now", -0.5)])
        #expect(CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false) == .failure(.continuesPreviousWord))
    }

    @Test("stops at a sentence end the model chose")
    func sentenceEnd() throws {
        let raw = completion([(" questions", -1.6), (".", -0.2)], stop: .endOfText)
        let shaped = try CotypistShaper.shape(raw, afterSpace: true, heal: nil, maxTokens: 10, firstWordOnly: false).get()
        #expect(shaped.text == "questions.")
    }

    @Test("first-word stage shows only a word known to be complete")
    func firstWordOnly() throws {
        let complete = completion([(" help", -2.0), (" me", -0.2), (" with", -0.4), (" this", -0.5)])
        #expect(try CotypistShaper.shape(complete, afterSpace: true, heal: nil, maxTokens: 4, firstWordOnly: true).get().text == "help")
        let cut = completion([(" rec", -1.0), ("eiv", -0.1), ("ab", -0.1), ("le", -0.1)])
        #expect(CotypistShaper.shape(cut, afterSpace: true, heal: nil, maxTokens: 4, firstWordOnly: true) == .failure(.firstWordIncomplete))
    }

    @Test("healing shows the rest of the typed word and ignores forced tokens in the gate")
    func healing() throws {
        // " recei" was typed; " rece" + "i" were forced, "ve" and the rest were the model's choice.
        let raw = completion([(" rece", -6.0), ("i", -4.0), ("ve", -0.3), (" the", -0.4), (" file", -0.9), (".", -0.2)], stop: .endOfText)
        let shaped = try CotypistShaper.shape(raw, afterSpace: false, heal: " recei", maxTokens: 10, firstWordOnly: false).get()
        #expect(shaped.text == "ve the file.")
        #expect(shaped.firstWordLogProb == -0.3)
    }

    @Test("healing a fully typed word suggests the following words")
    func healingCompleteWord() throws {
        let raw = completion([(" screen", -5.0), (" works", -1.2), ("?", -0.3)], stop: .endOfText)
        let shaped = try CotypistShaper.shape(raw, afterSpace: false, heal: " screen", maxTokens: 10, firstWordOnly: false).get()
        #expect(shaped.text == " works?")
    }

    @Test("finds Claude Code's prompt box and the conversation above it")
    func agentPrompt() {
        let rule = String(repeating: "─", count: 40)
        let screen = ["⏺ Built the engine.", "", rule, "❯ check the CI and updated PR    ", "  reviews for the  ", rule, "  status line"].joined(separator: "\n")
        #expect(CotypistAgentPrompt.context(screen: screen) == "⏺ Built the engine.\n\ncheck the CI and updated PR    reviews for the ")
        #expect(CotypistAgentPrompt.context(screen: "$ ls\n❯ not a box") == nil)
    }

    @Test("splits the half-typed word after a space, at a line start, or at the start of the text")
    @MainActor
    func partialWord() {
        #expect(CotypistService.splitPartialWord("Thanks for the quic")! == ("Thanks for the", " quic"))
        #expect(CotypistService.splitPartialWord("Hi team,\nWe")! == ("Hi team,\n", "We"))
        #expect(CotypistService.splitPartialWord("Thou")! == ("", "Thou"))
        #expect(CotypistService.splitPartialWord("the q") == nil)
        #expect(CotypistService.splitPartialWord("the ") == nil)
    }

    @Test("screen OCR keeps sentence-like lines nearest the bottom, as flowing text")
    @MainActor
    func screenText() {
        let ocr = "File\nEdit\nThe quarterly numbers look right\nSend\nThanks, I will forward them to legal today\nOK"
        #expect(CotypistService.promptReadyScreenText(ocr) == "The quarterly numbers look right Thanks, I will forward them to legal today")
        #expect(CotypistService.promptReadyScreenText(ocr, maxCharacters: 50) == "Thanks, I will forward them to legal today")
    }
}
