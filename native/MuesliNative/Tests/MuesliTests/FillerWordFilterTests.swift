import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Filler Word Filter")
struct FillerWordFilterTests {

    @Test("removes uh and um")
    func removeUhUm() {
        #expect(FillerWordFilter.apply("So uh I was thinking um about this") == "So I was thinking about this")
    }

    @Test("removes multiple fillers")
    func removeMultiple() {
        #expect(FillerWordFilter.apply("Uh um err the thing is") == "The thing is")
    }

    @Test("keeps Norwegian verb er")
    func keepsNorwegianEr() {
        #expect(FillerWordFilter.apply("Det er kjemperelevant") == "Det er kjemperelevant")
        #expect(FillerWordFilter.apply("Er det klart?") == "Er det klart?")
    }

    @Test("handles fillers at start")
    func fillerAtStart() {
        let result = FillerWordFilter.apply("Uh hello world")
        #expect(result == "Hello world")
    }

    @Test("preserves clean text")
    func cleanText() {
        #expect(FillerWordFilter.apply("Hello world") == "Hello world")
    }

    @Test("empty text returns empty")
    func emptyText() {
        #expect(FillerWordFilter.apply("") == "")
    }

    @Test("removes hmm and variants")
    func removeHmm() {
        #expect(FillerWordFilter.apply("Hmm let me think") == "Let me think")
    }

    @Test("collapses extra spaces")
    func collapsesSpaces() {
        let result = FillerWordFilter.apply("I uh uh think so")
        #expect(!result.contains("  "))
    }

    @Test("capitalizes after filler removal at start")
    func capitalizesAfterRemoval() {
        let result = FillerWordFilter.apply("um the answer is yes")
        #expect(result.first?.isUppercase == true)
    }
}
