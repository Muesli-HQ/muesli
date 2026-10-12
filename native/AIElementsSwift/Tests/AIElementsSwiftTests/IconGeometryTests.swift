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

extension IconGeometryTests {
    func testAuditedChatImportsHaveNativeArtwork() throws {
        struct Coverage: Decodable {
            struct Source: Decodable {
                struct Icon: Decodable { let swift: String; let svg: String }
                let icons: [Icon]
            }
            let chatbotComponents: [String]
            let files: [Source]
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Upstream/chat-icon-coverage.json"))
        let coverage = try JSONDecoder().decode(Coverage.self, from: data)
        XCTAssertEqual(coverage.chatbotComponents.count, 19)
        XCTAssertEqual(coverage.files.count, 40)
        let imported = coverage.files.flatMap(\.icons)
        XCTAssertEqual(Set(imported.map(\.svg)).count, 33)
        for icon in imported {
            XCTAssertNotNil(AIIconName(rawValue: icon.swift), icon.svg)
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                root.appendingPathComponent("Upstream/Lucide/\(icon.svg).svg").path), icon.svg)
        }
    }
}
