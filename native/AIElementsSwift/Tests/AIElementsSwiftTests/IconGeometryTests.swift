import XCTest
import SwiftUI
@testable import AIElementsSwift

final class IconGeometryTests: XCTestCase {
    func testConvertedArtworkStaysInsideViewBoxAndScales() {
        for icon in AIIconName.allCases {
            let shape = LucideShape(name: icon)
            let path = shape.path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
            XCTAssertFalse(path.isEmpty, icon.rawValue)
            let bounds = path.boundingRect
            XCTAssertTrue(bounds.minX.isFinite && bounds.maxY.isFinite, icon.rawValue)
            XCTAssertTrue(CGRect(x: -0.1, y: -0.1, width: 24.2, height: 24.2).contains(bounds), "\(icon): \(bounds)")
            let scaled = shape.path(in: CGRect(x: 5, y: 7, width: 48, height: 48)).boundingRect
            XCTAssertEqual(scaled.minX, bounds.minX * 2 + 5, accuracy: 0.001, icon.rawValue)
            XCTAssertEqual(scaled.minY, bounds.minY * 2 + 7, accuracy: 0.001, icon.rawValue)
            XCTAssertEqual(scaled.width, bounds.width * 2, accuracy: 0.001, icon.rawValue)
        }
    }
}
