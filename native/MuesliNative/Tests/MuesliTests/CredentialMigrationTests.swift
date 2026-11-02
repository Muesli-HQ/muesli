import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Credential migration")
struct CredentialMigrationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("credential-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func migratesAllConfigSecretsAndHydratesRestart() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        var legacy = AppConfig()
        legacy.openAIAPIKey = "synthetic-openai"
        legacy.anthropicAPIKey = "synthetic-anthropic"
        legacy.customLLMAPIKey = "synthetic-custom"
        legacy.customLLMAPIKeyCommand = "synthetic-command"
        legacy.customLLMHeaders = [.init(name: "Authorization", value: "synthetic-header")]
        let path = root.appendingPathComponent("config.json")
        try JSONEncoder().encode(legacy).write(to: path)
        let store = ConfigStore(supportDirectory: root, vault: vault)
        let loaded = store.load()
        #expect(loaded.openAIAPIKey == legacy.openAIAPIKey)
        #expect(store.credentialStorageError == nil)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: path))
        #expect(persisted.openAIAPIKey.isEmpty && persisted.anthropicAPIKey.isEmpty && persisted.customLLMAPIKey.isEmpty)
        #expect(persisted.customLLMAPIKeyCommand.isEmpty && persisted.customLLMHeaders.isEmpty)
        let restarted = ConfigStore(supportDirectory: root, vault: vault).load()
        #expect(restarted.openAIAPIKey == legacy.openAIAPIKey)
        #expect(restarted.anthropicAPIKey == legacy.anthropicAPIKey)
        #expect(restarted.customLLMHeaders.map(\.name) == legacy.customLLMHeaders.map(\.name))
        #expect(restarted.customLLMHeaders.map(\.value) == legacy.customLLMHeaders.map(\.value))
        #expect(restarted.customLLMAPIKeyCommand == legacy.customLLMAPIKeyCommand)
    }

    @Test func failedMigrationRetainsOnlyWorkingCopyAndRejectsNewPlaintextWrites() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault(); vault.failWrites = true
        var legacy = AppConfig(); legacy.openAIAPIKey = "synthetic-original"
        let path = root.appendingPathComponent("config.json")
        let data = try JSONEncoder().encode(legacy); try data.write(to: path)
        let store = ConfigStore(supportDirectory: root, vault: vault)
        var loaded = store.load()
        #expect(loaded.openAIAPIKey == legacy.openAIAPIKey)
        #expect(store.credentialStorageError != nil)
        loaded.openAIAPIKey = "synthetic-new"
        #expect(!store.save(loaded))
        #expect(try Data(contentsOf: path) == data)
        vault.failWrites = false
        #expect(store.save(loaded))
        #expect(ConfigStore(supportDirectory: root, vault: vault).load().openAIAPIKey == loaded.openAIAPIKey)
    }

    @Test func currentVaultWinsOverStaleConfigAndClearingPersists() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault(); var secret = ConfigCredentials(); secret.openAI = "synthetic-newer"
        try vault.write(JSONEncoder().encode(secret), account: ConfigCredentials.account)
        var legacy = AppConfig(); legacy.openAIAPIKey = "synthetic-stale"
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("config.json"))
        let store = ConfigStore(supportDirectory: root, vault: vault)
        var loaded = store.load(); #expect(loaded.openAIAPIKey == secret.openAI)
        loaded.openAIAPIKey = ""; #expect(store.save(loaded))
        #expect(try vault.read(ConfigCredentials.account) == nil)
        #expect(ConfigStore(supportDirectory: root, vault: vault).load().openAIAPIKey.isEmpty)
    }

    @Test func fileMigrationVerifiesBeforeDeletingAndRetries() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault(); let path = root.appendingPathComponent("auth.json")
        let data = Data("synthetic-token".utf8); try data.write(to: path)
        let storage = CredentialFileMigration(legacyURL: path, account: "fixture", vault: vault)
        vault.failWrites = true
        #expect(try storage.load() == data)
        #expect(FileManager.default.fileExists(atPath: path.path))
        vault.failWrites = false
        #expect(try storage.load() == data)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try vault.read("fixture") == data)
        vault.failDeletes = true
        #expect(throws: CredentialVaultError.self) { try storage.delete() }
        #expect(try storage.load() == data)
        vault.failDeletes = false; try storage.delete()
        #expect(try storage.load() == nil)
    }

    @Test func malformedVaultDoesNotRemoveReadableLegacyFile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let store = OpenRouterCredentialStore(supportDirectory: root, vault: vault)
        let old = OpenRouterCredential(apiKey: "synthetic-readable", userID: nil)
        try JSONEncoder().encode(old).write(to: store.fileURL)
        try vault.write(Data("invalid".utf8), account: "openrouter-auth")
        #expect(try store.load() == old)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func namespacesAreStableAndSeparateAcrossLanes() {
        let production = URL(fileURLWithPath: "/synthetic/Muesli")
        #expect(KeychainCredentialVault(supportDirectory: production).service == KeychainCredentialVault(supportDirectory: production).service)
        #expect(KeychainCredentialVault(supportDirectory: production).service != KeychainCredentialVault(supportDirectory: URL(fileURLWithPath: "/synthetic/MuesliDevA")).service)
    }
    @Test @MainActor func oauthFilesMigrateWithoutReauthenticationAndSignOutFailsHonestly() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "account_id": "synthetic-account", "expires_at": "9999999999999"])
        for name in ["chatgpt-auth", "google-calendar-auth"] { try data.write(to: root.appendingPathComponent(name + ".json")) }
        let chatGPT = ChatGPTAuthManager(supportDirectory: root, vault: vault)
        let google = GoogleCalendarAuthManager(supportDirectory: root, vault: vault)
        #expect(chatGPT.isAuthenticated)
        #expect(google.isAuthenticated)
        #expect(try await chatGPT.validAccessToken().token == "synthetic-access")
        for name in ["chatgpt-auth", "google-calendar-auth"] {
            #expect(try vault.read(name) == data)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".json").path))
        }
        vault.failDeletes = true
        #expect(throws: CredentialVaultError.self) { try chatGPT.signOut() }
        #expect(chatGPT.isAuthenticated)
        vault.failDeletes = false
        try chatGPT.signOut(); try google.signOut()
        #expect(!chatGPT.isAuthenticated && !google.isAuthenticated)
    }

}
