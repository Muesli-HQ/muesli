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
    func testDragPreviewsLocallyAndCommitsOnlyTheFinalChoice() {
        let choices: [AIThinkingChoice] = [
            .init(id: "low", title: "Low"), .init(id: "medium", title: "Medium"), .init(id: "high", title: "High")
        ]
        var drag = AIThinkingDragState()
        drag.begin(at: 0)
        XCTAssertNil(drag.update(1, choices: choices, selectedID: "low"))
        XCTAssertEqual(drag.position, 1)
        XCTAssertNil(drag.update(2, choices: choices, selectedID: "low"))
        XCTAssertEqual(drag.finish(choices: choices, selectedID: "low"), "high")
        XCTAssertFalse(drag.isEditing)
        XCTAssertNil(drag.position)
        XCTAssertNil(drag.finish(choices: choices, selectedID: "low"))
    }

    func testCancelledOrUnchangedDragDoesNotPersistAndKeyboardStepsDo() {
        let choices: [AIThinkingChoice] = [.init(id: "low", title: "Low"), .init(id: "high", title: "High")]
        var drag = AIThinkingDragState()
        drag.begin(at: 0)
        XCTAssertNil(drag.update(1, choices: choices, selectedID: "low"))
        drag.cancel() // A provider/model or supported-choice change cancels the gesture.
        XCTAssertNil(drag.finish(choices: choices, selectedID: "low"))
        drag.begin(at: 0)
        XCTAssertNil(drag.finish(choices: choices, selectedID: "low"))
        XCTAssertEqual(drag.update(1, choices: choices, selectedID: "low"), "high")
        XCTAssertNil(drag.update(.nan, choices: choices, selectedID: "low"))
    }
}
