import Testing
@testable import MuesliNativeApp

@Suite("Whisper preview presentation")
struct WhisperPreviewPresentationTests {
    @Test("consecutive lexical agreement ignores timestamp drift and bounds fresh draft")
    func lexicalAgreement() {
        var presentation = WhisperPreviewPresentation()
        let first = words(["one", "two", "three", "four", "five", "six"])
        #expect(show(&presentation, first) == "one two")
        let next = words(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"], shift: 20)
        #expect(show(&presentation, next) == "one two three four five six seven eight")
    }

    @Test("a single bounded draft word appears on its first observation")
    func smallGroups() {
        var presentation = WhisperPreviewPresentation()
        #expect(show(&presentation, words(["one"])) == "one")
        #expect(show(&presentation, words(["one", "two"])) == "one two")
        let three = words(["one", "two", "three"])
        #expect(show(&presentation, three) == "one two three")
        #expect(show(&presentation, words(["one", "two", "three", "four", "five"])) == "one two three four five")
    }

    @Test("continued speech presents each new word without extra decode cycles or sentence resets")
    func longSpeakingSequence() {
        var presentation = WhisperPreviewPresentation()
        let sequence = (1...120).map { "word\($0)" }
        var previous = ""
        for count in 1...sequence.count {
            let prefix = Array(sequence.prefix(count))
            let current = show(&presentation, words(prefix))
            #expect(current == prefix.joined(separator: " "))
            #expect(current.utf16.starts(with: previous.utf16))
            #expect(current.count - previous.count <= 8)
            previous = current
        }
    }

    @Test("matching displayed prefix resumes bounded additions after a rejected large revision")
    func continuationAfterRejectedRevision() {
        var presentation = WhisperPreviewPresentation()
        let original = ["these", "are", "the", "already", "displayed", "words"]
        _ = show(&presentation, words(original))
        let visible = show(&presentation, words(original))
        #expect(show(&presentation, words(["a", "conflicting", "sentence", "should", "wait"])) == visible)
        let continuation = original + ["now", "continue", "with", "more", "speech"]
        let resumed = show(&presentation, words(continuation))
        #expect(resumed == (original + ["now", "continue"]).joined(separator: " "))
        #expect(resumed.utf16.starts(with: visible.utf16))
        #expect(resumed.count - visible.count <= 24)
    }

    @Test("returning to visible text does not bypass the draft grapheme limit")
    func recoveredContinuationIsBounded() {
        var presentation = WhisperPreviewPresentation()
        let original = ["these", "are", "the", "already", "displayed", "words"]
        _ = show(&presentation, words(original))
        let visible = show(&presentation, words(original))
        #expect(show(&presentation, words(["a", "conflicting", "sentence"])) == visible)
        let family = "👨‍👩‍👧‍👦"
        let longWord = String(repeating: family, count: 30)
        let resumed = show(&presentation, words(original + [longWord, "later"]))
        #expect(resumed == visible + " " + String(repeating: family, count: 23))
        #expect(resumed.count - visible.count == 24)
    }

    @Test("an unconfirmed large revision cannot replace the sentence prefix to reveal its tail")
    func largeRevisionCannotAppendAcrossConflict() {
        var presentation = WhisperPreviewPresentation()
        let original = ["these", "are", "the", "already", "displayed", "words"]
        _ = show(&presentation, words(original))
        let visible = show(&presentation, words(original))
        #expect(show(&presentation, words(["a", "different", "sentence", "and", "new", "tail"])) == visible)
        #expect(show(&presentation, words(["another", "changed", "sentence", "and", "more", "tail"])) == visible)
    }

    @Test("raw commitment transfers do not retract or duplicate displayed words")
    func commitmentTransfer() {
        var presentation = WhisperPreviewPresentation()
        let first = words(["one", "two", "three", "four"])
        _ = show(&presentation, first)
        #expect(show(&presentation, first) == "one two three four")
        let tail = words(["three", "four"])
        #expect(presentation.present(committedText: "one two", tail: " three four", words: tail, final: false) == " three four")
        #expect(presentation.present(committedText: "one two three four", tail: "", words: [], final: false) == "")
    }

    @Test("a large speculative correction waits for agreement then appears")
    func largeCorrection() {
        var presentation = WhisperPreviewPresentation()
        let old = words(["these", "are", "the", "older", "speculative", "words"])
        _ = show(&presentation, old)
        let visible = show(&presentation, old)
        let corrected = words(["a", "different", "sentence", "with", "corrected", "wording"])
        #expect(show(&presentation, corrected) == visible)
        #expect(show(&presentation, corrected) == "a different sentence with corrected wording")
    }

    @Test("new engine commitments override a conflicting presentation proposal")
    func commitmentsWin() {
        var presentation = WhisperPreviewPresentation()
        let old = words(["these", "are", "the", "older", "speculative", "words"])
        _ = show(&presentation, old)
        _ = show(&presentation, old)
        let remainder = words(["new", "tail", "later"])
        let tail = presentation.present(committedText: "Engine correction", tail: " new tail later", words: remainder, final: false)
        #expect(tail == " new tail")
        #expect("Engine correction" + tail == "Engine correction new tail")
    }

    @Test("unchanged visible text survives changed word boundaries")
    func noConfidenceRetraction() {
        var presentation = WhisperPreviewPresentation()
        let long = "abcdefghijklmnopqrstuvwxyz0123456789"
        let original = words([long])
        _ = show(&presentation, original)
        #expect(show(&presentation, original) == long)
        #expect(show(&presentation, words([long + "more"])) == long)
        #expect(show(&presentation, words([long + "more"])) == long + "more")
    }

    @Test("finalization flushes every provisional word without presentation gating")
    func finalFlush() {
        var presentation = WhisperPreviewPresentation()
        let first = words(["one", "two", "three", "four", "five"])
        #expect(show(&presentation, first) == "one two")
        #expect(show(&presentation, first, final: true) == "one two three four five")
    }

    @Test("Unicode words, punctuation, and repetitions retain their exact bytes")
    func multilingualAndRepeats() {
        for pieces in [["你", "好", "世", "界"], ["வணக்கம்", " தமிழ்", " உலகம்"],
                       ["👨‍👩‍👧‍👦", "🙂", "🙂", "!"], ["go", " go,", " go", " go!"]] {
            var presentation = WhisperPreviewPresentation()
            let input = pieces.enumerated().map { index, text in
                BufferedTranscriptionWord(text: text, start: Double(index), end: Double(index + 1))
            }
            let first = show(&presentation, input)
            #expect(input.map(\.text).joined().utf16.starts(with: first.utf16))
            #expect(first.count <= 24)
            #expect(show(&presentation, input).utf16.elementsEqual(pieces.joined().utf16))
        }
    }

    @Test("a long fresh word is capped without splitting joined emoji")
    func graphemeLimit() {
        var presentation = WhisperPreviewPresentation()
        let family = "👨‍👩‍👧‍👦"
        let prefix = String(repeating: family, count: 30)
        _ = show(&presentation, words([prefix + "a"]))
        let next = show(&presentation, words([prefix + "b"]))
        #expect(next == String(repeating: family, count: 24))
        #expect(next.count == 24)
        #expect(!next.unicodeScalars.contains("�"))
    }

    private func words(_ texts: [String], shift: Double = 0) -> [BufferedTranscriptionWord] {
        texts.enumerated().map { index, text in
            .init(text: (index == 0 ? "" : " ") + text,
                  start: shift + Double(index), end: shift + Double(index + 1))
        }
    }

    private func show(_ presentation: inout WhisperPreviewPresentation,
                      _ words: [BufferedTranscriptionWord], final: Bool = false) -> String {
        presentation.present(committedText: "", tail: words.map(\.text).joined(), words: words, final: final)
    }
}
