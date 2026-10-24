import Foundation
import MuesliCore

/// Seeds a fresh runner-owned support directory through the production storage
/// APIs. No user database, credentials, recordings, or copied data are read.
struct VisualFixtureSeeder {
    private struct Seed: Codable {
        let version: Int
        let dictations: [Dictation]
    }

    private struct Dictation: Codable {
        let text: String
        let appContext: String
        let startedAt: Date
        let endedAt: Date
    }

    let paths: VisualFixturePaths

    func seedIfNeeded() throws {
        let marker = paths.dataDirectory.appendingPathComponent("fixture-seed-v1.complete")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let seed = try decoder.decode(Seed.self, from: Data(contentsOf: paths.seedURL))
        guard seed.version == VisualScenarioManifest.currentVersion else {
            throw VisualScenarioError.unsupportedManifestVersion(seed.version)
        }

        let configStore = ConfigStore(supportDirectory: paths.dataDirectory)
        // Saving a default config creates the isolated config through the same
        // code path as the app without triggering a credential migration.
        configStore.save(AppConfig())

        let store = DictationStore(databaseURL: paths.databaseURL)
        try store.migrateIfNeeded()
        for dictation in seed.dictations {
            try store.insertDictation(
                text: dictation.text,
                durationSeconds: dictation.endedAt.timeIntervalSince(dictation.startedAt),
                appContext: dictation.appContext,
                startedAt: dictation.startedAt,
                endedAt: dictation.endedAt
            )
        }
        try Data("seeded\n".utf8).write(to: marker, options: .atomic)
    }
}
