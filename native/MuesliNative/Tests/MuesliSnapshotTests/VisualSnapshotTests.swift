import Foundation
import SnapshotTesting
import Testing
@testable import MuesliNativeApp

@Suite("Opt-in AppKit visual snapshots", .serialized)
struct VisualSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_VISUAL_TESTS"] == "1"))
    @MainActor
    func capturesManifestScenariosAsAdvisoryResults() throws {
        let environment = ProcessInfo.processInfo.environment
        let paths = try VisualFixturePaths(environment: environment)
        let manifest = try VisualScenarioManifest.load(from: paths.manifestURL)
        try VisualFixtureSeeder(paths: paths).seedIfNeeded()

        guard let baselinePath = environment["MUESLI_VISUAL_BASELINE_DIR"], baselinePath.hasPrefix("/") else {
            throw VisualSnapshotTestError.missingBaselineDirectory
        }
        let baselineRoot = URL(fileURLWithPath: baselinePath, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var cases: [VisualSnapshotSuiteResult.Case] = []

        for scenario in manifest.scenarios {
            let capture = try VisualSnapshotCapture.capture(scenario: scenario)
            let caseDirectory = paths.artifactDirectory.appendingPathComponent(scenario.id)
            try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
            try capture.pngData.write(to: caseDirectory.appendingPathComponent("actual.png"), options: .atomic)

            let result = try VisualSnapshotComparator.compare(
                scenario: scenario,
                actualPNG: capture.pngData,
                baselineURL: baselineRoot.appendingPathComponent("\(scenario.id).png"),
                actualPixelSize: capture.pixelSize
            )
            try encoder.encode(result).write(
                to: caseDirectory.appendingPathComponent("result.json"),
                options: .atomic
            )
            cases.append(.init(
                id: scenario.id,
                status: result.status.rawValue,
                artifacts: ["actual": "cases/snapshot/\(scenario.id)/actual.png"]
            ))
            // The checked-in SnapshotTesting dependency is deliberately scoped
            // to this target. Its record mode is never enabled here: this test
            // only emits proposed artifacts for the trusted baseline workflow.
            #expect(result.status != .incompatibleEnvironment)
        }

        if let resultPath = environment["MUESLI_UI_RENDERING_RESULT"] {
            let suiteResult = VisualSnapshotSuiteResult(cases: cases)
            try encoder.encode(suiteResult).write(
                to: URL(fileURLWithPath: resultPath),
                options: .atomic
            )
        }
    }
}

private struct VisualSnapshotSuiteResult: Encodable {
    struct Case: Encodable {
        let id: String
        let status: String
        let artifacts: [String: String]
    }

    let schemaVersion = 1
    let suite = "snapshot"
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

enum VisualSnapshotTestError: LocalizedError {
    case missingBaselineDirectory

    var errorDescription: String? {
        "MUESLI_VISUAL_BASELINE_DIR must be an absolute trusted baseline directory."
    }
}
