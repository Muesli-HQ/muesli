import Foundation

/// A checked-in, versioned description of one deterministic rendering state.
/// New cases belong in `native/VisualTesting/Fixtures`, not in test source.
struct VisualScenarioManifest: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let fixedDate: Date
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let scenarios: [VisualScenario]

    func scenario(id: String) -> VisualScenario? {
        scenarios.first { $0.id == id }
    }

    static func load(from url: URL) throws -> VisualScenarioManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(VisualScenarioManifest.self, from: Data(contentsOf: url))
        guard manifest.version == currentVersion else {
            throw VisualScenarioError.unsupportedManifestVersion(manifest.version)
        }
        guard !manifest.scenarios.isEmpty else {
            throw VisualScenarioError.emptyManifest
        }
        let identifiers = manifest.scenarios.map(\.id)
        guard identifiers.allSatisfy({ !$0.isEmpty }), Set(identifiers).count == identifiers.count else {
            throw VisualScenarioError.invalidScenarioIdentifiers
        }
        return manifest
    }
}

struct VisualScenario: Codable, Equatable, Hashable, Sendable {
    let id: String
    let screen: VisualScenarioScreen
    let appearance: VisualAppearance
    let size: VisualSnapshotSize
    let scale: Int
    let tolerance: VisualTolerance

    var pixelSize: VisualPixelSize {
        VisualPixelSize(width: size.width * scale, height: size.height * scale)
    }
}

enum VisualScenarioScreen: String, Codable, Sendable {
    case notchInstructionPreview = "notch_instruction_preview"
    case liveInstruction = "live_instruction"
    case recordingIndicatorPicker = "recording_indicator_picker"
}

enum VisualAppearance: String, Codable, Sendable {
    case light
    case dark
}

struct VisualSnapshotSize: Codable, Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
}

struct VisualPixelSize: Codable, Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
}

struct VisualTolerance: Codable, Equatable, Hashable, Sendable {
    /// Starts strict. A case-specific, reviewed non-zero value is the only
    /// permitted future relaxation; the capture is never resized or blurred.
    let maximumDifferentPixelRatio: Double

    static let strict = VisualTolerance(maximumDifferentPixelRatio: 0)
}

enum VisualScenarioError: LocalizedError, Equatable {
    case unsupportedManifestVersion(Int)
    case emptyManifest
    case invalidScenarioIdentifiers
    case unknownScenario(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedManifestVersion(let version):
            "Unsupported visual fixture manifest version \(version)."
        case .emptyManifest:
            "Visual fixture manifest contains no scenarios."
        case .invalidScenarioIdentifiers:
            "Visual fixture scenario identifiers must be non-empty and unique."
        case .unknownScenario(let id):
            "Unknown visual fixture scenario \(id)."
        }
    }
}
