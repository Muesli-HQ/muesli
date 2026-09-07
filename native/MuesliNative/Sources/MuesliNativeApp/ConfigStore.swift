import Foundation
import MuesliCore

final class ConfigStore {
    private let configURL: URL
    private let openRouterCredentialStore: OpenRouterCredentialStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        self.configURL = supportDirectory.appendingPathComponent("config.json")
        self.openRouterCredentialStore = OpenRouterCredentialStore(supportDirectory: supportDirectory)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppConfig {
        ensureDirectory()
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        var config = (try? decoder.decode(AppConfig.self, from: data)) ?? AppConfig()
        let hadLegacyOpenRouterKey = !config.openRouterAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        migrateLegacyOpenRouterCredential(in: &config)
        if hadLegacyOpenRouterKey, config.openRouterAPIKey.isEmpty {
            write(config)
        }
        return config
    }

    func save(_ config: AppConfig) {
        ensureDirectory()
        var persistedConfig = config
        migrateLegacyOpenRouterCredential(in: &persistedConfig)
        write(persistedConfig)
    }

    private func write(_ config: AppConfig) {
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        } catch {
            fputs("[config-store] failed to save config: \(error)\n", stderr)
        }
    }

    /// Moves the legacy config.json key into the dedicated owner-only
    /// credential file. If that write fails, keep the old value in config so
    /// migration can retry without losing the user's credential.
    private func migrateLegacyOpenRouterCredential(in config: inout AppConfig) {
        let legacyKey = config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else { return }
        do {
            if let existingCredential = try openRouterCredentialStore.load(),
               !existingCredential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A dedicated credential may have been created after this stale
                // config value was written. Keep the newer destination value and
                // only remove the legacy duplicate from config.json.
                config.openRouterAPIKey = ""
                return
            }
            try openRouterCredentialStore.save(
                OpenRouterCredential(apiKey: legacyKey, userID: nil)
            )
            config.openRouterAPIKey = ""
        } catch {
            fputs("[config-store] failed to migrate OpenRouter credential\n", stderr)
        }
    }

    func configPath() -> URL {
        configURL
    }

    func supportDirectory() -> URL {
        configURL.deletingLastPathComponent()
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
