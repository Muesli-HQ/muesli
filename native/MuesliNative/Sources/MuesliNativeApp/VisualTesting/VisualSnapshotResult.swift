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
              actual.bitsPerPixel == expected.bitsPerPixel,
              actual.bitsPerPixel.isMultiple(of: 8) else {
            return VisualSnapshotResult(
                scenario: scenario,
                status: .incompatibleEnvironment,
                actualPixelSize: actualPixelSize,
                detail: "Baseline pixel dimensions or bitmap layout differs from the capture."
            )
        }

        var changedPixels = 0
        let bytesPerPixel = actual.bitsPerPixel / 8
        let comparedBytesPerRow = actual.pixelsWide * bytesPerPixel
        guard actual.bytesPerRow >= comparedBytesPerRow else {
            return VisualSnapshotResult(
                scenario: scenario,
                status: .incompatibleEnvironment,
                actualPixelSize: actualPixelSize,
                detail: "Bitmap rows are shorter than their declared pixel width."
            )
        }
        for row in 0..<actual.pixelsHigh {
            let rowOffset = row * actual.bytesPerRow
            for offset in stride(from: 0, to: comparedBytesPerRow, by: bytesPerPixel) {
                if memcmp(actualBytes.advanced(by: rowOffset + offset), expectedBytes.advanced(by: rowOffset + offset), bytesPerPixel) != 0 {
                    changedPixels += 1
                }
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

    static func differencePNG(actualPNG: Data, baselineURL: URL) throws -> Data {
        guard let actual = NSBitmapImageRep(data: actualPNG),
              let expected = NSBitmapImageRep(contentsOf: baselineURL),
              actual.pixelsWide == expected.pixelsWide,
              actual.pixelsHigh == expected.pixelsHigh,
              actual.bitsPerPixel == expected.bitsPerPixel,
              actual.bitsPerPixel.isMultiple(of: 8),
              let actualBytes = actual.bitmapData,
              let expectedBytes = expected.bitmapData,
              let difference = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: actual.pixelsWide,
                  pixelsHigh: actual.pixelsHigh,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bitmapFormat: .alphaNonpremultiplied,
                  bytesPerRow: actual.pixelsWide * 4,
                  bitsPerPixel: 32
              ),
              let differenceBytes = difference.bitmapData else {
            throw VisualSnapshotDifferenceError.incompatibleImages
        }

        let bytesPerPixel = actual.bitsPerPixel / 8
        let comparedBytesPerRow = actual.pixelsWide * bytesPerPixel
        guard actual.bytesPerRow >= comparedBytesPerRow,
              expected.bytesPerRow >= comparedBytesPerRow else {
            throw VisualSnapshotDifferenceError.incompatibleImages
        }
        for row in 0..<actual.pixelsHigh {
            for column in 0..<actual.pixelsWide {
                let sourceOffset = row * actual.bytesPerRow + column * bytesPerPixel
                if memcmp(
                    actualBytes.advanced(by: sourceOffset),
                    expectedBytes.advanced(by: row * expected.bytesPerRow + column * bytesPerPixel),
                    bytesPerPixel
                ) != 0 {
                    let outputOffset = row * difference.bytesPerRow + column * 4
                    differenceBytes[outputOffset] = 255
                    differenceBytes[outputOffset + 3] = 255
                }
            }
        }
        guard let png = difference.representation(using: .png, properties: [:]) else {
            throw VisualSnapshotDifferenceError.encodingFailed
        }
        return png
    }
}

enum VisualSnapshotDifferenceError: LocalizedError {
    case incompatibleImages
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .incompatibleImages:
            "The visual snapshot and baseline cannot produce a pixel diff."
        case .encodingFailed:
            "AppKit could not encode the visual snapshot diff."
        }
    }
}
