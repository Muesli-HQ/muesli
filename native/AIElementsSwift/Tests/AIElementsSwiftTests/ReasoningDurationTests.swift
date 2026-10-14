import XCTest
@testable import AIElementsSwift

final class ReasoningDurationTests: XCTestCase {
    func testSummaryMarkdownRendersEmphasisWithoutActivatingLinks() {
        let text = AIReasoning.summaryInlineContent("**Searching action items** and [reference](https://example.com)")
        XCTAssertEqual(String(text.characters), "Searching action items and reference")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(text.runs.allSatisfy { $0.link == nil })
    }

    func testMissingOrInvalidHostDurationIsNotDisplayed() {
        XCTAssertNil(AIReasoning.durationLabel(nil))
        XCTAssertNil(AIReasoning.durationLabel(-1))
        XCTAssertNil(AIReasoning.durationLabel(.infinity))
        XCTAssertNil(AIReasoning.durationLabel(.nan))
    }

    func testElapsedTimeDoesNotRoundUpBeforeItPasses() {
        XCTAssertEqual(AIReasoning.durationLabel(0), "0s")
        XCTAssertEqual(AIReasoning.durationLabel(59.99), "59s")
        XCTAssertEqual(AIReasoning.durationLabel(60), "1m 0s")
        XCTAssertEqual(AIReasoning.durationLabel(125.9), "2m 5s")
    }

    func testUnreasonablyLargeHostDurationCannotOverflow() {
        XCTAssertEqual(AIReasoning.durationLabel(.greatestFiniteMagnitude), "525600m 0s")
    }
}
