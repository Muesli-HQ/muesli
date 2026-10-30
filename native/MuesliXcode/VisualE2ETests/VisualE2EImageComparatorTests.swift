import AppKit
import XCTest

final class VisualE2EImageComparatorTests: XCTestCase {
    func testComparisonClassifiesMissingMatchedAndChangedBaselines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuesliVisualE2EComparator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let red = try png(red: 1, green: 0, blue: 0)
        let blue = try png(red: 0, green: 0, blue: 1)
        let baselineURL = directory.appendingPathComponent("baseline.png")

        let missing = try VisualE2EImageComparator.compare(
            actualPNG: red,
            baselineURL: baselineURL,
            artifactDirectory: directory
        )
        XCTAssertEqual(missing.status, .missingBaseline)
        XCTAssertNil(missing.expectedURL)
        XCTAssertNil(missing.diffURL)

        try red.write(to: baselineURL)
        let matched = try VisualE2EImageComparator.compare(
            actualPNG: red,
            baselineURL: baselineURL,
            artifactDirectory: directory
        )
        XCTAssertEqual(matched.status, .matched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("expected.png").path))
        XCTAssertNil(matched.diffURL)

        let changed = try VisualE2EImageComparator.compare(
            actualPNG: blue,
            baselineURL: baselineURL,
            artifactDirectory: directory
        )
        XCTAssertEqual(changed.status, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("diff.png").path))
    }

    func testRelativeArtifactPathRejectsPathsOutsideReportDirectory() throws {
        let report = URL(fileURLWithPath: "/tmp/visual-results", isDirectory: true)
        XCTAssertEqual(
            try VisualE2EResultWriter.relativeArtifactPath(
                URL(fileURLWithPath: "/tmp/visual-results/cases/e2e/example/actual.png"),
                reportDirectory: report
            ),
            "cases/e2e/example/actual.png"
        )
        XCTAssertThrowsError(
            try VisualE2EResultWriter.relativeArtifactPath(
                URL(fileURLWithPath: "/tmp/not-visual-results/actual.png"),
                reportDirectory: report
            )
        )
    }

    func testRunnerJSONContractsRequireExpectedShapes() throws {
        let profile = try VisualE2EConfiguration.jsonObject(named: "profile", environment: [
            "profile": #"{"architecture":"arm64","display":{"scale":2}}"#,
        ])
        XCTAssertEqual(profile["architecture"] as? String, "arm64")
        XCTAssertEqual(
            try VisualE2EConfiguration.stringArray(named: "cases", environment: ["cases": #"["example"]"#]),
            ["example"]
        )
        XCTAssertThrowsError(
            try VisualE2EConfiguration.jsonObject(named: "profile", environment: [
                "profile": "[]",
            ])
        )
    }

    private func png(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        guard let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ) else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }
        image.setColor(NSColor(red: red, green: green, blue: blue, alpha: 1), atX: 0, y: 0)
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }
        return png
    }
}
