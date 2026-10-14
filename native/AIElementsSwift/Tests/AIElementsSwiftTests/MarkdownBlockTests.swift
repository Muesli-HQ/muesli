import XCTest
@testable import AIElementsSwift

final class MarkdownBlockTests: XCTestCase {
    func testTablesPreserveEscapedPipesAndCodeSpans() {
        let markdown = "| Name | Value |\n| :--- | ---: |\n| A \\| B | ``a`|b`` |\n| C | `x|y` |"
        XCTAssertEqual(AIMarkdownBlock.parse(markdown), [.table([
            ["Name", "Value"], ["A | B", "``a`|b``"], ["C", "`x|y`"]
        ])])
    }

    func testFenceLengthAndCharacterProtectCodeContents() {
        XCTAssertEqual(AIMarkdownBlock.parse("````swift\n```\nA | B\n--- | ---\n````"), [.code("```\nA | B\n--- | ---")])
        XCTAssertEqual(AIMarkdownBlock.parse("~~~text\n```\n~~~"), [.code("```")])
        XCTAssertEqual(AIMarkdownBlock.parse("```\nunclosed"), [.code("unclosed")])
    }

    func testPartialTablesAndHTMLStayInertText() {
        XCTAssertEqual(AIMarkdownBlock.parse("A | B\nnot a separator\n<script>alert('x')</script>"), [
            .line("A | B"), .line("not a separator"), .line("<script>alert('x')</script>")
        ])
    }

    func testSingleColumnTableAndOtherBlockMarkersSurvive() {
        XCTAssertEqual(AIMarkdownBlock.parse("# Heading\n- [x] Done\n> Quote\n| Only |\n| --- |\n| Cell |"), [
            .line("# Heading"), .line("- [x] Done"), .line("> Quote"), .table([["Only"], ["Cell"]])
        ])
    }

    func testEscapedTrailingPipeIsContentRatherThanDelimiter() {
        XCTAssertEqual(AIMarkdownBlock.parse("A | B\n--- | ---\nx | y\\|"), [.table([["A", "B"], ["x", "y|"]])])
    }
}
