import Testing
import Foundation
@testable import MuesliCore

@Suite("Jaro-Winkler Similarity")
struct JaroWinklerTests {

    @Test("identical strings return 1.0")
    func identical() {
        #expect(CustomWordMatcher.jaroWinklerSimilarity("hello", "hello") == 1.0)
    }

    @Test("completely different strings return low score")
    func different() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("abc", "xyz")
        #expect(score < 0.5)
    }

    @Test("similar strings score high")
    func similar() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("pranav", "pranab")
        #expect(score > 0.85)
    }

    @Test("empty strings")
    func empty() {
        #expect(CustomWordMatcher.jaroWinklerSimilarity("", "") == 1.0)
        #expect(CustomWordMatcher.jaroWinklerSimilarity("hello", "") == 0.0)
        #expect(CustomWordMatcher.jaroWinklerSimilarity("", "hello") == 0.0)
    }

    @Test("single character strings don't crash")
    func singleChar() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("a", "b")
        #expect(score >= 0 && score <= 1)
        let score2 = CustomWordMatcher.jaroWinklerSimilarity("a", "a")
        #expect(score2 == 1.0)
        let score3 = CustomWordMatcher.jaroWinklerSimilarity("I", "muesli")
        #expect(score3 >= 0 && score3 <= 1)
    }

    @Test("short vs long strings don't crash")
    func shortVsLong() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("a", "abcdefghij")
        #expect(score >= 0 && score <= 1)
    }

    @Test("common prefix boosts score")
    func prefixBoost() {
        let withPrefix = CustomWordMatcher.jaroWinklerSimilarity("muesli", "muesly")
        let noPrefix = CustomWordMatcher.jaroWinklerSimilarity("xuesli", "muesly")
        #expect(withPrefix > noPrefix)
    }
}

@Suite("Custom Word Matcher")
struct CustomWordMatcherApplyTests {

    @Test("exact match replaces word")
    func exactMatch() {
        let words = [CustomWord(word: "museli", replacement: "muesli")]
        let result = CustomWordMatcher.apply(text: "I love museli", customWords: words)
        #expect(result == "I love muesli")
    }

    @Test("case-insensitive exact match")
    func caseInsensitive() {
        let words = [CustomWord(word: "Pranav", replacement: "Pranav")]
        let result = CustomWordMatcher.apply(text: "hello pranav", customWords: words)
        #expect(result == "hello Pranav")
    }

    @Test("preserves punctuation")
    func preservesPunctuation() {
        let words = [CustomWord(word: "museli", replacement: "muesli")]
        let result = CustomWordMatcher.apply(text: "I love museli!", customWords: words)
        #expect(result == "I love muesli!")
    }

    @Test("fuzzy match replaces similar word")
    func fuzzyMatch() {
        let words = [CustomWord(word: "kubernetes", replacement: "Kubernetes")]
        let result = CustomWordMatcher.apply(text: "deploy to kubernete", customWords: words)
        // "kubernete" vs "kubernetes" should be > 0.85 Jaro-Winkler
        #expect(result == "deploy to Kubernetes")
    }

    @Test("no match leaves word unchanged")
    func noMatch() {
        let words = [CustomWord(word: "muesli", replacement: "Muesli")]
        let result = CustomWordMatcher.apply(text: "hello world", customWords: words)
        #expect(result == "hello world")
    }

    @Test("empty text returns empty")
    func emptyText() {
        let words = [CustomWord(word: "test", replacement: "Test")]
        #expect(CustomWordMatcher.apply(text: "", customWords: words) == "")
    }

    @Test("empty custom words returns original")
    func emptyWords() {
        #expect(CustomWordMatcher.apply(text: "hello", customWords: []) == "hello")
    }

    @Test("word with no replacement uses word itself")
    func noReplacement() {
        let words = [CustomWord(word: "muesli", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "I love museli", customWords: words)
        // "museli" fuzzy matches "muesli", replacement is nil so uses word "muesli"
        #expect(result == "I love muesli")
    }

    @Test("per-word lower threshold allows aggressive fuzzy correction")
    func lowerThresholdAllowsCorrection() {
        let words = [CustomWord(word: "Caivex", replacement: "Caivex", matchingThreshold: 0.70)]
        let result = CustomWordMatcher.apply(text: "talk to Kvex tomorrow", customWords: words)
        #expect(result == "talk to Caivex tomorrow")
    }

    @Test("higher threshold blocks over-eager fuzzy correction")
    func higherThresholdPreventsCorrection() {
        let words = [CustomWord(word: "Caivex", replacement: "Caivex", matchingThreshold: 0.92)]
        let result = CustomWordMatcher.apply(text: "talk to Kvex tomorrow", customWords: words)
        #expect(result == "talk to Kvex tomorrow")
    }

    @Test("multi-word exact match replaces the full phrase")
    func multiWordExactMatch() {
        let words = [CustomWord(word: "open telemetry", replacement: "OpenTelemetry")]
        let result = CustomWordMatcher.apply(text: "ship open telemetry traces", customWords: words)
        #expect(result == "ship OpenTelemetry traces")
    }

    @Test("multi-word fuzzy match replaces only same-length phrase windows")
    func multiWordFuzzyMatch() {
        let words = [CustomWord(word: "open telemetry", replacement: "OpenTelemetry")]
        let result = CustomWordMatcher.apply(text: "ship open telemtry traces", customWords: words)
        #expect(result == "ship OpenTelemetry traces")
    }

    @Test("multi-word entries do not partial-match shorter utterances")
    func multiWordDoesNotPartialMatchShorterUtterance() {
        let words = [CustomWord(word: "new york city", replacement: "NYC")]
        let result = CustomWordMatcher.apply(text: "book new york", customWords: words)
        #expect(result == "book new york")
    }

    @Test("multi-word fuzzy match requires each token to match")
    func multiWordFuzzyMatchRequiresEachTokenToMatch() {
        let words = [CustomWord(word: "new york city", replacement: "NYC")]
        let result = CustomWordMatcher.apply(text: "book new york flights", customWords: words)
        #expect(result == "book new york flights")
    }

    @Test("three-word exact match replaces the full phrase")
    func threeWordExactMatch() {
        let words = [CustomWord(word: "new york city", replacement: "NYC")]
        let result = CustomWordMatcher.apply(text: "book new york city flights", customWords: words)
        #expect(result == "book NYC flights")
    }

    @Test("longest phrase match wins before shorter word match")
    func longestPhraseWinsBeforeShorterWord() {
        let words = [
            CustomWord(word: "open", replacement: "Open"),
            CustomWord(word: "open telemetry", replacement: "OpenTelemetry"),
        ]
        let result = CustomWordMatcher.apply(text: "open telemetry helps open systems", customWords: words)
        #expect(result == "OpenTelemetry helps Open systems")
    }

    @Test("multi-word phrase replacement preserves trailing punctuation")
    func multiWordPreservesTrailingPunctuation() {
        let words = [CustomWord(word: "open telemetry", replacement: "OpenTelemetry")]
        let result = CustomWordMatcher.apply(text: "try open telemetry, please", customWords: words)
        #expect(result == "try OpenTelemetry, please")
    }

    @Test("multi-word phrase replacement does not drop internal punctuation")
    func multiWordDoesNotDropInternalPunctuation() {
        let words = [CustomWord(word: "open telemetry", replacement: "OpenTelemetry")]
        let result = CustomWordMatcher.apply(text: "try open, telemetry now", customWords: words)
        #expect(result == "try open, telemetry now")
    }

    // MARK: Possessives

    @Test("possessive survives an exact match")
    func possessiveSurvivesExactMatch() {
        let words = [CustomWord(word: "Caivex", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "open Caivex's settings", customWords: words)
        #expect(result == "open Caivex's settings")
    }

    @Test("possessive survives a fuzzy correction")
    func possessiveSurvivesFuzzyCorrection() {
        let words = [CustomWord(word: "Caivex", replacement: "Caivex", matchingThreshold: 0.70)]
        let result = CustomWordMatcher.apply(text: "ask Kvex's team", customWords: words)
        #expect(result == "ask Caivex's team")
    }

    @Test("curly-apostrophe possessive survives a match")
    func curlyPossessiveSurvivesMatch() {
        let words = [CustomWord(word: "Caivex", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "open Caivex\u{2019}s settings", customWords: words)
        #expect(result == "open Caivex\u{2019}s settings")
    }

    @Test("possessive survives a multi-word phrase match")
    func possessiveSurvivesPhraseMatch() {
        let words = [CustomWord(word: "open telemetry", replacement: "OpenTelemetry")]
        let result = CustomWordMatcher.apply(text: "check open telemetry's exporter", customWords: words)
        #expect(result == "check OpenTelemetry's exporter")
    }

    @Test("entry that is itself possessive is not doubled")
    func possessiveEntryIsNotDoubled() {
        let words = [CustomWord(word: "McDonald's", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "lunch at mcdonald's today", customWords: words)
        #expect(result == "lunch at McDonald's today")
    }

    // MARK: Words much shorter than the entry

    @Test("word that is the start of a longer entry is not rewritten")
    func truncatedPrefixIsNotRewritten() {
        // "north" vs "northcap" scores ~0.93 only because of the shared prefix.
        let words = [CustomWord(word: "Northcap", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "head north after lunch", customWords: words)
        #expect(result == "head north after lunch")
    }

    @Test("much shorter word is not rewritten")
    func muchShorterWordIsNotRewritten() {
        // "yes" vs "yonesh" scores 0.85 at the default threshold.
        let words = [CustomWord(word: "Yonesh", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "Yes. Send it over.", customWords: words)
        #expect(result == "Yes. Send it over.")
    }

    // MARK: Replacement already present in the text

    @Test("one-word entry with a multi-word replacement keeps a correct spelling")
    func multiWordReplacementIsNotDuplicated() {
        let words = [CustomWord(word: "XYWidget", replacement: "XY Widget")]
        let result = CustomWordMatcher.apply(text: "order the XY Widget now", customWords: words)
        #expect(result == "order the XY Widget now")
    }

    @Test("misspelled tail of a multi-word replacement is fixed without duplicating")
    func multiWordReplacementTailIsFixedInPlace() {
        let words = [CustomWord(word: "XYWidget", replacement: "XY Widget")]
        let result = CustomWordMatcher.apply(text: "order the XY Widgett now", customWords: words)
        #expect(result == "order the XY Widget now")
    }

    @Test("abbreviation expanding to a phrase is not applied inside that phrase")
    func expansionIsNotAppliedInsideReplacement() {
        let words = [CustomWord(word: "xy", replacement: "XY Widget")]
        let result = CustomWordMatcher.apply(text: "order the XY Widget now", customWords: words)
        #expect(result == "order the XY Widget now")
    }

    @Test("one-word entry still expands to its multi-word replacement")
    func multiWordReplacementStillExpands() {
        let words = [CustomWord(word: "XYWidget", replacement: "XY Widget")]
        let result = CustomWordMatcher.apply(text: "order the xywidget now", customWords: words)
        #expect(result == "order the XY Widget now")
    }

    @Test("repeated expansions each keep their full replacement")
    func repeatedExpansionKeepsFullReplacement() {
        let words = [CustomWord(word: "xy", replacement: "XY Widget")]
        let result = CustomWordMatcher.apply(text: "xy xy", customWords: words)
        #expect(result == "XY Widget XY Widget")
    }

    @Test("words across a sentence break are not treated as part of the replacement")
    func replacementOverlapStopsAtSentenceBreak() {
        let words = [CustomWord(word: "nyc", replacement: "New York")]
        let result = CustomWordMatcher.apply(text: "I bought something new. nyc is next.", customWords: words)
        #expect(result == "I bought something new. New York is next.")
    }

    @Test("replacement words already on both sides of the match are reused")
    func replacementOverlapOnBothSides() {
        let words = [CustomWord(word: "York", replacement: "New York City")]
        let result = CustomWordMatcher.apply(text: "visit New York City soon", customWords: words)
        #expect(result == "visit New York City soon")
    }

    // MARK: Possessive entries and replacements

    @Test("explicit possessive entry wins over its base word's entry")
    func explicitPossessiveEntryWins() {
        let words = [
            CustomWord(word: "Alex", replacement: "Alexander"),
            CustomWord(word: "Alex's", replacement: "Alex's team"),
        ]
        let result = CustomWordMatcher.apply(text: "Alex's update", customWords: words)
        #expect(result == "Alex's team update")
    }

    @Test("possessive already in the replacement is not added twice")
    func possessiveReplacementIsNotDoubled() {
        let words = [CustomWord(word: "mcdonald", replacement: "McDonald's")]
        let result = CustomWordMatcher.apply(text: "lunch at mcdonald's", customWords: words)
        #expect(result == "lunch at McDonald's")
    }

    // MARK: Reuse limits for replacement words around a match

    @Test("separate expansions do not reuse each other's words")
    func separateExpansionsKeepAllWords() {
        let words = [CustomWord(word: "lol", replacement: "ha ha")]
        let result = CustomWordMatcher.apply(text: "lol lol", customWords: words)
        #expect(result == "ha ha ha ha")
    }

    @Test("possessive match does not reuse the following word")
    func possessiveMatchKeepsFullReplacement() {
        let words = [CustomWord(word: "nyc", replacement: "New York")]
        let result = CustomWordMatcher.apply(text: "nyc's York", customWords: words)
        #expect(result == "New York's York")
    }

    @Test("following word that another entry rewrites is not reused")
    func followingWordRewrittenLaterIsNotReused() {
        let words = [
            CustomWord(word: "nyc", replacement: "New York"),
            CustomWord(word: "York", replacement: "Yorkshire"),
        ]
        let result = CustomWordMatcher.apply(text: "nyc York", customWords: words)
        #expect(result == "New York Yorkshire")
    }

    @Test("following word that another entry only recases is still reused")
    func followingWordRecasedLaterIsReused() {
        let words = [
            CustomWord(word: "nyc", replacement: "New York"),
            CustomWord(word: "York", replacement: nil),
        ]
        let result = CustomWordMatcher.apply(text: "nyc york", customWords: words)
        #expect(result == "New York")
    }

    @Test("replacement punctuation is kept rather than reusing unpunctuated words")
    func replacementPunctuationIsKept() {
        let words = [CustomWord(word: "nyc", replacement: "New, York")]
        let result = CustomWordMatcher.apply(text: "New nyc", customWords: words)
        #expect(result == "New New, York")
    }

    @Test("word an earlier entry leaves unchanged or recases is still reused")
    func unchangedEarlierMatchIsReused() {
        let words = [
            CustomWord(word: "XY", replacement: "XY"),
            CustomWord(word: "Widget", replacement: "XY Widget"),
        ]
        #expect(CustomWordMatcher.apply(text: "XY Widget", customWords: words) == "XY Widget")
        #expect(CustomWordMatcher.apply(text: "xy widget", customWords: words) == "XY Widget")
    }

    @Test("long run of a self-expanding word is corrected without deep recursion")
    func longRepeatedRunStaysLinear() {
        let words = [CustomWord(word: "ha", replacement: "ha ha")]
        let text = Array(repeating: "ha", count: 5_000).joined(separator: " ")
        let result = CustomWordMatcher.apply(text: text, customWords: words)
        #expect(result == Array(repeating: "ha", count: 10_000).joined(separator: " "))
    }
}
