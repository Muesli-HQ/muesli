import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Visual fixture contract")
struct VisualFixtureContractTests {
    @Test("fixture launch requires exactly one scenario argument")
    func launchArgumentsAreStrict() throws {
        #expect(try VisualTestLaunchConfiguration.scenarioID(from: ["Muesli"]) == nil)
        #expect(try VisualTestLaunchConfiguration.scenarioID(from: [
            "Muesli", "--muesli-visual-test", "--visual-scenario", "safe-case",
        ]) == "safe-case")
        #expect(throws: VisualTestLaunchError.self) {
            try VisualTestLaunchConfiguration.scenarioID(from: [
                "Muesli", "--muesli-visual-test", "--muesli-visual-test", "--visual-scenario", "safe-case",
            ])
        }
        #expect(throws: VisualTestLaunchError.self) {
            try VisualTestLaunchConfiguration.scenarioID(from: ["Muesli", "--muesli-visual-test"])
        }
        #expect(throws: VisualTestLaunchError.self) {
            try VisualTestLaunchConfiguration.scenarioID(from: [
                "Muesli", "--muesli-visual-test", "--visual-scenario", "one", "--visual-scenario", "two",
            ])
        }
    }

    @Test("manifest rejects unsafe scenario IDs and dimensions")
    func manifestRejectsUnsafeFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = directory.appendingPathComponent("manifest.json")
        try """
        {
          "version": 1,
          "fixedDate": "2026-01-15T12:00:00Z",
          "localeIdentifier": "en_US",
          "timeZoneIdentifier": "UTC",
          "scenarios": [{
            "id": "../escape",
            "screen": "live_instruction",
            "appearance": "light",
            "size": { "width": 120, "height": 120 },
            "scale": 2,
            "tolerance": { "maximumDifferentPixelRatio": 0 }
          }]
        }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        #expect(throws: VisualScenarioError.self) {
            try VisualScenarioManifest.load(from: manifest)
        }

        try """
        {
          "version": 1,
          "fixedDate": "2026-01-15T12:00:00Z",
          "localeIdentifier": "en_US",
          "timeZoneIdentifier": "UTC",
          "scenarios": [{
            "id": "safe-case",
            "screen": "live_instruction",
            "appearance": "light",
            "size": { "width": 0, "height": 120 },
            "scale": 2,
            "tolerance": { "maximumDifferentPixelRatio": 0 }
          }]
        }
        """.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(throws: VisualScenarioError.self) {
            try VisualScenarioManifest.load(from: manifest)
        }
    }

    @Test("scenario artifacts cannot escape their runner-owned root")
    func childPathsStayUnderRoots() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixtures", isDirectory: true)
        let data = directory.appendingPathComponent("data", isDirectory: true)
        let artifacts = directory.appendingPathComponent("artifacts", isDirectory: true)
        try [fixture, data, artifacts].forEach { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }

        let paths = try VisualFixturePaths(environment: [
            VisualFixturePaths.fixtureDirectoryKey: fixture.path,
            VisualFixturePaths.dataDirectoryKey: data.path,
            VisualFixturePaths.artifactDirectoryKey: artifacts.path,
        ])
        let scenarioDirectory = try paths.artifactDirectory(forScenarioID: "safe_case-1")
        #expect(scenarioDirectory.path.hasPrefix(artifacts.path + "/"))
        #expect(throws: VisualFixturePathError.self) {
            try VisualFixturePaths.childURL(named: "../escape.png", under: artifacts)
        }
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: artifacts.appendingPathComponent("linked"), withDestinationURL: outside)
        #expect(throws: VisualFixturePathError.self) {
            try VisualFixturePaths.childURL(named: "linked", under: artifacts)
        }
    }

    @Test("missing baselines remain advisory")
    @MainActor
    func missingBaselineIsNotAComparisonFailure() throws {
        let scenario = VisualScenario(
            id: "safe-case",
            screen: .liveInstruction,
            appearance: .light,
            size: VisualSnapshotSize(width: 10, height: 10),
            scale: 1,
            tolerance: .strict
        )
        let result = try VisualSnapshotComparator.compare(
            scenario: scenario,
            actualPNG: Data(),
            baselineURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png"),
            actualPixelSize: scenario.pixelSize
        )
        #expect(result.status == .missingBaseline)
        let incompatible = try VisualSnapshotComparator.compare(
            scenario: scenario,
            actualPNG: Data(),
            baselineURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png"),
            actualPixelSize: VisualPixelSize(width: 9, height: 10)
        )
        #expect(incompatible.status == .incompatibleEnvironment)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
