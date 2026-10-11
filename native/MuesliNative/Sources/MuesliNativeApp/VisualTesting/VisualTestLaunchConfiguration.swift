import Foundation

/// Debug-only launch contract for the non-shipping visual test host. The
/// sentinel argument is intentionally all-or-nothing: an invalid fixture
/// launch must terminate before normal startup can touch a user's profile.
enum VisualTestLaunchConfiguration {
    static let launchArgument = "--muesli-visual-test"
    static let scenarioArgument = "--visual-scenario"
    static let hostBundleIdentifier = "com.muesli.visual-test-host"
    static let hostPlistKey = "MuesliVisualTestHost"

    let scenario: VisualScenario
    let paths: VisualFixturePaths

    static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> VisualTestLaunchConfiguration? {
        #if DEBUG
        guard arguments.contains(launchArgument) else { return nil }

        guard bundle.bundleIdentifier == hostBundleIdentifier,
              bundle.object(forInfoDictionaryKey: hostPlistKey) as? Bool == true else {
            throw VisualTestLaunchError.unauthorizedHost(
                bundleID: bundle.bundleIdentifier,
                hasHostFlag: bundle.object(forInfoDictionaryKey: hostPlistKey) as? Bool == true
            )
        }
        guard let flagIndex = arguments.firstIndex(of: scenarioArgument),
              arguments.indices.contains(flagIndex + 1),
              !arguments[flagIndex + 1].hasPrefix("--") else {
            throw VisualTestLaunchError.missingScenarioArgument
        }
        guard arguments.filter({ $0 == scenarioArgument }).count == 1 else {
            throw VisualTestLaunchError.duplicateScenarioArgument
        }

        let paths = try VisualFixturePaths(environment: environment)
        let manifest = try VisualScenarioManifest.load(from: paths.manifestURL)
        let id = arguments[flagIndex + 1]
        guard let scenario = manifest.scenario(id: id) else {
            throw VisualScenarioError.unknownScenario(id)
        }
        return VisualTestLaunchConfiguration(scenario: scenario, paths: paths)
        #else
        return nil
        #endif
    }
}

enum VisualTestLaunchError: LocalizedError, Equatable {
    case unauthorizedHost(bundleID: String?, hasHostFlag: Bool)
    case missingScenarioArgument
    case duplicateScenarioArgument

    var errorDescription: String? {
        switch self {
        case .unauthorizedHost:
            "Visual fixture mode is restricted to the dedicated Debug visual-test host."
        case .missingScenarioArgument:
            "Visual fixture mode requires --visual-scenario <scenario-id>."
        case .duplicateScenarioArgument:
            "Visual fixture mode accepts exactly one --visual-scenario argument."
        }
    }
}
