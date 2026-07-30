import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let store = ConfigStore()
        let config = store.load()
        // Hotkey may have been customized by user — just verify it loaded
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() {
        let store = ConfigStore()
        let original = store.load()

        var config = original
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.meetingSummaryBackend == "openrouter")

        // Restore original
        store.save(original)
    }

    @Test("diarization tuning survives a config encode/decode round-trip")
    func diarizationTuningRoundTrip() throws {
        var config = AppConfig()
        config.diarizationClusteringThreshold = 0.6
        config.diarizationMinSpeechDuration = 0.5

        let decoded = try JSONDecoder().decode(
            AppConfig.self,
            from: try JSONEncoder().encode(config)
        )

        #expect(decoded.diarizationClusteringThreshold == 0.6)
        #expect(decoded.diarizationMinSpeechDuration == 0.5)
    }

    @Test("diarization tuning falls back to defaults when absent")
    func diarizationTuningDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        #expect(decoded.diarizationClusteringThreshold == 0.7)
        #expect(decoded.diarizationMinSpeechDuration == 1.0)
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
        let store = ConfigStore()
        let original = store.load()

        store.save(original)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }
}
