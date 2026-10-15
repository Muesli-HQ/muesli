import AppKit
import Foundation

struct VisualE2EArtifactExporter {
    struct Metadata: Encodable {
        let schemaVersion = 1
        let caseID: String
        let suite = "e2e"
        let scenarioID: String
        let windowIdentifier: String
        let captureBounds: CaptureBounds
        let pixelWidth: Int
        let pixelHeight: Int
        let pngByteCount: Int

        struct CaptureBounds: Encodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }
    }

    let directory: URL

    init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw VisualE2EConfigurationError.invalidArtifactDirectory(directory.path)
        }
        self.directory = directory
    }

    func export(
        png: Data,
        caseID: String,
        scenarioID: String,
        windowIdentifier: String,
        windowFrame: CGRect
    ) throws {
        guard !png.isEmpty else {
            throw VisualE2EConfigurationError.emptyScreenshot
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("actual.png"), options: .atomic)

        let pixelSize = try VisualE2EImageComparator.pixelSize(of: png)
        let metadata = Metadata(
            caseID: caseID,
            scenarioID: scenarioID,
            windowIdentifier: windowIdentifier,
            captureBounds: .init(
                x: windowFrame.origin.x,
                y: windowFrame.origin.y,
                width: windowFrame.width,
                height: windowFrame.height
            ),
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            pngByteCount: png.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent("metadata.json"),
            options: .atomic
        )
    }
}

enum VisualE2EComparisonStatus: String {
    case matched
    case changed
    case missingBaseline = "missing_baseline"
}

struct VisualE2EComparison {
    let status: VisualE2EComparisonStatus
    let expectedURL: URL?
    let diffURL: URL?
}

/// Strict, fixed-profile PNG comparison for E2E captures. A missing trusted
/// reference is advisory; malformed images remain a harness error by throwing.
struct VisualE2EImageComparator {
    private struct Raster: Equatable {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    static func compare(
        actualPNG: Data,
        baselineURL: URL,
        artifactDirectory: URL
    ) throws -> VisualE2EComparison {
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            return VisualE2EComparison(status: .missingBaseline, expectedURL: nil, diffURL: nil)
        }

        let expectedPNG = try Data(contentsOf: baselineURL)
        let actual = try raster(of: actualPNG)
        let expected = try raster(of: expectedPNG)
        let expectedURL = artifactDirectory.appendingPathComponent("expected.png")
        try expectedPNG.write(to: expectedURL, options: .atomic)

        guard actual.width == expected.width, actual.height == expected.height,
              actual.rgba == expected.rgba else {
            let diffURL = artifactDirectory.appendingPathComponent("diff.png")
            try diffPNG(actual: actual, expected: expected).write(to: diffURL, options: .atomic)
            return VisualE2EComparison(status: .changed, expectedURL: expectedURL, diffURL: diffURL)
        }
        return VisualE2EComparison(status: .matched, expectedURL: expectedURL, diffURL: nil)
    }

    static func pixelSize(of png: Data) throws -> (width: Int, height: Int) {
        let image = try raster(of: png)
        return (image.width, image.height)
    }

    private static func raster(of png: Data) throws -> Raster {
        guard let image = NSImage(data: png),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }

        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drewImage = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drewImage else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }
        return Raster(width: width, height: height, rgba: rgba)
    }

    private static func diffPNG(actual: Raster, expected: Raster) throws -> Data {
        let width = max(actual.width, expected.width)
        let height = max(actual.height, expected.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let outputOffset = (y * width + x) * 4
                let actualPixel = pixel(atX: x, y: y, in: actual)
                let expectedPixel = pixel(atX: x, y: y, in: expected)
                switch (actualPixel, expectedPixel) {
                case let (actual?, expected?) where actual == expected:
                    continue
                case (.some, .some):
                    pixels[outputOffset] = 255
                    pixels[outputOffset + 3] = 255
                case (.some, nil):
                    pixels[outputOffset + 2] = 255
                    pixels[outputOffset + 3] = 255
                case (nil, .some):
                    pixels[outputOffset + 1] = 255
                    pixels[outputOffset + 3] = 255
                case (nil, nil):
                    continue
                }
            }
        }

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let destination = representation.bitmapData else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }
        pixels.withUnsafeBufferPointer { source in
            destination.assign(from: source.baseAddress!, count: pixels.count)
        }
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }
        return png
    }

    private static func pixel(atX x: Int, y: Int, in raster: Raster) -> ArraySlice<UInt8>? {
        guard x < raster.width, y < raster.height else { return nil }
        let offset = (y * raster.width + x) * 4
        return raster.rgba[offset..<(offset + 4)]
    }
}

struct VisualE2EResultWriter {
    /// Writes the advisory suite result consumed by the repository reporter.
    /// `MUESLI_VISUAL_RENDERER_PROFILE_JSON` comes from the trusted runner's exact
    /// post-preflight observation, not from the app-under-test.
    static func writeCaptureResult(
        configuration: VisualE2EConfiguration,
        comparison: VisualE2EComparison,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let resultPath = environment["MUESLI_UI_RENDERING_RESULT"], resultPath.hasPrefix("/") else {
            throw VisualE2EConfigurationError.missingEnvironment("MUESLI_UI_RENDERING_RESULT")
        }

        let resultURL = URL(fileURLWithPath: resultPath)
        let reportDirectory = resultURL.deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL
        var artifacts = ["actual": try relativeArtifactPath(
            configuration.caseArtifactsDirectory.appendingPathComponent("actual.png"),
            reportDirectory: reportDirectory
        )]
        if let expectedURL = comparison.expectedURL {
            artifacts["expected"] = try relativeArtifactPath(expectedURL, reportDirectory: reportDirectory)
        }
        if let diffURL = comparison.diffURL {
            artifacts["diff"] = try relativeArtifactPath(diffURL, reportDirectory: reportDirectory)
        }

        let expectedCases = try VisualE2EConfiguration.stringArray(
            named: "MUESLI_VISUAL_EXPECTED_CASES_JSON",
            environment: environment
        )
        guard expectedCases == [configuration.caseID] else {
            throw VisualE2EConfigurationError.invalidJSONEnvironment("MUESLI_VISUAL_EXPECTED_CASES_JSON")
        }
        let document: [String: Any] = [
            "schema_version": 1,
            "suite": "e2e",
            "status": "completed",
            "renderer_profile": try VisualE2EConfiguration.jsonObject(
                named: "MUESLI_VISUAL_RENDERER_PROFILE_JSON",
                environment: environment
            ),
            "baseline_provenance": try VisualE2EConfiguration.jsonObject(
                named: "MUESLI_VISUAL_BASELINE_PROVENANCE_JSON",
                environment: environment
            ),
            "expected_cases": expectedCases,
            "cases": [[
                "id": configuration.caseID,
                "status": comparison.status.rawValue,
                "artifacts": artifacts,
            ]],
        ]
        guard JSONSerialization.isValidJSONObject(document) else {
            throw VisualE2EConfigurationError.invalidJSONEnvironment("MUESLI_VISUAL_RENDERER_PROFILE_JSON")
        }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: resultURL, options: .atomic)
    }

    static func relativeArtifactPath(_ artifactURL: URL, reportDirectory: URL) throws -> String {
        let artifact = artifactURL.standardizedFileURL.path
        let root = reportDirectory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard artifact.hasPrefix(prefix) else {
            throw VisualE2EConfigurationError.invalidArtifactDirectory(artifact)
        }
        return String(artifact.dropFirst(prefix.count))
    }
}
