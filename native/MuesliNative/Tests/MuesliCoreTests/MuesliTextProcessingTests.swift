import Foundation
import XCTest
@testable import MuesliCore

/// Golden tests for the canonical shared transcript text operations. These run
/// on every platform and are the definition Windows parity is measured against.
final class MuesliTextProcessingTests: XCTestCase {
    func testNormalizeEmptyAndWhitespaceOnly() {
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript(""), "")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("   "), "")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("\n\t \r\n"), "")
    }

    func testNormalizeTrimsAndCollapses() {
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("  hello   world  "), "hello world")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("hello\tworld"), "hello world")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("a\nb\rc\r\nd"), "a b c d")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("first\n\nsecond paragraph"), "first second paragraph")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("multiple     internal    spaces"), "multiple internal spaces")
    }

    func testNormalizeIsIdempotent() {
        for input in ["a  b", "  lead", "trail  ", "x\n\ny", "", "  ", "café 東京  ok"] {
            let once = MuesliTextProcessing.normalizeTranscript(input)
            XCTAssertEqual(MuesliTextProcessing.normalizeTranscript(once), once, "input: \(input)")
        }
    }

    func testNormalizePreservesContentCharacters() {
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("it’s a “quote”—really"), "it’s a “quote”—really")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("don't can't won't"), "don't can't won't")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("3.14 and 42 and 1,000"), "3.14 and 42 and 1,000")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("Zürich café 東京 Москва नमस्ते"), "Zürich café 東京 Москва नमस्ते")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("emoji 🎙️ stays"), "emoji 🎙️ stays")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("!!! ??? ..."), "!!! ??? ...")
    }

    func testNormalizeHandlesUnicodeWhitespace() {
        // Non-breaking space (U+00A0) is Unicode White_Space and collapses too.
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("a\u{00A0}\u{00A0}b"), "a b")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript("\u{2028}line\u{2029}"), "line")
    }

    func testNormalizeLargeInput() {
        let count = 100_000
        let input = String(repeating: "word  \n", count: count)
        let expected = Array(repeating: "word", count: count).joined(separator: " ")
        XCTAssertEqual(MuesliTextProcessing.normalizeTranscript(input), expected)
    }

    func testWordCountContract() {
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: ""), 0)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "   \n\t "), 0)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "one"), 1)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "one two three"), 3)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "one   two\n\nthree"), 3)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "— ... !!!"), 3)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "don't stop"), 2)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "3.14 42 1,000"), 3)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "東京 は 日本 です"), 4)
        XCTAssertEqual(MuesliTextProcessing.wordCount(in: "a🎙️b c"), 2)
    }

    func testDictationStoreCountWordsUsesCanonicalImplementation() {
        XCTAssertEqual(DictationStore.countWords(in: "  hello   shared world "), MuesliTextProcessing.wordCount(in: "  hello   shared world "))
        XCTAssertEqual(DictationStore.countWords(in: "one two three"), 3)
    }
}
