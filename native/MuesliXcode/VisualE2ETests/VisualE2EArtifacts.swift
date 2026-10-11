import AppKit
import Foundation
import XCTest

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
        screenshot: XCUIScreenshot,
        caseID: String,
        scenarioID: String,
        windowIdentifier: String,
        windowFrame: CGRect
    ) throws {
        let png = screenshot.pngRepresentation
        guard !png.isEmpty else {
            throw VisualE2EConfigurationError.emptyScreenshot
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("actual.png"), options: .atomic)

        let pixelSize = try Self.pixelSize(of: png)
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

    private static func pixelSize(of png: Data) throws -> (width: Int, height: Int) {
        guard
            let image = NSImage(data: png),
            let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
        else {
            throw VisualE2EConfigurationError.unreadableScreenshot
        }
        return (representation.pixelsWide, representation.pixelsHigh)
    }
}

struct VisualE2EResultWriter {
    private struct Result: Encodable {
        let schemaVersion = 1
        let suite = "e2e"
        let status = "completed"
        let rendererProfile: [String: String] = [:]
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case suite
            case status
            case rendererProfile = "renderer_profile"
            case cases
        }
    }

    private struct Case: Encodable {
        let id: String
        let status = "missing_baseline"
        let artifacts: [String: String]
    }

    /// Writes the narrow suite result consumed by the repository's advisory
    /// reporter. Image comparison can later replace `missing_baseline` with a
    /// reviewed baseline result without changing the capture path or test API.
    static func writeCaptureResult(
        configuration: VisualE2EConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let resultPath = environment["MUESLI_UI_RENDERING_RESULT"], resultPath.hasPrefix("/") else {
            throw VisualE2EConfigurationError.missingEnvironment("MUESLI_UI_RENDERING_RESULT")
        }

        let resultURL = URL(fileURLWithPath: resultPath)
        let reportDirectory = resultURL.deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL
        let actualURL = configuration.caseArtifactsDirectory.appendingPathComponent("actual.png")
            .standardizedFileURL
        let reportPrefix = reportDirectory.path.hasSuffix("/") ? reportDirectory.path : reportDirectory.path + "/"
        guard actualURL.path.hasPrefix(reportPrefix) else {
            throw VisualE2EConfigurationError.invalidArtifactDirectory(actualURL.path)
        }
        let actualPath = String(actualURL.path.dropFirst(reportPrefix.count))

        let result = Result(cases: [
            Case(id: configuration.caseID, artifacts: ["actual": actualPath]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(result).write(to: resultURL, options: .atomic)
    }
}
