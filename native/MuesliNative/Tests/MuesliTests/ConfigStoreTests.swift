import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    /// A throwaway support directory. Tests must never read or write the real
    /// config.json: `swift test` runs on machines where Muesli is installed, and
    /// a test that saves into the live support directory rewrites the settings of
    /// whoever is running the suite.
    private func makeStore() -> ConfigStore {
        ConfigStore(
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("muesli-config-store-\(UUID().uuidString)", isDirectory: true)
        )
    }

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let store = makeStore()
        let config = store.load()
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() {
        let store = makeStore()
        let original = store.load()

        var config = original
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
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.whisperLanguage == WhisperKitLanguage.german.rawValue)
        #expect(loaded.appleSpeechLanguage == "en-US")
        #expect(loaded.meetingSummaryBackend == "openrouter")
    }

    @Test("config path is in Application Support")
    func configPath() {
        let store = ConfigStore()
        let path = store.configPath().path
        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("config.json"))
    }

    @Test("saved config uses owner-only file permissions")
    func configPermissions() throws {
        let store = makeStore()
        let original = store.load()

        store.save(original)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }
}
