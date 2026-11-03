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

    @Test(arguments: [false, true])
    func failedInitialReadCannotDeleteOrReplaceUnreadCredentials(replaceKey: Bool) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        var original = AppConfig()
        original.openAIAPIKey = "synthetic-openai"
        original.anthropicAPIKey = "synthetic-anthropic"
        original.customLLMAPIKeyCommand = "synthetic-command"
        original.customLLMHeaders = [.init(name: "Authorization", value: "synthetic-header")]
        #expect(ConfigStore(supportDirectory: root, vault: vault).save(original))
        let stored = try vault.read(ConfigCredentials.account)
        let path = root.appendingPathComponent("config.json")
        let persisted = try Data(contentsOf: path)
        let store = ConfigStore(supportDirectory: root, vault: vault)
        vault.failReads = true
        var unavailable = store.load()
        #expect(unavailable.openAIAPIKey.isEmpty)
        #expect(store.credentialStorageError != nil)

        // Unlocking alone does not hydrate the snapshot returned by the failed load.
        vault.failReads = false
        unavailable.openAIModel = "synthetic-model"
        if replaceKey { unavailable.openAIAPIKey = "synthetic-replacement" }
        #expect(!store.save(unavailable))
        #expect(store.credentialStorageError != nil)
        #expect(try vault.read(ConfigCredentials.account) == stored)
        #expect(try Data(contentsOf: path) == persisted)

        var hydrated = store.load()
        #expect(store.credentialStorageError == nil)
        #expect(hydrated.openAIAPIKey == original.openAIAPIKey)
        hydrated.openAIAPIKey = "synthetic-replacement"
        #expect(store.save(hydrated))
        let restarted = ConfigStore(supportDirectory: root, vault: vault).load()
        #expect(restarted.openAIAPIKey == hydrated.openAIAPIKey)
        #expect(restarted.anthropicAPIKey == original.anthropicAPIKey)
        #expect(restarted.customLLMAPIKeyCommand == original.customLLMAPIKeyCommand)
        #expect(restarted.customLLMHeaders.map(\.name) == original.customLLMHeaders.map(\.name))
        #expect(restarted.customLLMHeaders.map(\.value) == original.customLLMHeaders.map(\.value))
    }

    @Test func failedReloadInvalidatesPreviouslyHydratedSnapshot() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let store = ConfigStore(supportDirectory: root, vault: vault)
        var original = AppConfig(); original.openAIAPIKey = "synthetic-original"
        #expect(store.save(original))
        #expect(store.load().openAIAPIKey == original.openAIAPIKey)
        vault.failReads = true
        let unavailable = store.load()
        vault.failReads = false
        #expect(!store.save(unavailable))
        #expect(store.load().openAIAPIKey == original.openAIAPIKey)
    }

    @Test func observerReloadCannotAuthorizeStaleOwnerCredentialWrites() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        var original = AppConfig(); original.openAIAPIKey = "synthetic-original"
        #expect(ConfigStore(supportDirectory: root, vault: vault).save(original))
        let record = try vault.read(ConfigCredentials.account)
        let store = ConfigStore(supportDirectory: root, vault: vault)
        vault.failReads = true
        var owner = store.load()
        #expect(owner.openAIAPIKey.isEmpty)
        vault.failReads = false
        #expect(store.loadForReading().openAIAPIKey == original.openAIAPIKey)
        #expect(store.credentialStorageError != nil)
        owner.openAIModel = "synthetic-model"
        #expect(!store.save(owner))
        #expect(try vault.read(ConfigCredentials.account) == record)
        // Recovery is authorized only when the owner adopts the hydrated config.
        owner = store.load()
        owner.openAIModel = "synthetic-model"
        #expect(store.save(owner))
        #expect(store.loadForReading().openAIAPIKey == original.openAIAPIKey)
        vault.failReads = true
        _ = store.loadForReading()
        vault.failReads = false
        #expect(store.save(owner))
    }

    @Test func unavailableVaultPreservesLegacyUntilSuccessfulReload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        var legacy = AppConfig(); legacy.openAIAPIKey = "synthetic-legacy"
        let path = root.appendingPathComponent("config.json")
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: path)
        let store = ConfigStore(supportDirectory: root, vault: vault)
        vault.failReads = true
        let unavailable = store.load()
        #expect(unavailable.openAIAPIKey == legacy.openAIAPIKey)
        #expect(!store.save(unavailable))
        #expect(try Data(contentsOf: path) == original)
        vault.failReads = false
        #expect(store.load().openAIAPIKey == legacy.openAIAPIKey)
        #expect(store.credentialStorageError == nil)
        #expect(try vault.read(ConfigCredentials.account) != nil)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: path)).openAIAPIKey.isEmpty)
    }

    @Test func unhydratedSaveCannotOverwriteExistingOrMalformedCredentials() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let invalid = Data("synthetic-invalid-record".utf8)
        try vault.write(invalid, account: ConfigCredentials.account)
        let store = ConfigStore(supportDirectory: root, vault: vault)
        #expect(!store.save(AppConfig()))
        let unavailable = store.load()
        #expect(!store.save(unavailable))
        #expect(try vault.read(ConfigCredentials.account) == invalid)
    }

    @Test func configFileFailureIsReportedSeparatelyFromVaultFailureAndCanRetry() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let store = ConfigStore(supportDirectory: root, vault: vault)
        // A directory at the destination deterministically prevents the JSON write.
        try FileManager.default.createDirectory(at: store.configPath(), withIntermediateDirectories: true)
        var config = AppConfig(); config.openAIAPIKey = "synthetic-original"
        #expect(!store.save(config))
        let error = try #require(store.credentialStorageError)
        #expect(error.contains("config.json"))
        #expect(!error.contains("Keychain"))
        #expect(try vault.read(ConfigCredentials.account) != nil)
        try FileManager.default.removeItem(at: store.configPath())
        #expect(store.save(config))
        #expect(store.credentialStorageError == nil)
        #expect(store.load().openAIAPIKey == config.openAIAPIKey)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configPath())).openAIAPIKey.isEmpty)
    }

    @Test func failedOpenRouterMigrationDoesNotHideOtherStoredProviderCredentials() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        var stored = ConfigCredentials(); stored.openAI = "synthetic-openai"; stored.anthropic = "synthetic-anthropic"
        let record = try JSONEncoder().encode(stored)
        try vault.write(record, account: ConfigCredentials.account)
        var legacy = AppConfig(); legacy.openRouterAPIKey = "synthetic-openrouter"
        let original = try JSONEncoder().encode(legacy)
        let path = root.appendingPathComponent("config.json"); try original.write(to: path)
        vault.failingReadAccounts = ["openrouter-auth"]
        let store = ConfigStore(supportDirectory: root, vault: vault)
        let loaded = store.load()
        #expect(loaded.openAIAPIKey == stored.openAI)
        #expect(loaded.anthropicAPIKey == stored.anthropic)
        #expect(store.credentialStorageError != nil)
        #expect(!store.save(loaded))
        #expect(try vault.read(ConfigCredentials.account) == record)
        #expect(try Data(contentsOf: path) == original)
        vault.failingReadAccounts = []
        let recovered = store.load()
        #expect(recovered.openAIAPIKey == stored.openAI)
        #expect(recovered.openRouterAPIKey.isEmpty)
        #expect(store.credentialStorageError == nil)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: path)).openRouterAPIKey.isEmpty)
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

    @Test @MainActor func chatGPTDisplayStateDoesNotReadVaultAndRequestsUseOneFreshSnapshot() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let tokens = try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access", "account_id": "synthetic-account", "expires_at": "9999999999999"])
        try vault.write(tokens, account: "chatgpt-auth")
        let auth = ChatGPTAuthManager(supportDirectory: root, vault: vault)
        let reads = vault.readCallCount
        for _ in 0..<20 { #expect(auth.isAuthenticated) }
        #expect(vault.readCallCount == reads)
        #expect(try await auth.validAccessToken().token == "synthetic-access")
        #expect(vault.readCallCount == reads + 1)
        vault.failReads = true
        await #expect(throws: ChatGPTAuthError.self) { try await auth.validAccessToken() }
        vault.failReads = false
        vault.failDeletes = true
        #expect(throws: CredentialVaultError.self) { try auth.signOut() }
        #expect(auth.isAuthenticated)
        vault.failDeletes = false
        try auth.signOut()
        #expect(!auth.isAuthenticated)
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

    @Test(arguments: [false, true]) @MainActor
    func rotatedChatGPTSessionSurvivesFailedPersistenceAndCanSaveOrSignOut(signOut: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let original = try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-old", "refresh_token": "synthetic-old-refresh", "expires_at": "0"])
        try vault.write(original, account: "chatgpt-auth")
        var refreshes = 0
        let auth = ChatGPTAuthManager(supportDirectory: root, vault: vault, load: { request in
            refreshes += 1
            #expect(String(data: request.httpBody!, encoding: .utf8)?.contains("synthetic-old-refresh") == true)
            return (Data(#"{"access_token":"synthetic-new","refresh_token":"synthetic-rotated","expires_in":3600}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        vault.failWrites = true
        #expect(try await auth.validAccessToken().token == "synthetic-new")
        #expect(try vault.read("chatgpt-auth") == original)
        #expect(try await auth.validAccessToken().token == "synthetic-new")
        #expect(refreshes == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chatgpt-auth.json").path))
        if signOut {
            vault.failDeletes = true
            #expect(throws: CredentialVaultError.self) { try auth.signOut() }
            #expect(try await auth.validAccessToken().token == "synthetic-new")
            vault.failDeletes = false
            try auth.signOut()
            #expect(!auth.isAuthenticated)
            await #expect(throws: ChatGPTAuthError.self) { try await auth.validAccessToken() }
            #expect(try vault.read("chatgpt-auth") == nil)
        } else {
            vault.failWrites = false
            #expect(try await auth.validAccessToken().token == "synthetic-new")
            let saved = try #require(try vault.read("chatgpt-auth"))
            let tokens = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: String])
            #expect(tokens["refresh_token"] == "synthetic-rotated")
            let restarted = ChatGPTAuthManager(supportDirectory: root, vault: vault)
            #expect(try await restarted.validAccessToken().token == "synthetic-new")
        }
    }

    @Test @MainActor func refreshCompletionCannotResurrectSignedOutSession() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        try vault.write(JSONSerialization.data(withJSONObject: ["access_token": "synthetic-old", "refresh_token": "synthetic-refresh", "expires_at": "0"]), account: "chatgpt-auth")
        var auth: ChatGPTAuthManager!
        defer { auth = nil }
        auth = ChatGPTAuthManager(supportDirectory: root, vault: vault, load: { request in
            try auth.signOut()
            return (Data(#"{"access_token":"synthetic-late","refresh_token":"synthetic-rotated","expires_in":3600}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: ChatGPTAuthError.self) { try await auth.validAccessToken() }
        #expect(!auth.isAuthenticated)
        #expect(try vault.read("chatgpt-auth") == nil)
    }

}
