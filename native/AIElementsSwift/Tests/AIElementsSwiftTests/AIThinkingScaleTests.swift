import XCTest
@testable import AIElementsSwift

final class AIThinkingScaleTests: XCTestCase {
    func testUnsupportedLevelsNeverOccupySliderPositions() {
        let available = AIThinkingScale.available([
            .init(id: "low", title: "Low"),
            .init(id: "medium", title: "Medium", disabledReason: "Not supported by this model"),
            .init(id: "high", title: "High")
        ])
        XCTAssertEqual(available.map(\.id), ["low", "high"])
        XCTAssertEqual(AIThinkingScale.choice(at: 1, in: available)?.id, "high")
    }

    func testPositionsRoundClampAndRejectInvalidNumbers() {
        let choices: [AIThinkingChoice] = [.init(id: "low", title: "Low"), .init(id: "high", title: "High")]
        XCTAssertEqual(AIThinkingScale.choice(at: 0.6, in: choices)?.id, "high")
        XCTAssertEqual(AIThinkingScale.choice(at: -100, in: choices)?.id, "low")
        XCTAssertEqual(AIThinkingScale.choice(at: Double.greatestFiniteMagnitude, in: choices)?.id, "high")
        XCTAssertNil(AIThinkingScale.choice(at: .nan, in: choices))
        XCTAssertNil(AIThinkingScale.choice(at: .infinity, in: choices))
        XCTAssertNil(AIThinkingScale.choice(at: 0, in: []))
    }
}
