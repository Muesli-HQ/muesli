import Foundation
import MuesliCore

final class ConfigStore {
    private let configURL: URL
    private let openRouterCredentialStore: OpenRouterCredentialStore
    let credentialVault: any CredentialVault
    private var savedCredentials: ConfigCredentials?
    private(set) var credentialStorageError: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(supportDirectory: URL = AppIdentity.supportDirectoryURL, vault: (any CredentialVault)? = nil) {
        let vault = vault ?? KeychainCredentialVault(supportDirectory: supportDirectory)
        self.credentialVault = vault
        self.configURL = supportDirectory.appendingPathComponent("config.json")
        self.openRouterCredentialStore = OpenRouterCredentialStore(supportDirectory: supportDirectory, vault: vault)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppConfig {
        ensureDirectory()
        // A failed reload must not leave an earlier credential snapshot trusted
        // while the caller receives a sanitized configuration without those keys.
        savedCredentials = nil
        let data = try? Data(contentsOf: configURL)
        var config = data.flatMap { try? decoder.decode(AppConfig.self, from: $0) } ?? AppConfig()
        let hadLegacyOpenRouterKey = !config.openRouterAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        migrateLegacyOpenRouterCredential(in: &config)
        let legacy = credentials(in: config)
        do {
            guard config.openRouterAPIKey.isEmpty else { throw CredentialVaultError.unavailable }
            if let data = try credentialVault.read(ConfigCredentials.account) {
                let stored = try decoder.decode(ConfigCredentials.self, from: data)
                apply(stored, to: &config)
                savedCredentials = stored
                if !legacy.isEmpty || hadLegacyOpenRouterKey { try writeSanitized(config) }
            } else if !legacy.isEmpty {
                try storeCredentials(legacy)
                try writeSanitized(config)
            } else if hadLegacyOpenRouterKey, config.openRouterAPIKey.isEmpty {
                try writeSanitized(config)
            }
            credentialStorageError = nil
        } catch {
            // Migration failure preserves the existing file and in-memory keys.
            credentialStorageError = CredentialVaultError.unavailable.localizedDescription
        }
        return config
    }

    @discardableResult
    func save(_ config: AppConfig) -> Bool {
        ensureDirectory()
        var persistedConfig = config
        migrateLegacyOpenRouterCredential(in: &persistedConfig)
        do {
            try storeCredentials(credentials(in: persistedConfig))
            // Never write a new credential to plaintext after migration is introduced.
            guard persistedConfig.openRouterAPIKey.isEmpty else { throw CredentialVaultError.unavailable }
        } catch {
            credentialStorageError = "Changes could not be saved. " + CredentialVaultError.unavailable.localizedDescription
            return false
        }
        do {
            try writeSanitized(persistedConfig)
            credentialStorageError = nil
            return true
        } catch {
            credentialStorageError = "Changes could not be saved to config.json. " + error.localizedDescription
            return false
        }
    }

    private func storeCredentials(_ value: ConfigCredentials) throws {
        if savedCredentials == nil {
            // An unread item is not an empty item. Only initialize a new store
            // after confirming absence; an existing item requires load() to
            // hydrate the caller's config before it can be replaced or cleared.
            guard try credentialVault.read(ConfigCredentials.account) == nil else {
                throw CredentialVaultError.unavailable
            }
            savedCredentials = ConfigCredentials()
        }
        guard savedCredentials != value else { return }
        if value.isEmpty {
            try credentialVault.remove(ConfigCredentials.account)
        } else {
            let data = try encoder.encode(value)
            try credentialVault.write(data, account: ConfigCredentials.account)
            guard try credentialVault.read(ConfigCredentials.account) == data else { throw CredentialVaultError.verificationFailed }
        }
        savedCredentials = value
    }

    private func credentials(in config: AppConfig) -> ConfigCredentials {
        var value = ConfigCredentials()
        value.openAI = config.openAIAPIKey; value.anthropic = config.anthropicAPIKey
        value.custom = config.customLLMAPIKey; value.customCommand = config.customLLMAPIKeyCommand
        value.customHeaders = config.customLLMHeaders
        return value
    }

    private func apply(_ value: ConfigCredentials, to config: inout AppConfig) {
        config.openAIAPIKey = value.openAI; config.anthropicAPIKey = value.anthropic
        config.customLLMAPIKey = value.custom; config.customLLMAPIKeyCommand = value.customCommand
        config.customLLMHeaders = value.customHeaders
    }

    private func writeSanitized(_ config: AppConfig) throws {
        var sanitized = config
        apply(ConfigCredentials(), to: &sanitized)
        let data = try encoder.encode(sanitized)
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    /// Moves the legacy config.json key into the scoped Keychain item. If that write fails, keep the old value in config so
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
