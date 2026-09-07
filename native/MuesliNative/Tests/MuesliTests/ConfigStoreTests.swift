import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let supportDirectory = makeSupportDirectory(label: "load")
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = ConfigStore(supportDirectory: supportDirectory)
        let config = store.load()
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() throws {
        let supportDirectory = makeSupportDirectory(label: "roundtrip")
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = ConfigStore(supportDirectory: supportDirectory)

        var config = AppConfig()
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.whisperLanguage = WhisperKitLanguage.german.rawValue
        config.appleSpeechLanguage = "en-US"
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey.isEmpty)
        #expect(
            try OpenRouterCredentialStore(supportDirectory: supportDirectory).load()?.apiKey ==
                "sk-or-test-roundtrip"
        )
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.whisperLanguage == WhisperKitLanguage.german.rawValue)
        #expect(loaded.appleSpeechLanguage == "en-US")
        #expect(loaded.meetingSummaryBackend == "openrouter")
    }

    @Test("config path honors the isolated support directory")
    func configPath() {
        let supportDirectory = makeSupportDirectory(label: "path")
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = ConfigStore(supportDirectory: supportDirectory)
        let path = store.configPath().path
        #expect(path.hasPrefix(supportDirectory.path))
        #expect(path.hasSuffix("config.json"))
    }

    @Test("saved config uses owner-only file permissions")
    func configPermissions() throws {
        let supportDirectory = makeSupportDirectory(label: "permissions")
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = ConfigStore(supportDirectory: supportDirectory)

        store.save(AppConfig())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }

    @Test("legacy migration preserves an existing dedicated credential")
    func legacyMigrationPreservesExistingCredential() throws {
        let supportDirectory = makeSupportDirectory(label: "migration-existing")
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )

        let credentialStore = OpenRouterCredentialStore(supportDirectory: supportDirectory)
        let existingCredential = OpenRouterCredential(
            apiKey: "sk-or-new-oauth",
            userID: "user-new"
        )
        try credentialStore.save(existingCredential)

        var staleConfig = AppConfig()
        staleConfig.openRouterAPIKey = "sk-or-stale-legacy"
        let configURL = supportDirectory.appendingPathComponent("config.json")
        try JSONEncoder().encode(staleConfig).write(to: configURL, options: .atomic)

        let loaded = ConfigStore(supportDirectory: supportDirectory).load()

        #expect(loaded.openRouterAPIKey.isEmpty)
        #expect(try credentialStore.load() == existingCredential)
        let persistedConfig = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(contentsOf: configURL)
        )
        #expect(persistedConfig.openRouterAPIKey.isEmpty)
    }

    private func makeSupportDirectory(label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "muesli-config-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
