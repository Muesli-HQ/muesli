import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Bodhan compatibility and languages")
struct BodhanBackendTests {
    private let retiredModel = "phequals/indic-conformer-600m-multilingual-coreml-rnnt"

    @Test("Retired Indic model is absent and saved selections resolve to Flex")
    func retiredSelection() {
        #expect(!BackendOption.all.contains { $0.model == retiredModel || $0.backend == "indicasr" })
        #expect(BackendOption.resolve(backend: "indicasr", model: retiredModel) == .bodhanFlex)
        #expect(BackendOption.resolve(backend: "bodhan", model: "missing") == nil)
    }

    @Test("Old Bodhan route preserves Core and Flex selection", arguments: BodhanModel.allCases)
    func oldBodhanRoute(model: BodhanModel) {
        let resolved = BackendOption.resolve(backend: "indicasr", model: model.rawValue)
        #expect(resolved?.backend == "bodhan")
        #expect(resolved?.model == model.rawValue)
    }

    @Test("Persisted dictation and meeting selections migrate without losing language")
    func configMigration() throws {
        let payload: [String: Any] = [
            "stt_backend": "indicasr", "stt_model": retiredModel,
            "meeting_transcription_backend": "indicasr", "meeting_transcription_model": BodhanModel.core.rawValue,
            "indic_asr_language": "ta"
        ]
        let config = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(config.sttBackend == "bodhan")
        #expect(config.sttModel == BodhanModel.flex.rawValue)
        #expect(config.meetingTranscriptionBackend == "bodhan")
        #expect(config.meetingTranscriptionModel == BodhanModel.core.rawValue)
        #expect(config.resolvedBodhanLanguage == .tamil)
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.resolvedBodhanLanguage == .tamil)
        #expect(roundTrip.sttModel == config.sttModel)
    }

    @Test("Language menus reflect the distinct Core and Flex tokenizer prompts")
    func supportedLanguages() {
        let core = BodhanLanguage.choices(for: BodhanModel.core.rawValue)
        let flex = BodhanLanguage.choices(for: BodhanModel.flex.rawValue)
        #expect(core.count == 26) // 25 languages plus auto-detect.
        #expect(flex.count == 28)
        #expect(core.contains(.english) && core.contains(.automatic))
        #expect(!core.contains(.chhattisgarhi) && flex.contains(.chhattisgarhi))
        #expect(!core.contains(.haryanvi) && flex.contains(.haryanvi))
        #expect(BodhanLanguage.choices(for: "missing").isEmpty)
    }
    @Test("Precision variants have independent downloads and exact artifact sets")
    func variantDownloads() {
        #expect(Set(BodhanModel.allCases.map(\.cacheDirectory)).count == 4)
        #expect(BackendOption.bodhanFamily.count == 4)
        #expect(BackendOption.bodhanFamily.allSatisfy { !BackendOption.experimental.contains($0) })
        for model in BodhanModel.allCases {
            #expect(model.repository == (model.isCore ? BodhanModel.core.rawValue : BodhanModel.flex.rawValue))
            #expect(model.requiredFiles.contains("native-assets/tokenizer.json"))
            #expect(model.requiredFiles.contains("variants/mlx-decoder-int8/config.json") == model.isInt8)
            #expect(!model.requiredFiles.contains("coreml/decoder.mlpackage/Manifest.json"))
            #expect(model.requiredFiles.contains("variants/mlx-decoder/decoder.safetensors") == !model.isInt8)
            #expect(model.requiredFiles.count == (model.isInt8 ? 7 : 6))
            #expect(BodhanLanguage.choices(for: model.rawValue).count == (model.isCore ? 26 : 28))
        }
    }

    @Test("Flex-only languages fall back per model without losing the saved preference",
          arguments: [BodhanLanguage.chhattisgarhi, .haryanvi])
    func languageFallback(language: BodhanLanguage) {
        var config = AppConfig()
        config.bodhanLanguage = language.rawValue
        for model in BodhanModel.allCases {
            let effective = config.resolvedBodhanLanguage.supported(for: model.rawValue)
            #expect(effective == (model.isCore ? .automatic : language))
            #expect(BodhanLanguage.choices(for: model.rawValue).contains(effective))
        }
        #expect(config.resolvedBodhanLanguage == language)
        #expect(BodhanLanguage.english.supported(for: BodhanModel.core.rawValue) == .english)
        #expect(BodhanLanguage.automatic.supported(for: BodhanModel.flex.rawValue) == .automatic)
    }

    @Test("Missing configuration preserves transcription defaults")
    func missingConfiguration() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        let defaults = AppConfig()
        #expect(config.sttBackend == defaults.sttBackend)
        #expect(config.sttModel == defaults.sttModel)
        #expect(config.meetingTranscriptionBackend == config.sttBackend)
        #expect(config.meetingTranscriptionModel == config.sttModel)
        #expect(config.resolvedBodhanLanguage == .hindi)
    }

    @Test("Bodhan cleanup allows every compatible backend except local S1-mini",
          arguments: BackendOption.bodhanFamily)
    func cleanupRouting(model: BackendOption) {
        for cleanup in TranscriptCleanupBackendOption.all {
            #expect(cleanup.isCompatible(with: model, inputFormat: .configurable))
            #expect(cleanup.isCompatible(with: model, inputFormat: .s1Mini) == (cleanup != .local))
        }
        #expect(!TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: .gemma4E2BLiteRT, inputFormat: .configurable))
    }

}
