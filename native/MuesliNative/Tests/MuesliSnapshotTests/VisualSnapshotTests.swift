import Foundation
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
            let caseDirectory = try paths.artifactDirectory(forScenarioID: scenario.id)
            try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
            try capture.pngData.write(
                to: try VisualFixturePaths.childURL(named: "actual.png", under: caseDirectory),
                options: .atomic
            )

            let result = try VisualSnapshotComparator.compare(
                scenario: scenario,
                actualPNG: capture.pngData,
                baselineURL: try VisualFixturePaths.childURL(named: "\(scenario.id).png", under: baselineRoot),
                actualPixelSize: capture.pixelSize
            )
            try encoder.encode(result).write(
                to: try VisualFixturePaths.childURL(named: "result.json", under: caseDirectory),
                options: .atomic
            )
            var artifacts = ["actual": "cases/snapshot/\(scenario.id)/actual.png"]
            if result.status == .matched || result.status == .changed {
                let expectedURL = try VisualFixturePaths.childURL(named: "expected.png", under: caseDirectory)
                try Data(contentsOf: try VisualFixturePaths.childURL(
                    named: "\(scenario.id).png",
                    under: baselineRoot
                )).write(to: expectedURL, options: .atomic)
                artifacts["expected"] = "cases/snapshot/\(scenario.id)/expected.png"
            }
            if result.status == .changed {
                let diff = try VisualSnapshotComparator.differencePNG(
                    actualPNG: capture.pngData,
                    baselineURL: try VisualFixturePaths.childURL(named: "\(scenario.id).png", under: baselineRoot)
                )
                try diff.write(
                    to: try VisualFixturePaths.childURL(named: "diff.png", under: caseDirectory),
                    options: .atomic
                )
                artifacts["diff"] = "cases/snapshot/\(scenario.id)/diff.png"
            }
            cases.append(.init(
                id: scenario.id,
                status: result.status.rawValue,
                artifacts: artifacts
            ))
            #expect(result.status != .incompatibleEnvironment)
        }

        if let resultPath = environment["MUESLI_UI_RENDERING_RESULT"] {
            try VisualSnapshotSuiteResult.write(
                cases: cases,
                environment: environment,
                to: URL(fileURLWithPath: resultPath)
            )
        }
    }
}

private enum VisualSnapshotSuiteResult {
    struct Case: Encodable {
        let id: String
        let status: String
        let artifacts: [String: String]
    }

    static func write(cases: [Case], environment: [String: String], to url: URL) throws {
        let profile = try jsonObject(
            environment["MUESLI_VISUAL_RENDERER_PROFILE_JSON"],
            key: "MUESLI_VISUAL_RENDERER_PROFILE_JSON"
        )
        let provenance = try jsonObject(
            environment["MUESLI_VISUAL_BASELINE_PROVENANCE_JSON"],
            key: "MUESLI_VISUAL_BASELINE_PROVENANCE_JSON"
        )
        guard let expectedData = environment["MUESLI_VISUAL_EXPECTED_CASES_JSON"]?.data(using: .utf8),
              let expectedCases = try JSONSerialization.jsonObject(with: expectedData) as? [String] else {
            throw VisualSnapshotTestError.invalidResultContract("MUESLI_VISUAL_EXPECTED_CASES_JSON")
        }
        guard cases.map(\.id) == expectedCases else {
            throw VisualSnapshotTestError.resultCasesDoNotMatchContract
        }

        let encodedCases = try JSONEncoder().encode(cases)
        guard let caseObjects = try JSONSerialization.jsonObject(with: encodedCases) as? [[String: Any]] else {
            throw VisualSnapshotTestError.invalidResultContract("encoded cases")
        }
        let document: [String: Any] = [
            "schema_version": 1,
            "suite": "snapshot",
            "status": "completed",
            "renderer_profile": profile,
            "baseline_provenance": provenance,
            "expected_cases": expectedCases,
            "cases": caseObjects,
        ]
        guard JSONSerialization.isValidJSONObject(document) else {
            throw VisualSnapshotTestError.invalidResultContract("suite result")
        }
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private static func jsonObject(_ value: String?, key: String) throws -> [String: Any] {
        guard let data = value?.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VisualSnapshotTestError.invalidResultContract(key)
        }
        return object
    }
}

enum VisualSnapshotTestError: LocalizedError {
    case missingBaselineDirectory
    case invalidResultContract(String)
    case resultCasesDoNotMatchContract

    var errorDescription: String? {
        switch self {
        case .missingBaselineDirectory:
            "MUESLI_VISUAL_BASELINE_DIR must be an absolute trusted baseline directory."
        case .invalidResultContract(let key):
            "Visual snapshot result requires a valid \(key) contract value."
        case .resultCasesDoNotMatchContract:
            "Visual snapshot manifest cases do not match the runner's expected-case contract."
        }
    }
}
