import Foundation
import XCTest
@testable import MuesliCore

/// Golden tests for the insights text analyzer.
///
/// The portable implementation is tested explicitly on every platform so results
/// are deterministic regardless of whether Apple NaturalLanguage is available.
/// The public `InsightsWordAnalyzer` API is tested through invariants that both
/// the NaturalLanguage path and the portable path satisfy.
final class InsightsTextAnalysisTests: XCTestCase {

    private func portableCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        InsightsTextAnalysis.accumulatePortable(text, into: &counts)
        return counts
    }

    func testGoldenPunctuationCasingInflectionAndUnicode() {
        let text = "The Quick, brown fox. Don't jump! Running runs, RAN. the the the cats cat cat cities city naïve café café"
        let counts = portableCounts(text)
        XCTAssertEqual(counts, [
            "quick": 1,
            "brown": 1,
            "fox": 1,
            "don't": 1,
            "jump": 1,
            "run": 2,
            "ran": 1,
            "cat": 3,
            "city": 2,
            "naïve": 1,
            "café": 2,
        ])
    }

    func testPunctuationAndCasingNormalization() {
        XCTAssertEqual(portableCounts("hello, hello. (hello) HELLO"), ["hello": 4])
    }

    func testEnglishStopwordsRemoved() {
        XCTAssertEqual(portableCounts("the and a an the"), [:])
    }

    func testContractionsAreRetainedNotMangled() {
        let counts = portableCounts("won't can't don't")
        XCTAssertEqual(counts, ["won't": 1, "can't": 1, "don't": 1])
    }

    func testUnicodeIsPreserved() {
        let counts = portableCounts("Zürich Zürich 東京 東京")
        XCTAssertEqual(counts["zürich"], 2)
        XCTAssertEqual(counts["東京"], 2)
    }

    func testDevanagariDetectedAsHindiAndStopwordsRemoved() {
        XCTAssertEqual(InsightsTextAnalysis.detectLanguage(in: "और यह है"), "hi")
        XCTAssertEqual(portableCounts("और यह है नमस्ते नमस्ते"), ["नमस्ते": 2])
    }

    func testSpanishStopwordsAndLanguageDetection() {
        XCTAssertEqual(InsightsTextAnalysis.detectLanguage(in: "el la de que y para"), "es")
        XCTAssertEqual(portableCounts("el la de que y para gato gato"), ["gato": 2])
    }

    func testFrenchAndGermanLanguageDetection() {
        XCTAssertEqual(InsightsTextAnalysis.detectLanguage(in: "le la et dans pour"), "fr")
        XCTAssertEqual(portableCounts("le la et café café"), ["café": 2])
        XCTAssertEqual(InsightsTextAnalysis.detectLanguage(in: "der die und nicht"), "de")
        XCTAssertEqual(portableCounts("der die und straße straße"), ["straße": 2])
    }

    func testDefaultLanguageIsEnglish() {
        XCTAssertEqual(InsightsTextAnalysis.detectLanguage(in: "unique widgets"), "en")
    }

    func testTokenizerKeepsIntraWordApostrophes() {
        XCTAssertEqual(InsightsTextAnalysis.tokenize("don't stop"), ["don't", "stop"])
        XCTAssertEqual(InsightsTextAnalysis.tokenize("naïve café"), ["naïve", "café"])
    }

    func testStemmerMergesCommonInflections() {
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("running"), "run")
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("stopped"), "stop")
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("jumped"), "jump")
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("cats"), "cat")
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("cities"), "city")
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("classes"), "class")
        XCTAssertEqual(InsightsTextAnalysis.stemEnglish("called"), "call")
    }

    // MARK: - Public API invariants (valid on macOS NaturalLanguage and Windows)

    func testFrequenciesDropStopwordsAndRankByCount() {
        let frequencies = InsightsWordAnalyzer.frequencies(in: "The cat and the dog and a cat")
        XCTAssertEqual(frequencies.map(\.word), ["cat", "dog"])
        XCTAssertEqual(frequencies.map(\.count), [2, 1])
    }

    func testMeetingFrequenciesStripSpeakerLabelsAndNoise() {
        let transcript = """
        Speaker 1: Hello world
        Speaker 2: Hello [music playing] there
        """
        let frequencies = InsightsWordAnalyzer.meetingFrequencies(in: transcript)
        XCTAssertEqual(frequencies.first?.word, "hello")
        XCTAssertEqual(frequencies.first?.count, 2)
    }

    func testCleanedMeetingTranscriptRemovesLabelsAndBracketedNoise() {
        let cleaned = InsightsWordAnalyzer.cleanedMeetingTranscript("Speaker 1: hi [applause] everyone")
        XCTAssertFalse(cleaned.contains("Speaker 1"))
        XCTAssertFalse(cleaned.contains("applause"))
        XCTAssertTrue(cleaned.contains("hi"))
    }
}
