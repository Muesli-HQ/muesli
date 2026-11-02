import Foundation
import MuesliCore
import FluidAudio
import MLX
import Testing
@testable import MuesliNativeApp

@Suite("Bodhan compatibility and languages")
struct BodhanBackendTests {
    @Test("streamed language metadata accounts for decoder-skipped silence")
    func streamingMetadataAcrossSilence() async {
        let metadata = BodhanPreviewMetadata()
        let session = BufferedTranscriptionSession(decodeWithoutTimings: { audio in
            metadata.append(.init(startSeconds: 0, endSeconds: Double(audio.count) / 16000,
                languageCode: "ta", wasAutoDetected: true))
            return "தமிழ்"
        }, measurement: { text in
            metadata.measurement(text: text, modelID: BodhanModel.flex.rawValue, outputMode: .mixed)
        }, onSilentAudio: { metadata.advanceSilentAudio(samples: $0) },
        onUpdate: { _ in }, onFailure: { Issue.record("Unexpected stream failure: \($0)") })
        session.enqueue(Array(repeating: 0.2, count: 32_000)
            + Array(repeating: 0, count: 32_000) + Array(repeating: 0.2, count: 8_000))
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        let measurement = session.bodhanMeasurement(for: result.text)
        #expect(measurement?.languageSamples.map(\.startSeconds) == [0, 4])
        #expect(measurement?.languageSamples.map(\.endSeconds) == [2, 4.5])
    }

    @Test("streaming metadata retains absolute language spans and computes switches over the full transcript")
    func previewMetadata() {
        let metadata = BodhanPreviewMetadata()
        metadata.append(.init(startSeconds: 0, endSeconds: 2, languageCode: "ta", wasAutoDetected: true))
        metadata.advanceSilentAudio(samples: 32_000)
        metadata.append(.init(startSeconds: 0, endSeconds: 0.5, languageCode: "en", wasAutoDetected: false))
        let text = "தமிழ் this is English தமிழ்"
        let mixed = metadata.measurement(text: text, modelID: BodhanModel.flex.rawValue, outputMode: .mixed)
        #expect(mixed.languageSamples.map(\.startSeconds) == [0, 4])
        #expect(mixed.languageSamples.map(\.endSeconds) == [2, 4.5])
        #expect(mixed.languageSamples.map(\.languageCode) == ["ta", "en"])
        #expect(mixed.languageSamples.map(\.wasAutoDetected) == [true, false])
        #expect(mixed.runLengths == WordsBeforeCodeSwitch.bodhanMixedRunLengths(in: text))
        #expect(metadata.measurement(text: text, modelID: BodhanModel.flex.rawValue,
                                     outputMode: .romanized).runLengths == nil)
    }

    @Test("live token limits preserve progress while batch still requires EOS")
    func boundedPreviewDecoding() throws {
        for mode in BodhanOutputMode.allCases {
            #expect(BodhanDecodingPolicy.preview.tokenLimit(outputMode: mode) == 64)
            #expect(BodhanDecodingPolicy.batch.tokenLimit(outputMode: mode) == mode.maximumGeneratedTokens)
        }
        try BodhanDecodingPolicy.preview.validateCompletion(endedWithEOS: false)
        try BodhanDecodingPolicy.batch.validateCompletion(endedWithEOS: true)
        #expect(throws: (any Error).self) {
            try BodhanDecodingPolicy.batch.validateCompletion(endedWithEOS: false)
        }
    }

    @Test("opt-in real-time Bodhan replay", .enabled(if: ProcessInfo.processInfo.environment["MUESLI_BODHAN_STREAM_AUDIO"] != nil))
    func realtimeStreamingReplay() async throws {
        guard #available(macOS 15, *) else { return }
        let env = ProcessInfo.processInfo.environment
        if let path = env["MUESLI_MLX_EVAL_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
        let path = try #require(env["MUESLI_BODHAN_STREAM_AUDIO"])
        let model = BodhanModel(rawValue: env["MUESLI_BODHAN_STREAM_MODEL"] ?? "") ?? .flexInt8
        try #require(model.isDownloaded, "Replay requires an existing cached model")
        let backend = try #require(BackendOption.resolve(backend: "bodhan", model: model.rawValue))
        let original = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        let repeats = Int(env["MUESLI_BODHAN_STREAM_REPEATS"] ?? "4") ?? 4
        let repeated = Array(repeating: original, count: repeats).flatMap { $0 }
        let first = Int(env["MUESLI_BODHAN_STREAM_FIRST_SAMPLE"] ?? "0") ?? 0
        let count = Int(env["MUESLI_BODHAN_STREAM_SAMPLE_COUNT"] ?? "") ?? (repeated.count - first)
        try #require(first >= 0 && count > 0 && first <= repeated.count - count)
        let samples = Array(repeated[first..<first + count])
        let coordinator = TranscriptionCoordinator()
        try await coordinator.preloadRequired(backend: backend, includeMeetingHelpers: false)
        let session = try coordinator.makeBufferedTranscriptionSession(
            backend: backend, whisperLanguage: .auto, parakeetLanguage: .auto,
            bodhanLanguage: .english, bodhanOutputMode: .mixed,
            onUpdate: { update in
                #expect(update.tail.isEmpty)
            }, onFailure: { error in Issue.record("Bodhan replay failed: \(error)") },
            onDiagnostic: { event in
                if event.hasPrefix("continuity_decode:") { print("[bodhan-replay] \(event)") }
            })
        defer { session.cancel() }
        let clock = ContinuousClock()
        let start = clock.now
        for offset in stride(from: 0, to: samples.count, by: 1024) {
            try await clock.sleep(until: start.advanced(by: .milliseconds(offset / 16)))
            try #require(!session.diagnostics.closed, "Session closed before all audio arrived")
            session.enqueue(Array(samples[offset..<min(offset + 1024, samples.count)]))
        }
        let stopped = clock.now
        let result = await session.finishForReuse()
        print("[bodhan-replay] model=\(model.rawValue) samples=\(samples.count) decoded=\(result.decodedThroughSample) updates=\(session.diagnostics.revision) stop=\(stopped.duration(to: clock.now)) reusable=\(result.canReuse)")
        #expect(result.completed && result.canReuse)
        #expect(result.receivedSamples == samples.count)
        #expect(result.decodedThroughSample == samples.count)
        #expect(stopped.duration(to: clock.now) < .seconds(5))
        await coordinator.unloadBodhanTranscriber(ifLoadedModelID: model.rawValue)
    }

    @Test("Bodhan tiers use product names without changing saved model IDs", arguments: BodhanModel.allCases)
    func tierNames(model: BodhanModel) {
        let tier = model.isInt8 ? "Lite" : "Pro"
        #expect(model.tierName == tier)
        #expect(model.name == "Bodhan \(model.isCore ? "Core" : "Flex") \(tier)")
        #expect(BackendOption.resolve(backend: "bodhan", model: model.rawValue)?.label == model.name)
    }

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

    @Test("Only Flex Mixed output can measure words before a language switch")
    func wbcsOutputEligibility() {
        for model in BodhanModel.allCases {
            for mode in BodhanOutputMode.allCases {
                #expect(mode.supportsWordsBeforeCodeSwitch(modelID: model.rawValue) == (!model.isCore && mode == .mixed))
            }
        }
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

    @Test("Output mode persists, defaults to mixed and remains native for Core")
    func outputModes() throws {
        let missing = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(missing.resolvedBodhanOutputMode == .mixed)
        #expect(BodhanOutputMode.resolved("unknown") == .mixed)
        for mode in BodhanOutputMode.allCases {
            var config = AppConfig()
            config.bodhanOutputMode = mode.rawValue
            let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            #expect(restored.resolvedBodhanOutputMode == mode)
            for model in BodhanModel.allCases {
                #expect(mode.supported(for: model.rawValue) == (model.isCore ? .native : mode))
            }
        }
        #expect(BodhanOutputMode.romanized.maximumGeneratedTokens >= 281)
        #expect(BodhanOutputMode.mixed.maximumGeneratedTokens == 256)
    }

    @Test("Romanization derives the upstream task token without changing cached prompts")
    func romanizedPrompt() throws {
        guard #available(macOS 15, *) else { return }
        var pieces = [String](repeating: "", count: 32)
        pieces[8] = "<|itn|>"; pieces[9] = "<|noitn|>"
        pieces[10] = "<|romanized|>"; pieces[11] = "<|noromanized|>"
        let native = [7, 4, 18, 20, 20, 5, 9, 11, 13, 15]
        var mixed = native; mixed[6] = 8
        let tokenizer = BodhanCoreML.Tokenizer(pieces: pieces, special_count: 24, eos_id: 3,
            prompts: ["hi": native], mixed_prompts: ["hi": mixed])
        var romanized = native; romanized[7] = 10
        #expect(try tokenizer.prompt(language: "hi", mode: .native) == native)
        #expect(try tokenizer.prompt(language: "hi", mode: .mixed) == mixed)
        #expect(try tokenizer.prompt(language: "hi", mode: .romanized) == romanized)
        #expect(tokenizer.prompts["hi"] == native)
        pieces[10] = ""
        let unsupported = BodhanCoreML.Tokenizer(pieces: pieces, special_count: 24, eos_id: 3,
            prompts: ["hi": native], mixed_prompts: nil)
        #expect(throws: (any Error).self) { try unsupported.prompt(language: "hi", mode: .romanized) }
    }

}
