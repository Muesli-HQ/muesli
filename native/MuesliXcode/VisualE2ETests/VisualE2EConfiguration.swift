import Foundation

enum VisualE2EConfigurationError: LocalizedError {
    case missingEnvironment(String)
    case invalidAbsolutePath(String)
    case invalidArtifactDirectory(String)
    case invalidCaseIdentifier(String)
    case emptyScreenshot
    case unreadableScreenshot

    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let name):
            return "Missing required visual E2E environment variable: \(name)."
        case .invalidAbsolutePath(let path):
            return "Visual E2E paths must be absolute: \(path)."
        case .invalidArtifactDirectory(let path):
            return "Visual E2E artifact directory must be an absolute file URL: \(path)."
        case .invalidCaseIdentifier(let identifier):
            return "Visual E2E case identifiers may only contain letters, numbers, dots, underscores, and hyphens: \(identifier)."
        case .emptyScreenshot:
            return "The identified window produced an empty screenshot."
        case .unreadableScreenshot:
            return "The captured window PNG could not be decoded."
        }
    }
}

struct VisualE2EConfiguration {
    static let hostBundleIdentifier = "com.muesli.visual-test-host"

    let caseID: String
    let scenarioID: String
    let fixturesDirectory: URL
    let dataDirectory: URL
    let artifactsDirectory: URL
    let windowIdentifier: String

    var caseArtifactsDirectory: URL {
        artifactsDirectory.appendingPathComponent(caseID, isDirectory: true)
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let scenarioID = try required("MUESLI_VISUAL_SCENARIO_ID", environment: environment)
        let fixturesDirectory = try absoluteDirectory("MUESLI_VISUAL_FIXTURE_DIR", environment: environment)
        let dataDirectory = try absoluteDirectory("MUESLI_VISUAL_DATA_DIR", environment: environment)
        let artifactsDirectory = try absoluteDirectory("MUESLI_VISUAL_ARTIFACT_DIR", environment: environment)
        let windowIdentifier = try required("MUESLI_VISUAL_WINDOW_ID", environment: environment)

        guard scenarioID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            throw VisualE2EConfigurationError.invalidCaseIdentifier(scenarioID)
        }

        return Self(
            caseID: scenarioID,
            scenarioID: scenarioID,
            fixturesDirectory: fixturesDirectory,
            dataDirectory: dataDirectory,
            artifactsDirectory: artifactsDirectory,
            windowIdentifier: windowIdentifier
        )
    }

    var launchArguments: [String] {
        [
            "--muesli-visual-test",
            "--visual-scenario", scenarioID,
            "--visual-fixtures", fixturesDirectory.path,
            "--visual-data-root", dataDirectory.path,
            "--visual-artifacts", artifactsDirectory.path,
        ]
    }

    private static func required(_ name: String, environment: [String: String]) throws -> String {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw VisualE2EConfigurationError.missingEnvironment(name)
        }
        return value
    }

    private static func absoluteDirectory(_ name: String, environment: [String: String]) throws -> URL {
        let path = try required(name, environment: environment)
        guard path.hasPrefix("/") else {
            throw VisualE2EConfigurationError.invalidAbsolutePath(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
