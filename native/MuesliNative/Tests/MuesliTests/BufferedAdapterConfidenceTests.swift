import FluidAudio
import Testing
import struct WhisperKit.WordTiming
@testable import MuesliNativeApp

@Suite("Buffered adapter confidence")
struct BufferedAdapterConfidenceTests {
    private func token(_ text: String, _ index: Int, confidence: Float = 0.9) -> TokenTiming {
        .init(token: text, tokenId: index, startTime: Double(index) * 0.1,
              endTime: Double(index) * 0.1 + 0.08, confidence: confidence)
    }

    private func expectUpstreamParity(_ tokens: [TokenTiming]) {
        let expected = buildWordTimings(from: tokens)
        let actual = FluidAudioBufferedWordTimings.build(from: tokens)
        #expect(actual.count == expected.count)
        for (word, upstream) in zip(actual, expected) {
            #expect(word.text.utf16.elementsEqual(upstream.word.utf16))
            #expect(word.start == upstream.startTime)
            #expect(word.end == upstream.endTime)
        }
    }

    @Test("FluidAudio grouping matches installed upstream across boundary and special-token combinations")
    func upstreamGroupingParity() {
        let pieces = ["", "<blank>", "<pad>", "▁", " ", "  ", "▁hello", " world", "ing", ",", "你好", "e\u{301}"]
        expectUpstreamParity([])
        for first in pieces {
            for second in pieces {
                expectUpstreamParity([token(first, 0), token(second, 1), token("!", 2), token("▁next", 3)])
            }
        }
    }

    @Test("FluidAudio preserves minimum subword confidence, including punctuation")
    func weakestConstituent() {
        let tokens = [token("▁hel", 0, confidence: 0.95), token("lo", 1, confidence: 0.6),
                      token(",", 2, confidence: 0.8), token(" world", 3, confidence: 0.75)]
        expectUpstreamParity(tokens)
        let words = FluidAudioBufferedWordTimings.build(from: tokens)
        #expect(words.map(\.text) == ["hello,", "world"])
        #expect(words.map(\.confidence) == [0.6, 0.75])
    }

    @Test("An invalid constituent never disappears behind another valid confidence",
          arguments: [Float.nan, .infinity, -.infinity, -0.1, 1.1])
    func invalidConstituent(invalid: Float) {
        for invalidIndex in 0..<3 {
            let pieces = ["▁uncer", "tain", "."]
            let tokens = pieces.enumerated().map {
                token($0.element, $0.offset, confidence: $0.offset == invalidIndex ? invalid : 0.9)
            } + [token(" next", 3, confidence: 1)]
            let words = FluidAudioBufferedWordTimings.build(from: tokens)
            #expect(words[0].confidence == nil)
            #expect(words[1].confidence == 1)
            expectUpstreamParity(tokens)
        }
    }

    @Test("Skipped and standalone marker tokens follow upstream ownership exactly")
    func discardedMarkersAndSpecialTokens() {
        let tokens = [token("▁", 0, confidence: .nan), token("Hello", 1, confidence: 0.8),
                      token("<blank>", 2, confidence: .nan), token("", 3, confidence: .nan),
                      token("<pad>", 4, confidence: .nan), token(" ", 5, confidence: .nan),
                      token("world", 6, confidence: 0)]
        expectUpstreamParity(tokens)
        let words = FluidAudioBufferedWordTimings.build(from: tokens)
        #expect(words.map(\.confidence) == [0.8, 0])
        #expect(words.map(\.start) == [tokens[1].startTime, tokens[6].startTime])
        // Two spaces leave one in the current word after upstream strips its
        // boundary, so that token contributes to the next word's span/score.
        let whitespace = [token("  ", 0, confidence: .nan), token("hello", 1)]
        expectUpstreamParity(whitespace)
        #expect(FluidAudioBufferedWordTimings.build(from: whitespace).first?.confidence == nil)
    }

    @Test("Whisper preview preserves every word probability and exact spelling/span")
    func whisperProbability() throws {
        let original: [WordTiming] = [
            .init(word: "Hello", tokens: [1], start: 0.1, end: 0.4, probability: 0.9),
            .init(word: " world!", tokens: [2, 3], start: 0.5, end: 0.8, probability: 0.3)
        ]
        let words = WhisperKitTranscriber.previewWords(from: original)
        for (word, source) in zip(words, original) {
            #expect(word.text.utf16.elementsEqual(source.word.utf16))
            #expect(word.start == Double(source.start))
            #expect(word.end == Double(source.end))
            #expect(word.confidence == source.probability)
        }
        let aligned = try WhisperKitTranscriber.previewWindow(text: "Hello world!", words: words, sampleCount: 16_000)
        #expect(aligned.words.map(\.confidence) == [0.9, 0.3])
        #expect(WhisperKitTranscriber.previewWords(from: []).isEmpty)
        let invalid = WhisperKitTranscriber.previewWords(from: [
            .init(word: "unknown", tokens: [1], start: 0, end: 0.1, probability: .nan)
        ])
        #expect(invalid[0].confidence?.isNaN == true)
    }
}
