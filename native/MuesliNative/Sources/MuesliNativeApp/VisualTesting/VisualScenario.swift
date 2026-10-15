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
        guard identifiers.allSatisfy(Self.isSafeScenarioID), Set(identifiers).count == identifiers.count else {
            throw VisualScenarioError.invalidScenarioIdentifiers
        }
        for scenario in manifest.scenarios {
            guard scenario.size.width > 0,
                  scenario.size.height > 0,
                  scenario.scale > 0,
                  scenario.tolerance.maximumDifferentPixelRatio.isFinite,
                  (0...1).contains(scenario.tolerance.maximumDifferentPixelRatio),
                  !scenario.size.width.multipliedReportingOverflow(by: scenario.scale).overflow,
                  !scenario.size.height.multipliedReportingOverflow(by: scenario.scale).overflow else {
                throw VisualScenarioError.invalidScenarioMetrics(scenario.id)
            }
        }
        return manifest
    }

    static func isSafeScenarioID(_ identifier: String) -> Bool {
        guard let first = identifier.utf8.first, first.isASCIIAlphaNumeric else { return false }
        return identifier.utf8.allSatisfy { $0.isASCIIAlphaNumeric || $0 == 45 || $0 == 95 }
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
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
        let (width, widthOverflow) = size.width.multipliedReportingOverflow(by: scale)
        let (height, heightOverflow) = size.height.multipliedReportingOverflow(by: scale)
        precondition(!widthOverflow && !heightOverflow, "Validated visual scenario dimensions must not overflow.")
        return VisualPixelSize(width: width, height: height)
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
    case invalidScenarioMetrics(String)
    case unknownScenario(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedManifestVersion(let version):
            "Unsupported visual fixture manifest version \(version)."
        case .emptyManifest:
            "Visual fixture manifest contains no scenarios."
        case .invalidScenarioIdentifiers:
            "Visual fixture scenario identifiers must be unique ASCII letters, digits, hyphens, or underscores."
        case .invalidScenarioMetrics(let id):
            "Visual fixture scenario \(id) has invalid dimensions, scale, or tolerance."
        case .unknownScenario(let id):
            "Unknown visual fixture scenario \(id)."
        }
    }
}
