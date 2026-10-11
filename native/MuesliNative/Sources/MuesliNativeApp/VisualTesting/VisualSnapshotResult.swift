import AppKit
import Darwin
import Foundation

/// These statuses are advisory visual findings. Harness failures are represented
/// separately so a runner can retain operational exit codes without treating a
/// visual change or an absent reference as a failed product test.
enum VisualSnapshotStatus: String, Codable, Equatable, Sendable {
    case matched
    case changed
    case missingBaseline = "missing_baseline"
    case incompatibleEnvironment = "incompatible_environment"
}

struct VisualSnapshotResult: Codable, Sendable {
    let version: Int
    let scenarioID: String
    let status: VisualSnapshotStatus
    let expectedPixelSize: VisualPixelSize
    let actualPixelSize: VisualPixelSize
    let differentPixelRatio: Double?
    let detail: String?

    init(
        scenario: VisualScenario,
        status: VisualSnapshotStatus,
        actualPixelSize: VisualPixelSize,
        differentPixelRatio: Double? = nil,
        detail: String? = nil
    ) {
        version = 1
        scenarioID = scenario.id
        self.status = status
        expectedPixelSize = scenario.pixelSize
        self.actualPixelSize = actualPixelSize
        self.differentPixelRatio = differentPixelRatio
        self.detail = detail
    }
}

@MainActor
enum VisualSnapshotComparator {
    static func compare(
        scenario: VisualScenario,
        actualPNG: Data,
        baselineURL: URL,
        actualPixelSize: VisualPixelSize
    ) throws -> VisualSnapshotResult {
        guard actualPixelSize == scenario.pixelSize else {
            return VisualSnapshotResult(
                scenario: scenario,
                status: .incompatibleEnvironment,
                actualPixelSize: actualPixelSize,
                detail: "Expected \(scenario.pixelSize.width)x\(scenario.pixelSize.height) pixels."
            )
        }
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            return VisualSnapshotResult(
                scenario: scenario,
                status: .missingBaseline,
                actualPixelSize: actualPixelSize,
                detail: "No trusted baseline is checked in for this renderer profile."
            )
        }
        guard let actual = NSBitmapImageRep(data: actualPNG),
              let expected = NSBitmapImageRep(contentsOf: baselineURL),
              actual.pixelsWide == expected.pixelsWide,
              actual.pixelsHigh == expected.pixelsHigh,
              let actualBytes = actual.bitmapData,
              let expectedBytes = expected.bitmapData,
              actual.bytesPerRow == expected.bytesPerRow,
              actual.bitsPerPixel == expected.bitsPerPixel else {
            return VisualSnapshotResult(
                scenario: scenario,
                status: .incompatibleEnvironment,
                actualPixelSize: actualPixelSize,
                detail: "Baseline pixel dimensions or bitmap layout differs from the capture."
            )
        }

        let byteCount = actual.bytesPerRow * actual.pixelsHigh
        var changedPixels = 0
        let bytesPerPixel = max(actual.bitsPerPixel / 8, 1)
        for offset in stride(from: 0, to: byteCount, by: bytesPerPixel) {
            if memcmp(actualBytes.advanced(by: offset), expectedBytes.advanced(by: offset), bytesPerPixel) != 0 {
                changedPixels += 1
            }
        }
        let totalPixels = max(actual.pixelsWide * actual.pixelsHigh, 1)
        let ratio = Double(changedPixels) / Double(totalPixels)
        return VisualSnapshotResult(
            scenario: scenario,
            status: ratio <= scenario.tolerance.maximumDifferentPixelRatio ? .matched : .changed,
            actualPixelSize: actualPixelSize,
            differentPixelRatio: ratio
        )
    }
}
