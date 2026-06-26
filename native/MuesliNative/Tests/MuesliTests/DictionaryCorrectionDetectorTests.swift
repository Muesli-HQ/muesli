import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictionary correction detector")
struct DictionaryCorrectionDetectorTests {
    @Test("contract surfaces one-word and two-token-to-one-word corrections only")
    func contractSurfacesSupportedCorrectionShapesOnly() {
        let singleWordSuggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "for the dictionary test please write musley in this sentence today",
            editedText: "for the dictionary test please write muesli in this sentence today"
        )
        #expect(singleWordSuggestion?.observed == "musley")
        #expect(singleWordSuggestion?.replacement == "muesli")

        let splitWordSuggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "for the dictionary test please write Thoray Pakam in this sentence today",
            editedText: "for the dictionary test please write Thoraipakkam in this sentence today"
        )
        #expect(splitWordSuggestion?.observed == "Thoray Pakam")
        #expect(splitWordSuggestion?.replacement == "Thoraipakkam")

        let adjacentWordSuggestions = DictionaryCorrectionDetector.suggestions(
            originalText: "for the dictionary test please write Mandavali Dirvaniur in this sentence today",
            editedText: "for the dictionary test please write Mandaiveli Thiruvanmiyur in this sentence today",
            maxSuggestions: 3
        )
        #expect(adjacentWordSuggestions.map(\.observed) == ["Mandavali", "Dirvaniur"])
        #expect(adjacentWordSuggestions.map(\.replacement) == ["Mandaiveli", "Thiruvanmiyur"])
        #expect(adjacentWordSuggestions.allSatisfy { !$0.observed.contains(" ") && !$0.replacement.contains(" ") })

        let threeTokenSuggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "for the dictionary test please write Thoray I Pakam in this sentence today",
            editedText: "for the dictionary test please write Thoraipakkam in this sentence today"
        )
        #expect(threeTokenSuggestion == nil)
    }

    @Test("detects a corrected misspelling inside pasted text")
    func detectsCorrectedMisspelling() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "I love museli",
            baselineText: "I love museli",
            currentText: "I love muesli",
            appContext: "Notes|com.apple.Notes"
        )

        #expect(suggestion?.observed == "museli")
        #expect(suggestion?.replacement == "muesli")
        #expect(suggestion?.appContext == "Notes|com.apple.Notes")
    }

    @Test("detects less similar uncommon product-name corrections")
    func detectsLessSimilarProductNameCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "the word newsly is hard to transcribe",
            baselineText: "the word newsly is hard to transcribe",
            currentText: "the word muesli is hard to transcribe"
        )

        #expect(suggestion?.observed == "newsly")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects split ASR for a single proper noun")
    func detectsSplitASRForSingleProperNoun() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "often I try to say Alvar Pet in dictation",
            editedText: "often I try to say Alwarpet in dictation"
        )

        #expect(suggestion?.observed == "Alvar Pet")
        #expect(suggestion?.replacement == "Alwarpet")
    }

    @Test("does not suggest hyphenated phrase corrections")
    func skipsHyphenatedPhraseCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "please route this to sc domain",
            editedText: "please route this to sc-domain"
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest acronym phrase replacements")
    func skipsAcronymPhraseReplacement() {
        // Phrase-to-acronym learning is intentionally outside prompt scope.
        // `New York` initials are `ny`, so it is not an exact acronym correction
        // for `NYC`.
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "I moved to New York last year and I like it",
            editedText: "I moved to NYC last year and I like it"
        )

        #expect(suggestion == nil)
    }

    @Test("detects single-token acronym casing corrections")
    func detectsSingleTokenAcronymCasingCorrection() {
        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: "we use api and hsr routing today",
            editedText: "we use API and HSR routing today",
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["api", "hsr"])
        #expect(suggestions.map(\.replacement) == ["API", "HSR"])
    }

    @Test("does not accept prefix-only acronym corrections")
    func skipsPrefixOnlyAcronymCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "we discussed north american expansion today",
            editedText: "we discussed NASA expansion today"
        )

        #expect(suggestion == nil)
    }

    @Test("detects numeric shorthand corrections")
    func detectsNumericShorthandCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "we run kubernetes in production for backend services today",
            editedText: "we run k8s in production for backend services today"
        )

        #expect(suggestion?.observed == "kubernetes")
        #expect(suggestion?.replacement == "k8s")
    }

    @Test("detects muesli corrections from latest failure shape")
    func detectsMuesliCorrectionFromLatestFailureShape() {
        let original = "No, typically I think the word muzzle is the worst toughest one for it to transcribe because it usually transcribes to the one starting with the w letter N instead of just muzzli."
        let edited = "No, typically I think the word muesli is the worst toughest one for it to transcribe because it usually transcribes to the one starting with the w letter N instead of just muesli."

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "muzzle")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects muesli corrections from latest musley failure")
    func detectsMuesliCorrectionFromLatestMusleyFailure() {
        let original = "Okay, it is able to transcribe the word musley if I say it very explicitly and enunciate the words, but I think as such if I say musley fast it's not able to."
        let edited = "Okay, it is able to transcribe the word muesli if I say it very explicitly and enunciate the words, but I think as such if I say muesli fast it's not able to."

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "musley")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects muesli corrections from latest muwsly failure")
    func detectsMuesliCorrectionFromLatestMuwslyFailure() {
        let original = "See, I typically find the word muesli to be wrongly transcribed almost every time, so I'm just repeating muwsly twice."
        let edited = "See, I typically find the word muesli to be wrongly transcribed almost every time, so I'm just repeating muesli twice."

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "muwsly")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects multiple proper noun corrections from one edited snapshot")
    func detectsMultipleProperNounCorrectionsFromOneSnapshot() {
        let original = "Okay, testing the dictionary prompt once again. So let us see if it can transcribe Mailapur, Mandavali, Trivanmir, Teenagar, Alvarped."
        let edited = "Okay, testing the dictionary prompt once again. So let us see if it can transcribe Mylapore, Mandavali, Thiruvanmiyur, TNagar, Alwarpet."

        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: original,
            editedText: edited,
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["Mailapur", "Trivanmir", "Teenagar"])
        #expect(suggestions.map(\.replacement) == ["Mylapore", "Thiruvanmiyur", "TNagar"])
    }

    @Test("does not emit phrase suggestions when adjacent words are edited")
    func skipsPhraseSuggestionsForAdjacentWordEdits() {
        let original = "Chennai area names called Mylapore, Mandavali, Dirvaniur."
        let edited = "Chennai area names called Mylapore, Mandaiveli, Thiruvanmiyur."

        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: original,
            editedText: edited,
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["Mandavali", "Dirvaniur"])
        #expect(suggestions.map(\.replacement) == ["Mandaiveli", "Thiruvanmiyur"])
        #expect(suggestions.allSatisfy { !$0.observed.contains(" ") && !$0.replacement.contains(" ") })
    }

    @Test("detects multiple split ASR proper nouns from one edited snapshot")
    func detectsMultipleSplitASRProperNouns() {
        let original = "Okay, I am only interested in just like proper noun related corrections, so I don't want any phrasal related changes that is not part of my concern for the dictionary prompts. So let us check. can it transcribe Thoray Pakam, Kara Pakam, Nongam Bakam properly?"
        let edited = "Okay, I am only interested in just like proper noun related corrections, so I don't want any phrasal related changes that is not part of my concern for the dictionary prompts. So let us check. can it transcribe Thoraipakkam, Karapakkam, Nungambakkam properly?"

        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: original,
            editedText: edited,
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["Thoray Pakam", "Kara Pakam", "Nongam Bakam"])
        #expect(suggestions.map(\.replacement) == ["Thoraipakkam", "Karapakkam", "Nungambakkam"])
    }

    @Test("does not suggest three token collapse corrections")
    func skipsThreeTokenCollapseCorrections() {
        let original = "can it transcribe Thoray I Pakam properly in this sentence"
        let edited = "can it transcribe Thoraipakkam properly in this sentence"

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion == nil)
    }

    @Test("detects word correction when extra text is appended afterwards")
    func detectsCorrectionWithAdditionalTyping() {
        let original = "So this time if I say Newsly has not transcribed Newsly properly, would you be able to add it to dictionary immediately?"
        let edited = "So this time if I say muesli has not transcribed muesli properly, would you be able to add it to dictionary immediately? (still did not trigger the prompt unfortunately)"

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited,
            appContext: "Codex|com.openai.chat"
        )

        #expect(suggestion?.observed == "Newsly")
        #expect(suggestion?.replacement == "muesli")
        #expect(suggestion?.appContext == "Codex|com.openai.chat")
    }

    @Test("detects a correction inside a large focused text snapshot")
    func detectsCorrectionInsideLargeFocusedTextSnapshot() {
        let prefix = (0..<140).map { "prefix\($0)" }.joined(separator: " ")
        let suffix = (0..<140).map { "suffix\($0)" }.joined(separator: " ")
        let original = "\(prefix) I like museli today \(suffix)"
        let edited = "\(prefix) I like muesli today \(suffix)"

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "museli")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects far-apart corrections inside a large focused text snapshot")
    func detectsFarApartCorrectionsInsideLargeFocusedTextSnapshot() {
        let prefix = (0..<40).map { "prefix\($0)" }.joined(separator: " ")
        let middle = (0..<140).map { "middle\($0)" }.joined(separator: " ")
        let suffix = (0..<40).map { "suffix\($0)" }.joined(separator: " ")
        let original = "\(prefix) I like museli today \(middle) I mentioned newsly again \(suffix)"
        let edited = "\(prefix) I like muesli today \(middle) I mentioned muesli again \(suffix)"

        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: original,
            editedText: edited,
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["museli", "newsly"])
        #expect(suggestions.map(\.replacement) == ["muesli", "muesli"])
    }

    @Test("detects far-apart corrections across repeated separator text")
    func detectsFarApartCorrectionsAcrossRepeatedSeparatorText() {
        let middle = Array(repeating: "and then", count: 100).joined(separator: " ")
        let original = "I like museli today \(middle) I mentioned newsly again"
        let edited = "I like muesli today \(middle) I mentioned muesli again"

        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: original,
            editedText: edited,
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["museli", "newsly"])
        #expect(suggestions.map(\.replacement) == ["muesli", "muesli"])
    }

    @Test("detects repeated-separator corrections beyond the old token cap")
    func detectsRepeatedSeparatorCorrectionsBeyondOldTokenCap() {
        let middle = Array(repeating: "and then", count: 160).joined(separator: " ")
        let original = "I like museli today \(middle) I mentioned newsly again"
        let edited = "I like muesli today \(middle) I mentioned muesli again"

        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: original,
            editedText: edited,
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["museli", "newsly"])
        #expect(suggestions.map(\.replacement) == ["muesli", "muesli"])
    }

    @Test("detects a word correction next to an inserted word")
    func detectsCorrectionNextToInsertedWord() {
        let suggestions = DictionaryCorrectionDetector.suggestions(
            originalText: "I like museli today",
            editedText: "I like fresh muesli today",
            maxSuggestions: 3
        )

        #expect(suggestions.map(\.observed) == ["museli"])
        #expect(suggestions.map(\.replacement) == ["muesli"])
    }

    @Test("requires shared dictation context before diffing AX snapshots")
    func requiresSharedDictationContext() {
        #expect(DictionaryCorrectionDetector.hasSufficientSharedContext(
            originalText: "So this time if I say Newsly has not transcribed Newsly properly",
            editedText: "So this time if I say muesli has not transcribed muesli properly and then I kept typing"
        ))

        #expect(!DictionaryCorrectionDetector.hasSufficientSharedContext(
            originalText: "please look up spelling correction",
            editedText: "please look file_00000000f4ac61f4841155122554864c-sanitized spelling correction"
        ))

        #expect(!DictionaryCorrectionDetector.hasSufficientSharedContext(
            originalText: "hello muesli today",
            editedText: "unrelated editor content"
        ))

        #expect(DictionaryCorrectionDetector.hasSufficientSharedContext(
            originalText: "Alvar Pet",
            editedText: "Alwarpet"
        ))
    }

    @Test("keeps changed English words in recognition candidates")
    func keepsChangedEnglishWordsInRecognitionCandidates() {
        let filler = (0..<180).map { "a\($0)" }.joined(separator: " ")
        let original = "\(filler) internationalization"
        let edited = "\(filler) international"

        let candidates = DictionaryCorrectionDetector.requiredEnglishWordCandidates(
            originalText: original,
            editedText: edited
        )

        #expect(candidates.contains("internationalization"))
        #expect(candidates.contains("international"))
    }

    @Test("detects corrections from a final edited transcript snapshot")
    func detectsFinalEditedTranscriptSnapshot() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "Hey Musley, can you see if you're transcribing the word correctly?",
            editedText: "Hey Muesli, can you see if you're transcribing the word correctly?"
        )

        #expect(suggestion?.observed == "Musley")
        #expect(suggestion?.replacement == "Muesli")
    }

    @Test("detects capitalization corrections for names")
    func detectsCapitalizationCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "talk to pranav today",
            baselineText: "talk to pranav today",
            currentText: "talk to Pranav today"
        )

        #expect(suggestion?.observed == "pranav")
        #expect(suggestion?.replacement == "Pranav")
    }

    @Test("does not suggest common everyday typo corrections")
    func skipsCommonWords() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "ship teh update",
            baselineText: "ship teh update",
            currentText: "ship the update"
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest common word truncations")
    func skipsCommonWordTruncations() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "I usually use this prompt",
            baselineText: "I usually use this prompt",
            currentText: "I usual use this prompt",
            recognizedEnglishWords: ["usually", "usual"]
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest common word to generated artifact corrections")
    func skipsCommonWordToGeneratedArtifact() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "please look up spelling correction",
            editedText: "please look file_00000000f4ac61f4841155122554864c-sanitized spelling correction"
        )

        #expect(suggestion == nil)
    }

    @Test("does not let punctuation alone make unrelated words suggestions")
    func skipsUnrelatedHyphenatedReplacement() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "Please review the Vitruvian design note",
            editedText: "Please review the follow-up design note"
        )

        #expect(suggestion == nil)
    }

    @Test("does not let numeric shorthand signal alone replace unrelated words")
    func skipsUnrelatedNumericShorthandReplacement() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "Please review the Vitruvian design note",
            editedText: "Please review the k8s design note"
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest same-endpoint numeric shorthand with wrong omitted count")
    func skipsSameEndpointNumericShorthandWithWrongOmittedCount() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "Please review the validation design note today",
            editedText: "Please review the v2n design note today"
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest short same-endpoint numeric shorthand edits")
    func skipsShortSameEndpointNumericShorthand() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "Please review the token design note today",
            editedText: "Please review the t3n design note today"
        )

        #expect(suggestion == nil)
    }

    @Test("ignores edits outside the pasted dictation")
    func ignoresOutsideEdits() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "hello muesli",
            baselineText: "before hello muesli",
            currentText: "before hello muesli!"
        )

        #expect(suggestion == nil)
    }
}

@Suite("Dictionary correction snapshot stabilizer")
struct DictionaryCorrectionSnapshotStabilizerTests {
    @Test("waits for a quiet window before evaluating a changed snapshot")
    func waitsForQuietWindow() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = "I usually use this prompt"

        #expect(stabilizer.observe(snapshots: [snapshot], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(1.0), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(1.6), quietWindow: 1.5) == [snapshot])
    }

    @Test("resets the quiet window when the snapshot changes")
    func resetsQuietWindowOnChange() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 2_000)

        #expect(stabilizer.observe(snapshots: ["I usually"], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: ["I usual"], now: start.addingTimeInterval(1.0), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: ["I usual"], now: start.addingTimeInterval(2.4), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: ["I usual"], now: start.addingTimeInterval(2.6), quietWindow: 1.5) == ["I usual"])
    }

    @Test("does not evaluate the same stable snapshot repeatedly")
    func evaluatesStableSnapshotOnce() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 3_000)
        let snapshot = "muwsly"

        #expect(stabilizer.observe(snapshots: [snapshot], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(2.0), quietWindow: 1.5) == [snapshot])
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(3.0), quietWindow: 1.5).isEmpty)
    }

    @Test("evaluates later stable snapshots after an earlier snapshot was already evaluated")
    func evaluatesLaterStableSnapshotAfterEarlierCandidate() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 4_000)
        let earlier = "I changed punctuation only."
        let later = "I changed museli to muesli."

        #expect(stabilizer.observe(snapshots: [earlier], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [earlier], now: start.addingTimeInterval(1.6), quietWindow: 1.5) == [earlier])
        #expect(stabilizer.observe(snapshots: [earlier, later], now: start.addingTimeInterval(1.7), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [earlier, later], now: start.addingTimeInterval(3.3), quietWindow: 1.5) == [later])
    }
}

@Suite("Dictionary suggestion config")
struct DictionarySuggestionConfigTests {
    @Test("old configs decode with correction prompts disabled")
    func oldConfigDefaults() throws {
        let data = Data(#"{"custom_words":[]}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(!config.enableDictionaryCorrectionPrompts)
        #expect(config.dictionarySuggestions.isEmpty)
        #expect(config.dismissedDictionarySuggestionKeys.isEmpty)
    }

    @Test("suggestions decode despite missing or corrupt ids")
    func suggestionDecodeToleratesBadIDs() throws {
        let data = Data(
            #"""
            {
              "dictionary_suggestions": [
                {
                  "id": "not-a-uuid",
                  "observed": "museli",
                  "replacement": "muesli",
                  "app_context": "Codex|com.openai.codex",
                  "occurrence_count": 0,
                  "created_at": "2026-06-24T00:00:00Z",
                  "last_seen_at": "2026-06-24T00:00:01Z"
                },
                {
                  "observed": "mylapor",
                  "replacement": "Mylapore"
                }
              ]
            }
            """#.utf8
        )

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.dictionarySuggestions.count == 2)
        #expect(config.dictionarySuggestions[0].observed == "museli")
        #expect(config.dictionarySuggestions[0].replacement == "muesli")
        #expect(config.dictionarySuggestions[0].occurrenceCount == 1)
        #expect(config.dictionarySuggestions[1].observed == "mylapor")
        #expect(config.dictionarySuggestions[1].replacement == "Mylapore")
        #expect(config.dictionarySuggestions[1].appContext == "")
    }

    @Test("suggestion key is stable across whitespace and case")
    func stableSuggestionKey() {
        #expect(
            DictionarySuggestion.key(observed: " Museli ", replacement: "Muesli")
                == DictionarySuggestion.key(observed: "museli", replacement: " muesli ")
        )
    }

    @Test("suggestion app display name hides bundle identifier")
    func suggestionAppDisplayName() {
        let suggestion = DictionarySuggestion(
            observed: "museli",
            replacement: "muesli",
            appContext: "Codex|com.openai.codex"
        )

        #expect(suggestion.appDisplayName == "Codex")
    }
}
