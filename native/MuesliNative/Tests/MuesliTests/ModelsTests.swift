import Testing
import Accelerate
import AppKit
import Foundation
import FluidAudio
import MuesliCore
@testable import MuesliNativeApp

@Suite("BackendOption")
struct BackendOptionTests {

    @Test("all options have unique models")
    func uniqueModels() {
        let models = BackendOption.all.map(\.model)
        #expect(Set(models).count == models.count, "Duplicate model in BackendOption.all")
    }

    @Test("all options have non-empty labels and descriptions")
    func labelsAndDescriptions() {
        for option in BackendOption.all {
            #expect(!option.label.isEmpty, "Empty label for \(option.model)")
            #expect(!option.description.isEmpty, "Empty description for \(option.model)")
            #expect(!option.sizeLabel.isEmpty, "Empty sizeLabel for \(option.model)")
        }
    }

    @Test("backend field is one of the known backends")
    func knownBackends() {
        let known: Set<String> = ["fluidaudio", "parakeet-unified", "whisper", "qwen", "nemotron35", "cohere", "indicasr", "sensevoice", "gemma4-litert", "apple-speech"]
        for option in BackendOption.all {
            #expect(known.contains(option.backend), "Unknown backend: \(option.backend)")
        }
    }

    @Test("Parakeet models use fluidaudio backend")
    func parakeetBackend() {
        #expect(BackendOption.parakeetMultilingual.backend == "fluidaudio")
        #expect(BackendOption.parakeetEnglish.backend == "fluidaudio")
    }

    @Test("Whisper models use whisper backend")
    func whisperBackend() {
        #expect(BackendOption.whisperTiny.backend == "whisper")
        #expect(BackendOption.whisperTinyEnglish.backend == "whisper")
        #expect(BackendOption.whisperSmall.backend == "whisper")
        #expect(BackendOption.whisperSmallEnglish.backend == "whisper")
        #expect(BackendOption.whisperMediumEnglish.backend == "whisper")
        #expect(BackendOption.whisperLargeTurbo.backend == "whisper")
    }

    @Test("Nemotron 3.5 uses nemotron35 backend")
    func nemotron35Backend() {
        #expect(BackendOption.nemotron35Multilingual.backend == "nemotron35")
        #expect(BackendOption.nemotron35Multilingual.model.contains("Nemotron-3.5"))
        #expect(!BackendOption.nemotron35Multilingual.label.contains("Experimental"))
        #expect(!BackendOption.nemotron35Multilingual.recommended)
        #expect(!BackendOption.experimental.contains(.nemotron35Multilingual))
        #expect(BackendOption.streaming == [.nemotron35Multilingual])
        #expect(BackendOption.all.contains(.nemotron35Multilingual))
    }

    @Test("whisper alias points to parakeetMultilingual")
    func whisperAlias() {
        #expect(BackendOption.whisper == BackendOption.parakeetMultilingual)
    }

    @Test("all contains all defined options")
    func allContainsAll() {
        #expect(BackendOption.all.contains(.parakeetMultilingual))
        #expect(BackendOption.all.contains(.parakeetEnglish))
        #expect(BackendOption.all.contains(.whisperTiny))
        #expect(BackendOption.all.contains(.whisperTinyEnglish))
        #expect(BackendOption.all.contains(.whisperSmall))
        #expect(BackendOption.all.contains(.whisperSmallEnglish))
        #expect(BackendOption.all.contains(.whisperMediumEnglish))
        #expect(BackendOption.all.contains(.whisperLargeTurbo))
        #expect(BackendOption.all.contains(.qwen3Asr))
        #expect(BackendOption.all.contains(.cohereTranscribe))
        #expect(BackendOption.all.contains(.indicASR))
        #expect(BackendOption.all.contains(.senseVoiceSmall))
        #expect(BackendOption.all.contains(.nemotron35Multilingual))
        #expect(BackendOption.all.contains(.gemma4E2BLiteRT))
    }

    @Test("Qwen ASR is available but experimental")
    func qwenAsrIsExperimental() {
        #expect(BackendOption.all.contains(.qwen3Asr))
        #expect(BackendOption.experimental.contains(.qwen3Asr))
        #expect(BackendOption.qwen3Asr.description.contains("52 languages"))
        #expect(BackendOption.qwen3Asr.description.contains("2–3 second"))
    }

    @Test("model descriptions explain usage without implementation jargon")
    func modelDescriptionsAreProductFacing() {
        let implementationTerms = ["INT8", "CoreML", "ANE", "RNNT", "FluidAudio", "LiteRT-LM", "quantized", "GGUF"]
        for option in BackendOption.all {
            for term in implementationTerms {
                #expect(!option.description.contains(term), "\(option.label) description exposes \(term)")
            }
        }
        for option in PostProcessorOption.all {
            for term in implementationTerms {
                #expect(!option.description.contains(term), "\(option.label) description exposes \(term)")
            }
        }
    }

    @Test("Qwen ASR cache names preserve current runtime and legacy cleanup paths")
    func qwenAsrCacheDirectoryNamesMatchFluidAudio() {
        // FluidAudio Repo.folderName default strips "-coreml" from the repo slug,
        // so downloads land in qwen3-asr-0.6b/{int8,f32} (issue #380).
        #expect(Qwen3AsrModelStore.cacheDirectoryNames.first == "qwen3-asr-0.6b")
        #expect(Qwen3AsrModelStore.cacheDirectoryNames.contains("qwen3-asr-0.6b-coreml"))
    }

    @Test("Qwen ASR readiness matches the complete managed INT8 runtime directory")
    func qwenAsrReadinessMatchesManagedRuntimeDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("muesli-qwen-asr-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        func installRequiredArtifacts(in directory: URL) throws {
            for relativePath in [
                "qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin",
                "qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin",
                "qwen3_asr_decoder_stateful.mlmodelc/coremldata.bin",
                "qwen3_asr_decoder_stateful.mlmodelc/weights/weight.bin",
                "qwen3_asr_embeddings.bin",
                "vocab.json",
            ] {
                let url = directory.appendingPathComponent(relativePath)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0x01]).write(to: url)
            }
        }

        #expect(!Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))

        let legacyDirectory = root
            .appendingPathComponent("qwen3-asr-0.6b-coreml/int8", isDirectory: true)
        try installRequiredArtifacts(in: legacyDirectory)
        #expect(!Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))

        let managedDirectory = ManagedASRModelPlans.qwen3ASRInt8(modelsRoot: root).cacheDirectory
        try installRequiredArtifacts(in: managedDirectory)
        let managedPlan = ManagedASRModelPlans.qwen3ASRInt8(modelsRoot: root)
        #expect(Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))
        let installedPaths = [
            "qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin",
            "qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin",
            "qwen3_asr_decoder_stateful.mlmodelc/coremldata.bin",
            "qwen3_asr_decoder_stateful.mlmodelc/weights/weight.bin",
            "qwen3_asr_embeddings.bin",
            "vocab.json",
        ]
        let installedManifest = ModelDownloadManifest(
            id: managedPlan.modelID,
            version: "test-install",
            files: installedPaths.map { relativePath in
                ModelDownloadFile(
                    relativePath: relativePath,
                    remoteURL: URL(string: "https://example.com/model")!,
                    expectedByteCount: 1
                )
            }
        )
        try managedPlan.recordSuccessfulInstallation(installedManifest)
        #expect(Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))

        let completionMarker = managedDirectory
            .appendingPathComponent(".muesli-managed-model-complete.json")
        try Data("not-json".utf8).write(to: completionMarker)
        #expect(!Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))

        try managedPlan.recordSuccessfulInstallation(installedManifest)
        try fm.removeItem(at: managedDirectory.appendingPathComponent("vocab.json"))
        #expect(!Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))

        try Qwen3AsrModelStore.deleteModelFiles(from: root, fileManager: fm)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("qwen3-asr-0.6b").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("qwen3-asr-0.6b-coreml").path))
    }

    @Test("Qwen ASR warmup publishes readiness only for the current uncancelled load")
    func qwenAsrWarmupReadinessGate() throws {
        try Qwen3AsrWarmupReadiness.validate(isCancelled: false, isCurrent: true)
        #expect(throws: CancellationError.self) {
            try Qwen3AsrWarmupReadiness.validate(isCancelled: true, isCurrent: true)
        }
        #expect(throws: CancellationError.self) {
            try Qwen3AsrWarmupReadiness.validate(isCancelled: false, isCurrent: false)
        }
    }

    @Test("Parakeet deletion unloads only the matching runtime variant")
    func parakeetDeletionUnloadPolicy() {
        #expect(FluidAudioUnloadPolicy.shouldUnload(
            loadedVersion: .v2,
            deletingVersion: .v2
        ))
        #expect(!FluidAudioUnloadPolicy.shouldUnload(
            loadedVersion: .v3,
            deletingVersion: .v2
        ))
        #expect(!FluidAudioUnloadPolicy.shouldUnload(
            loadedVersion: nil,
            deletingVersion: .v3
        ))
    }

    @Test("Cohere uses cohere backend")
    func cohereBackend() {
        #expect(BackendOption.cohereTranscribe.backend == "cohere")
        #expect(BackendOption.cohereTranscribe.model.contains("cohere"))
    }

    @Test("Indic ASR uses indicasr backend")
    func indicASRBackend() {
        #expect(BackendOption.indicASR.backend == "indicasr")
        #expect(BackendOption.indicASR.model.contains("indic-conformer"))
    }

    @Test("Indic ASR chunk merge deduplicates Indic overlap")
    func indicASRChunkMergeDeduplicatesIndicOverlap() {
        let result = IndicASRTranscriptMerger.mergeOverlappingTranscripts([
            "मैं हिंदी में बोल सकता हूँ",
            "बोल सकता हूँ और तमिल भी",
            "தமிழ் கூட பேச முடியும்",
            "பேச முடியும் இப்போ",
        ])

        #expect(result == "मैं हिंदी में बोल सकता हूँ और तमिल भी தமிழ் கூட பேச முடியும் இப்போ")
    }

    @Test("Indic ASR chunk merge preserves non-overlapping text")
    func indicASRChunkMergePreservesNonOverlappingText() {
        let result = IndicASRTranscriptMerger.mergeOverlappingTranscripts([
            "நான் தமிழ் பேசுகிறேன்",
            "यह नया वाक्य है",
        ])

        #expect(result == "நான் தமிழ் பேசுகிறேன் यह नया वाक्य है")
    }

    @Test("Indic ASR mel transpose uses row-major vDSP parameter order")
    func indicASRMelTransposeParameterOrder() {
        let rows = 2
        let columns = 3
        let frameMajor: [Float] = [
            1, 2, 3,
            4, 5, 6,
        ]
        let expectedColumnMajorTranspose: [Float] = [
            1, 4,
            2, 5,
            3, 6,
        ]

        var actual = [Float](repeating: 0, count: frameMajor.count)
        vDSP_mtrans(
            frameMajor, 1,
            &actual, 1,
            vDSP_Length(columns),
            vDSP_Length(rows)
        )
        #expect(actual == expectedColumnMajorTranspose)

        var swapped = [Float](repeating: 0, count: frameMajor.count)
        vDSP_mtrans(
            frameMajor, 1,
            &swapped, 1,
            vDSP_Length(rows),
            vDSP_Length(columns)
        )
        #expect(swapped != expectedColumnMajorTranspose)
    }

    @Test("SenseVoice uses the native speech model")
    func senseVoiceBackend() {
        #expect(BackendOption.senseVoiceSmall.backend == "sensevoice")
        #expect(BackendOption.senseVoiceSmall.model == "FluidInference/sensevoice-small-coreml")
    }

    @Test("Gemma 4 variants remain experimental managed models")
    func gemma4LiteRTBackend() {
        #expect(BackendOption.gemma4E2BLiteRT.backend == "gemma4-litert")
        #expect(BackendOption.gemma4E2BLiteRT.model == Gemma4LiteRTModelStore.repoID)
        #expect(BackendOption.gemma4E2BLiteRT.label == "Gemma 4 E2B")
        #expect(BackendOption.gemma4E2BLiteRT.sizeLabel == "~2.6 GB")
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("research preview"))
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("macOS 15"))
        #expect(BackendOption.experimental.contains(.gemma4E2BLiteRT))
        #expect(!BackendOption.onboarding.contains(.gemma4E2BLiteRT))
        #expect(BackendOption.gemma4E4BLiteRT.backend == "gemma4-litert")
        #expect(BackendOption.gemma4E4BLiteRT.model == Gemma4LiteRTModel.e4b.repoID)
        #expect(BackendOption.gemma4E4BLiteRT.label == "Gemma 4 E4B")
        #expect(BackendOption.gemma4E4BLiteRT.sizeLabel == "~3.7 GB")
        #expect(BackendOption.experimental.contains(.gemma4E4BLiteRT))
        #expect(!BackendOption.onboarding.contains(.gemma4E4BLiteRT))
    }

    @Test("Cohere is not in experimental list")
    func cohereNotExperimental() {
        #expect(!BackendOption.experimental.contains(.cohereTranscribe))
    }

    @Test("onboarding prefers Parakeet Unified and v3 over Apple Speech")
    func onboardingModelChoices() {
        #expect(BackendOption.onboarding.first == BackendOption.onboardingDefault)
        #expect(BackendOption.onboardingDefault == .parakeetUnified)
        #expect(BackendOption.onboarding.contains(.parakeetUnified))
        #expect(BackendOption.onboarding.contains(.parakeetMultilingual))
        #expect(BackendOption.onboarding.contains(.whisperTiny))
        #expect(BackendOption.onboarding.contains(.whisperSmall))
        #expect(BackendOption.onboarding.contains(.cohereTranscribe))
        for option in BackendOption.experimental {
            #expect(!BackendOption.onboarding.contains(option))
        }
        #expect(BackendOption.onboarding.contains(.nemotron35Multilingual))
        if #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem {
            #expect(!BackendOption.onboarding.contains(.appleSpeechAnalyzer))
        } else {
            #expect(!BackendOption.onboarding.contains(.appleSpeechAnalyzer))
        }
    }

    @Test("only Nemotron backends use streaming dictation")
    func streamingDictationBackends() {
        let streaming = BackendOption.all.filter(\.isStreamingDictationBackend)
        #expect(streaming == [.nemotron35Multilingual])
    }

    @Test("OpenAI never uses local streaming")
    func providerStreamingRouting() {
        #expect(DictationProvider.local.usesStreamingBackend(.nemotron35Multilingual))
        #expect(!DictationProvider.openAI.usesStreamingBackend(.nemotron35Multilingual))
        #expect(!DictationProvider.local.usesStreamingBackend(.parakeetMultilingual))
    }

    @Test("Hosted dictation fallback excludes streaming backends")
    func openAIFallbackResolution() {
        let available: [BackendOption] = [
            .nemotron35Multilingual,
            .parakeetUnified,
            .whisperSmall,
        ]
        #expect(BackendOption.resolveHostedDictationFallback(
            selected: .nemotron35Multilingual,
            available: available
        ) == .parakeetUnified)
        #expect(BackendOption.resolveHostedDictationFallback(
            selected: .whisperSmall,
            available: available
        ) == .whisperSmall)
        #expect(BackendOption.resolveHostedDictationFallback(
            selected: .nemotron35Multilingual,
            available: [.nemotron35Multilingual]
        ) == nil)
    }

    @Test("streaming dictation models are excluded from meeting transcription")
    func streamingDictationModelsAreExcludedFromMeetingTranscription() {
        #expect(!BackendOption.nemotron35Multilingual.supportsMeetingTranscription)
        #expect(BackendOption.parakeetMultilingual.supportsMeetingTranscription)
        #expect(BackendOption.whisperLargeTurbo.supportsMeetingTranscription)
        #expect(!BackendOption.downloadedMeetingTranscription.contains(.nemotron35Multilingual))
    }

    @Test("only multilingual Whisper models expose language selection")
    func whisperLanguageSelectionAvailability() {
        #expect(BackendOption.whisperTiny.supportsWhisperLanguageSelection)
        #expect(BackendOption.whisperSmall.supportsWhisperLanguageSelection)
        #expect(BackendOption.whisperLargeTurbo.supportsWhisperLanguageSelection)
        #expect(!BackendOption.whisperTinyEnglish.supportsWhisperLanguageSelection)
        #expect(!BackendOption.whisperSmallEnglish.supportsWhisperLanguageSelection)
        #expect(!BackendOption.whisperMediumEnglish.supportsWhisperLanguageSelection)
        #expect(!BackendOption.parakeetMultilingual.supportsWhisperLanguageSelection)
    }

    @Test("Whisper models use WhisperKit CoreML identifiers")
    func whisperKitModels() {
        // WhisperKit models use short variant names, not ggml- prefixed binaries
        #expect(BackendOption.whisperTiny.model == "tiny")
        #expect(BackendOption.whisperTinyEnglish.model == "tiny.en")
        #expect(BackendOption.whisperSmall.model == "small")
        #expect(BackendOption.whisperSmallEnglish.model == "small.en")
        #expect(BackendOption.whisperMediumEnglish.model == "medium.en")
        #expect(BackendOption.whisperLargeTurbo.model.contains("large"))
    }

    @Test("English-only and multilingual Whisper checkpoints are always in the catalog")
    func whisperCatalogIncludesEveryVariant() {
        #expect(BackendOption.whisperFamily == [
            .whisperTiny, .whisperTinyEnglish,
            .whisperSmall, .whisperSmallEnglish,
            .whisperMediumEnglish, .whisperLargeTurbo,
        ])
        #expect(BackendOption.resolve(backend: "whisper", model: "tiny.en") == .whisperTinyEnglish)
        #expect(BackendOption.resolve(backend: "whisper", model: "small.en") == .whisperSmallEnglish)
        #expect(BackendOption.resolve(backend: "whisper", model: "medium.en") == .whisperMediumEnglish)
    }

    @Test("resolveDownloaded falls back when an English-only selection is not downloaded")
    func resolveDownloadedFallsBackForMissingEnglishWhisperSelection() {
        let resolved = BackendOption.resolveDownloaded(
            backend: "whisper",
            model: "small.en",
            fallback: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual, .whisperSmall]
        )

        #expect(resolved == .parakeetMultilingual)
    }

    @Test("resolveDownloaded keeps an installed English-only Whisper selection")
    func resolveDownloadedKeepsEnglishWhisperSelection() {
        let resolved = BackendOption.resolveDownloaded(
            backend: "whisper",
            model: "small.en",
            fallback: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual, .whisperSmallEnglish]
        )

        #expect(resolved == .whisperSmallEnglish)
    }

    @Test("resolveDownloaded keeps selected downloaded meeting model")
    func resolveDownloadedKeepsSelectedDownloadedModel() {
        let resolved = BackendOption.resolveDownloaded(
            backend: BackendOption.whisperLargeTurbo.backend,
            model: BackendOption.whisperLargeTurbo.model,
            fallback: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual, .whisperLargeTurbo]
        )

        #expect(resolved == .whisperLargeTurbo)
    }

    @Test("resolveDownloaded falls back when selected meeting model is unavailable")
    func resolveDownloadedFallsBackWhenSelectedUnavailable() {
        let resolved = BackendOption.resolveDownloaded(
            backend: BackendOption.whisperLargeTurbo.backend,
            model: BackendOption.whisperLargeTurbo.model,
            fallback: .parakeetMultilingual,
            downloadedOptions: [.parakeetMultilingual, .whisperSmall]
        )

        #expect(resolved == .parakeetMultilingual)
    }

    @Test("resolveDownloaded uses first downloaded model when fallback is unavailable")
    func resolveDownloadedUsesFirstDownloadedWhenFallbackUnavailable() {
        let resolved = BackendOption.resolveDownloaded(
            backend: BackendOption.whisperLargeTurbo.backend,
            model: BackendOption.whisperLargeTurbo.model,
            fallback: .parakeetMultilingual,
            downloadedOptions: [.whisperSmall]
        )

        #expect(resolved == .whisperSmall)
    }
}

@Suite("PostProcessorOption")
struct PostProcessorOptionTests {

    @Test("all options have unique ids")
    func uniqueIDs() {
        let ids = PostProcessorOption.all.map(\.id)
        #expect(Set(ids).count == ids.count, "Duplicate id in PostProcessorOption.all")
    }

    @Test("all options have unique filenames")
    func uniqueFilenames() {
        let filenames = PostProcessorOption.all.map(\.filename)
        #expect(Set(filenames).count == filenames.count, "Duplicate filename in PostProcessorOption.all")
    }

    @Test("all options use HTTPS GGUF downloads")
    func validDownloadMetadata() {
        for option in PostProcessorOption.all {
            #expect(option.downloadURL.scheme == "https", "Non-HTTPS download URL for \(option.id)")
            #expect(option.filename.lowercased().hasSuffix(".gguf"), "Non-GGUF filename for \(option.id)")
            #expect(!option.label.isEmpty, "Empty label for \(option.id)")
            #expect(!option.description.isEmpty, "Empty description for \(option.id)")
            #expect(!option.sizeLabel.isEmpty, "Empty size label for \(option.id)")
        }
    }

    @Test("S1-mini retains its trained normalization contract")
    func s1MiniNormalizationContract() {
        let option = PostProcessorOption.s1Mini

        #expect(option.label == "S1-mini by Superwhisper")
        #expect(option.inputFormat == .s1Mini)
        #expect(option.effectiveSystemPrompt(configuredSystemPrompt: "Custom prompt") == PostProcessorOption.s1MiniSystemPrompt)
        #expect(option.downloadURL.lastPathComponent == "s1-mini-q4_k_m.gguf")
        #expect(option.logoResourceName == "superwhisper-logo")
    }

    @Test("S1-mini is unavailable for Indic ASR only")
    func s1MiniIndicASRCompatibility() {
        #expect(!PostProcessorOption.s1Mini.isCompatible(with: .indicASR))
        #expect(PostProcessorOption.s1Mini.isCompatible(with: .parakeetMultilingual))
        #expect(PostProcessorOption.finetunedV3.isCompatible(with: .indicASR))
    }

    @Test("default option is first and matches config default")
    func defaultOption() {
        #expect(PostProcessorOption.all.first == PostProcessorOption.defaultOption)
        #expect(AppConfig().activePostProcessorId == PostProcessorOption.defaultOption.id)
    }

    @Test("unknown ids resolve to default")
    func unknownIDResolvesToDefault() {
        #expect(PostProcessorOption.resolve(id: "missing") == PostProcessorOption.defaultOption)
    }

    @Test("cached legacy v2 remains runnable but is not downloadable")
    func cachedLegacyV2RemainsRunnable() {
        #expect(!PostProcessorOption.all.contains(PostProcessorOption.legacyV2))
        #expect(!PostProcessorOption.legacyV2.isDownloadable)
        #expect(PostProcessorOption.resolve(id: PostProcessorOption.legacyV2.id) == PostProcessorOption.legacyV2)
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.legacyV2.id,
            downloadedIDs: [PostProcessorOption.legacyV2.id],
            hasDevOverride: false
        ) == PostProcessorOption.legacyV2)
    }

    @Test("resolveDownloaded prefers selected downloaded option")
    func resolveDownloadedPrefersSelected() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.s1Mini.id,
            PostProcessorOption.qwen35_0_8b.id,
        ]
        #expect(PostProcessorOption.resolveDownloaded(
            id: PostProcessorOption.qwen35_0_8b.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.qwen35_0_8b)
    }

    @Test("resolveDownloaded falls back to first downloaded option")
    func resolveDownloadedFallsBack() {
        let downloadedIDs: Set<String> = [PostProcessorOption.s1Mini.id]
        #expect(PostProcessorOption.resolveDownloaded(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.s1Mini)
    }

    @Test("runtimeOption prefers selected downloaded option")
    func runtimeOptionPrefersSelectedDownloadedOption() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.s1Mini.id,
            PostProcessorOption.qwen35_0_8b.id,
        ]
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.qwen35_0_8b.id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: false
        ) == PostProcessorOption.qwen35_0_8b)
    }

    @Test("runtimeOption falls back to first downloaded option")
    func runtimeOptionFallsBackToFirstDownloadedOption() {
        let downloadedIDs: Set<String> = [PostProcessorOption.s1Mini.id]
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: false
        ) == PostProcessorOption.s1Mini)
    }

    @Test("runtimeOption accepts configured option with dev override")
    func runtimeOptionAcceptsConfiguredOptionWithDevOverride() {
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: [],
            hasDevOverride: true
        ) == PostProcessorOption.finetunedV3)
    }

    @Test("runtimeOption returns nil without a download or dev override")
    func runtimeOptionReturnsNilWithoutDownloadOrDevOverride() {
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: [],
            hasDevOverride: false
        ) == nil)
    }

    @Test("firstDownloaded respects deletion exclusion")
    func firstDownloadedExcludingDeleted() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.finetunedV3.id,
            PostProcessorOption.s1Mini.id,
        ]
        #expect(PostProcessorOption.firstDownloaded(
            excluding: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.s1Mini)
    }
}

@Suite("TranscriptCleanupBackendOption")
struct TranscriptCleanupBackendOptionTests {

    @Test("Gemma cleanup is unavailable only for Gemma dictation")
    func gemmaCleanupCompatibility() {
        #expect(!TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: .gemma4E2BLiteRT))
        #expect(!TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: .gemma4E4BLiteRT))

        for backend in BackendOption.all where backend.backend != "gemma4-litert" {
            #expect(TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: backend))
        }
    }

    @Test("Other cleanup backends remain available for Gemma dictation")
    func otherCleanupBackendsRemainCompatible() {
        for backend in TranscriptCleanupBackendOption.all where backend != .gemma4LiteRT {
            #expect(backend.isCompatible(with: .gemma4E2BLiteRT))
            #expect(backend.isCompatible(with: .gemma4E4BLiteRT))
        }
    }

    @Test("Available cleanup options exclude only conflicting Gemma cleanup")
    func availableOptionsExcludeGemmaConflict() {
        let available = TranscriptCleanupBackendOption.available(for: .gemma4E2BLiteRT)

        #expect(!available.contains(.gemma4LiteRT))
        #expect(available.count == TranscriptCleanupBackendOption.all.count - 1)
    }

    @Test("Gemma cleanup model selection round trips")
    func gemmaCleanupModelRoundTrip() throws {
        var config = AppConfig()
        config.postProcessorBackend = TranscriptCleanupBackendOption.gemma4LiteRT.backend
        config.postProcessorGemmaModel = Gemma4LiteRTModel.e4b.repoID

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded.postProcessorGemmaModel == Gemma4LiteRTModel.e4b.repoID)
        #expect(TranscriptCleanupClient.configuredModel(for: .gemma4LiteRT, config: decoded) == Gemma4LiteRTModel.e4b.repoID)
    }
}

@Suite("SummaryModelPreset")
struct SummaryModelPresetTests {

    @Test("OpenAI presets have valid model IDs")
    func openAIModels() {
        #expect(!SummaryModelPreset.openAIModels.isEmpty)
        #expect(SummaryModelPreset.openAIModels.first?.id == "gpt-5.4-mini")
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.6-sol" })
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.6-terra" })
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.6-luna" })
        #expect(!SummaryModelPreset.openAIModels.contains { $0.id == "gpt-5.5" })
        #expect(SummaryModelPreset.openAIModels.contains { $0.id == "chat-latest" })
        for preset in SummaryModelPreset.openAIModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("ChatGPT presets include supported fast options")
    func chatGPTModels() {
        #expect(!SummaryModelPreset.chatGPTModels.isEmpty)
        #expect(SummaryModelPreset.chatGPTModels.first?.id == "gpt-5.4-mini")
        #expect(SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.6-sol" })
        #expect(SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.6-terra" })
        #expect(SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.6-luna" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.5" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.4-nano" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "chat-latest" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.4" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-5.2" })
        #expect(!SummaryModelPreset.chatGPTModels.contains { $0.id == "gpt-4o" })
        for preset in SummaryModelPreset.chatGPTModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("ChatGPT transcript cleanup uses GPT-5.6 Terra by default")
    func chatGPTTranscriptCleanupModels() {
        let presets = SummaryModelPreset.chatGPTTranscriptCleanupModels
        #expect(presets.first?.id == "gpt-5.6-terra")
        #expect(presets.first?.label.contains("default") == true)
        #expect(Set(presets.map(\.id)) == Set([
            "gpt-5.4-mini",
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
        ]))

        let backend = TranscriptCleanupBackendOption.hosted(.chatGPT)
        #expect(TranscriptCleanupClient.defaultModel(for: backend) == "gpt-5.6-terra")
        #expect(TranscriptCleanupClient.configuredModel(for: backend, config: AppConfig()) == "gpt-5.6-terra")
    }

    @Test("OpenRouter presets have valid model IDs")
    func openRouterModels() {
        #expect(!SummaryModelPreset.openRouterModels.isEmpty)
        for preset in SummaryModelPreset.openRouterModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("Computer use planner presets use GPT-5.6 Sol by default")
    func computerUsePlannerModels() {
        #expect(SummaryModelPreset.computerUsePlannerModels.first?.id == "gpt-5.6-sol")
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.6-terra" })
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.6-luna" })
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.4-mini" })
        #expect(!SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.5" })
        for preset in SummaryModelPreset.computerUsePlannerModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("GPT-5.6 family uses fixed High reasoning")
    func gpt56ReasoningEffort() {
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.6-sol") == "high")
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.6-terra") == "high")
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.6-luna") == "high")
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.4-mini") == nil)
        #expect(SummaryModelPreset.reasoningEffort(for: "gpt-5.5") == nil)
    }

    @Test("model menu includes custom configured model")
    func modelMenuIncludesCustomConfiguredModel() {
        let customModel = "anthropic/claude-sonnet-4.5"
        let menuPresets = SummaryModelPreset.menuPresets(
            SummaryModelPreset.openRouterModels,
            currentModel: customModel
        )

        #expect(menuPresets.last?.id == customModel)
        #expect(menuPresets.last?.label == "Custom: \(customModel)")
    }

    @Test("model menu does not duplicate known models")
    func modelMenuDoesNotDuplicateKnownModels() {
        let knownModel = SummaryModelPreset.openRouterModels[0].id
        let menuPresets = SummaryModelPreset.menuPresets(
            SummaryModelPreset.openRouterModels,
            currentModel: knownModel
        )

        #expect(menuPresets.count == SummaryModelPreset.openRouterModels.count)
    }

    @Test("OpenRouter catalog selections always persist their exact model ID")
    func openRouterCatalogSelectionPersistsModelID() {
        let dynamicFirstModel = "provider/dynamic-first-model:free"

        #expect(
            OpenRouterModelSelection.persistedModelID(for: dynamicFirstModel) == dynamicFirstModel
        )
        #expect(
            OpenRouterModelSelection.persistedModelID(for: "  \(dynamicFirstModel)  ") == dynamicFirstModel
        )
    }

    @Test("OpenRouter catalog filters free text generation models")
    func openRouterCatalogFiltersFreeTextModels() throws {
        let payload = """
        {
          "data": [
            {
              "id": "openrouter/free",
              "name": "Free Models Router",
              "context_length": 200000,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "google/lyria-3-pro-preview",
              "name": "Google: Lyria 3 Pro Preview",
              "context_length": 1048576,
              "pricing": { "prompt": "0", "completion": "0" },
              "architecture": { "output_modalities": ["text", "audio"] }
            },
            {
              "id": "missing/architecture",
              "name": "Missing Architecture",
              "context_length": 200000,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" }
            },
            {
              "id": "free/small-context",
              "name": "Free Small Context",
              "context_length": 99999,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "paid/model",
              "name": "Paid Model",
              "context_length": 128000,
              "pricing": { "prompt": "0.000001", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "unknown/pricing",
              "name": "Unknown Pricing",
              "context_length": 4096,
              "pricing": { "request": "0" },
              "architecture": { "output_modalities": ["text"] }
            },
            {
              "id": "free/image",
              "name": "Free Image",
              "context_length": 4096,
              "pricing": { "prompt": "0", "completion": "0", "request": "0" },
              "architecture": { "output_modalities": ["image"] }
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(OpenRouterModelCatalog.self, from: payload)
        let presets = OpenRouterModelCatalogFilter.freeTextSummaryPresets(from: catalog.data)

        #expect(presets.map(\.id) == ["openrouter/free"])
        #expect(presets[0].label == "Free Models Router (200k ctx)")
    }
}

@Suite("MeetingSummaryBackendOption")
struct MeetingSummaryBackendTests {

    @Test("all options listed")
    func allOptions() {
        #expect(MeetingSummaryBackendOption.all.count == 6)
        #expect(MeetingSummaryBackendOption.all.contains(.openAI))
        #expect(MeetingSummaryBackendOption.all.contains(.openRouter))
        #expect(MeetingSummaryBackendOption.all.contains(.chatGPT))
        #expect(MeetingSummaryBackendOption.all.contains(.ollama))
        #expect(MeetingSummaryBackendOption.all.contains(.lmStudio))
        #expect(MeetingSummaryBackendOption.all.contains(.customLLM))
    }

    @Test("backend strings are lowercase")
    func backendStrings() {
        #expect(MeetingSummaryBackendOption.openAI.backend == "openai")
        #expect(MeetingSummaryBackendOption.openRouter.backend == "openrouter")
        #expect(MeetingSummaryBackendOption.ollama.backend == "ollama")
        #expect(MeetingSummaryBackendOption.lmStudio.backend == "lmstudio")
        #expect(MeetingSummaryBackendOption.customLLM.backend == "custom_llm")
    }

    @Test("configured values resolve with ChatGPT fallback")
    func resolvedValues() {
        #expect(MeetingSummaryBackendOption.resolved("chatgpt") == .chatGPT)
        #expect(MeetingSummaryBackendOption.resolved("openrouter") == .openRouter)
        #expect(MeetingSummaryBackendOption.resolved("ollama") == .ollama)
        #expect(MeetingSummaryBackendOption.resolved("lmstudio") == .lmStudio)
        #expect(MeetingSummaryBackendOption.resolved("custom_llm") == .customLLM)
        #expect(MeetingSummaryBackendOption.resolved("unknown") == .chatGPT)
        #expect(MeetingSummaryBackendOption.resolved(nil) == .chatGPT)
    }

    @Test("Custom LLM format labels")
    func customLLMFormatLabels() {
        #expect(CustomLLMFormat.openAI.label == "OpenAI-compatible")
        #expect(CustomLLMFormat.anthropic.label == "Anthropic Messages")
    }
}

@Suite("AppConfig")
struct AppConfigTests {

    @Test("default values")
    func defaults() {
        let config = AppConfig()
        #expect(config.sttBackend == BackendOption.parakeetUnified.backend)
        #expect(config.sttModel == BackendOption.parakeetUnified.model)
        #expect(config.meetingInputDeviceUID == nil)
        #expect(config.cohereLanguage == CohereTranscribeLanguage.defaultLanguage.rawValue)
        #expect(config.indicASRLanguage == IndicASRLanguage.defaultLanguage.rawValue)
        #expect(config.whisperLanguage == WhisperKitLanguage.defaultLanguage.rawValue)
        #expect(config.appleSpeechLanguage == AppleSpeechLanguageOption.systemIdentifier)
        #expect(config.meetingTranscriptionBackend == BackendOption.whisper.backend)
        #expect(config.meetingTranscriptionModel == BackendOption.whisper.model)
        #expect(config.meetingSummaryBackend == "chatgpt")
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.meetingRecordingSavePolicy == .never)
        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.scheduledMeetingNotificationLeadTime == .atStart)
        #expect(config.showMeetingDetectionNotification == true)
        #expect(config.mutedMeetingDetectionAppBundleIDs.isEmpty)
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.meetingRecordingFileFormat == MeetingRecordingFileFormat.m4a.rawValue)
        #expect(config.resolvedMeetingRecordingFileFormat == .m4a)
        #expect(config.openRouterAPIKey.isEmpty)
        #expect(config.meetingSummaryRetryCount == MeetingSummaryRetryPolicy.defaultRetryCount)
        #expect(config.ollamaURL == "http://localhost:11434")
        #expect(config.ollamaModel == "qwen3.5")
        #expect(config.lmStudioURL == "http://localhost:1234")
        #expect(config.lmStudioModel.isEmpty)
        #expect(config.customLLMURL.isEmpty)
        #expect(config.customLLMAPIKey.isEmpty)
        #expect(config.customLLMModel.isEmpty)
        #expect(config.customLLMFormat == "openai")
        #expect(config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(config.postProcessorChatGPTModel.isEmpty)
        #expect(config.postProcessorOpenAIModel.isEmpty)
        #expect(config.postProcessorOpenRouterModel.isEmpty)
        #expect(config.postProcessorOllamaModel.isEmpty)
        #expect(config.postProcessorLMStudioModel.isEmpty)
        #expect(config.postProcessorCustomLLMModel.isEmpty)
        #expect(config.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(config.customTranscriptCleanupPrompts.isEmpty)
        #expect(config.enableScreenContext == false)
        #expect(config.enableDictationOCRContext == false)
        #expect(config.enableLiveStreamingPartials == false)
        #expect(config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU)
        #expect(config.showMeetingTranscriptOnIndicatorHover == true)
        #expect(config.dictationHotkey == .default)
        #expect(config.computerUseHotkey == .computerUseDefault)
        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        #expect(config.enableComputerUsePlanner == true)
        #expect(config.computerUsePlannerModel.isEmpty)
        #expect(config.computerUseTimeoutSeconds == 120)
        #expect(config.hotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.computerUseHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.meetingRecordingHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds)
        #expect(config.showFloatingIndicator == true)
        #expect(config.indicatorAnchor == .midTrailing)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.resolvedOnboardingUseCase == .dictation)
        #expect(config.userName.isEmpty)
        #expect(config.customMeetingTemplates.isEmpty)
        #expect(config.meetingHookEnabled == false)
        #expect(config.meetingHookPath.isEmpty)
        #expect(config.meetingHookTimeoutSeconds == 30)
        #expect(config.autoExportMarkdownEnabled == false)
        #expect(config.autoExportMarkdownFolderPath.isEmpty)
        #expect(config.autoExportMarkdownContent == MeetingExportContent.notes.rawValue)
        #expect(config.resolvedAutoExportMarkdownContent == .notes)
        #expect(config.autoExportFileFormat == MeetingAutoExportFileFormat.markdown.rawValue)
        #expect(config.resolvedAutoExportFileFormat == .markdown)
        #expect(config.contributionPromptNextWordCount == nil)
        #expect(config.contributionPromptNextMeetingCount == nil)
        #expect(config.contributionGitHubStarClicked == false)
        #expect(config.contributionBuyMeCoffeeClicked == false)
        #expect(config.contributionTweetClicked == false)
        #expect(config.contributionLinkedInClicked == false)
        #expect(config.upcomingMeetingsDayCount == UpcomingMeetingsWindow.defaultDayCount)
        #expect(config.hiddenCalendarEventSourceHints.isEmpty)
    }

    @Test("LM Studio cleanup readiness requires model and valid URL")
    func lmStudioCleanupReadinessRequiresModelAndValidURL() {
        let backend = TranscriptCleanupBackendOption.hosted(.lmStudio)
        var config = AppConfig()
        config.postProcessorLMStudioModel = "local-cleanup-model"
        config.lmStudioURL = "not a url"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.lmStudioURL = "http://localhost:1234"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))
    }

    @Test("Ollama cleanup readiness requires valid URL")
    func ollamaCleanupReadinessRequiresValidURL() {
        let backend = TranscriptCleanupBackendOption.hosted(.ollama)
        var config = AppConfig()

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.ollamaURL = "not a url"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.ollamaURL = "http://localhost:11434"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))
    }

    @Test("Custom LLM cleanup readiness requires model and explicit valid URL")
    func customLLMCleanupReadinessRequiresModelAndExplicitValidURL() {
        let backend = TranscriptCleanupBackendOption.hosted(.customLLM)
        var config = AppConfig()
        config.postProcessorCustomLLMModel = "cleanup-model"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMURL = "not a url"

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMURL = "http://localhost:8080"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        config.customLLMAPIKey = ""

        #expect(!TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))

        config.customLLMAPIKey = "sk-ant-test"

        #expect(TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: false
        ))
    }

    @Test("OpenRouter cleanup key uses environment, stored credential, then legacy config")
    func openRouterCleanupKeyPrecedence() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-openrouter-resolution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let credentialStore = OpenRouterCredentialStore(supportDirectory: supportDirectory)
        var config = AppConfig()
        config.openRouterAPIKey = ""

        #expect(TranscriptCleanupClient.resolvedOpenRouterAPIKey(
            config: config,
            environment: ["OPENROUTER_API_KEY": "sk-or-env"],
            credentialStore: credentialStore
        ) == "sk-or-env")

        try credentialStore.save(OpenRouterCredential(apiKey: "sk-or-stored", userID: nil))
        config.openRouterAPIKey = " sk-or-config "

        #expect(TranscriptCleanupClient.resolvedOpenRouterAPIKey(
            config: config,
            environment: [:],
            credentialStore: credentialStore
        ) == "sk-or-stored")

        try credentialStore.delete()
        #expect(TranscriptCleanupClient.resolvedOpenRouterAPIKey(
            config: config,
            environment: [:],
            credentialStore: credentialStore
        ) == "sk-or-config")
    }

    @Test("JSON encode/decode round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.openAIAPIKey = "sk-test-key-123"
        config.userName = "Test User"
        config.hasCompletedOnboarding = true
        config.onboardingUseCase = OnboardingUseCase.dictationAndMeetings.rawValue
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.indicASRLanguage = IndicASRLanguage.tamil.rawValue
        config.appleSpeechLanguage = "en-GB"
        config.defaultMeetingTemplateID = "weekly-team-meeting"
        config.meetingRecordingSavePolicy = .always
        config.meetingRecordingFileFormat = MeetingRecordingFileFormat.wav.rawValue
        config.customMeetingTemplates = [
            CustomMeetingTemplate(
                id: "tmpl_123",
                name: "Customer Follow-Up",
                prompt: "## Summary",
                icon: "dollarsign.circle"
            )
        ]
        config.meetingHookEnabled = true
        config.meetingHookPath = "/tmp/meeting-hook.sh"
        config.meetingHookTimeoutSeconds = 45
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = "/tmp/muesli-auto-export"
        config.autoExportMarkdownContent = MeetingExportContent.fullMeeting.rawValue
        config.autoExportFileFormat = MeetingAutoExportFileFormat.markdownAndPDF.rawValue
        config.showScheduledMeetingNotifications = false
        config.scheduledMeetingNotificationLeadTime = .threeMinutes
        config.showMeetingDetectionNotification = false
        config.mutedMeetingDetectionAppBundleIDs = ["com.google.Chrome", "com.tinyspeck.slackmacgap"]
        config.computerUseHotkey = HotkeyConfig(keyCode: 62, label: "Right Ctrl")
        config.enableComputerUseHotkey = false
        config.enableComputerUsePlanner = false
        config.computerUsePlannerModel = "gpt-5.4"
        config.computerUseTimeoutSeconds = 180
        config.hotkeyTriggerThresholdMS = 125
        config.computerUseHotkeyTriggerThresholdMS = 350
        config.meetingRecordingHotkeyTriggerThresholdMS = 900
        config.lmStudioURL = "http://localhost:1234"
        config.lmStudioModel = "local-model"
        config.customLLMURL = "https://example.com"
        config.customLLMAPIKey = "custom-key"
        config.customLLMModel = "custom-model"
        config.customLLMFormat = "anthropic"
        config.meetingSummaryRetryCount = 5
        config.postProcessorBackend = TranscriptCleanupBackendOption.hosted(.openRouter).backend
        config.postProcessorChatGPTModel = "gpt-5.4-mini"
        config.postProcessorOpenAIModel = "gpt-5.4-mini"
        config.postProcessorOpenRouterModel = "openrouter/test-model"
        config.postProcessorOllamaModel = "qwen3.5"
        config.postProcessorLMStudioModel = "lmstudio-loaded"
        config.postProcessorCustomLLMModel = "custom-cleanup"
        config.activeTranscriptCleanupPromptId = "cleanup_custom_1"
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(
                id: "cleanup_custom_1",
                name: "Strict Dictation",
                prompt: "Preserve labels and quotes."
            )
        ]
        config.postProcessorSystemPrompt = "Preserve labels and quotes."
        config.enableScreenContext = true
        config.enableDictationOCRContext = true
        config.enableLiveStreamingPartials = true
        config.meetingInputDeviceUID = "meeting-mic"
        config.enableAutomaticDiagnosticIssuePrompts = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue
        config.showMeetingTranscriptOnIndicatorHover = false
        config.contributionPromptNextWordCount = 31_000
        config.contributionPromptNextMeetingCount = 75
        config.contributionGitHubStarClicked = true
        config.contributionBuyMeCoffeeClicked = false
        config.contributionTweetClicked = true
        config.contributionLinkedInClicked = false
        config.upcomingMeetingsDayCount = UpcomingMeetingsWindow.today.dayCount
        config.hiddenCalendarEventSourceHints = [
            "ek-event-1": UnifiedCalendarEvent.CalendarSource.eventKit.rawValue,
            "google-event-1": UnifiedCalendarEvent.CalendarSource.googleCalendar.rawValue,
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.openAIAPIKey == "sk-test-key-123")
        #expect(decoded.userName == "Test User")
        #expect(decoded.hasCompletedOnboarding == true)
        #expect(decoded.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(decoded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(decoded.indicASRLanguage == IndicASRLanguage.tamil.rawValue)
        #expect(decoded.appleSpeechLanguage == "en-GB")
        #expect(decoded.defaultMeetingTemplateID == "weekly-team-meeting")
        #expect(decoded.meetingRecordingSavePolicy == .always)
        #expect(decoded.meetingRecordingFileFormat == MeetingRecordingFileFormat.wav.rawValue)
        #expect(decoded.resolvedMeetingRecordingFileFormat == .wav)
        #expect(decoded.customMeetingTemplates.count == 1)
        #expect(decoded.customMeetingTemplates.first?.name == "Customer Follow-Up")
        #expect(decoded.customMeetingTemplates.first?.icon == "dollarsign.circle")
        #expect(decoded.meetingHookEnabled == true)
        #expect(decoded.meetingHookPath == "/tmp/meeting-hook.sh")
        #expect(decoded.meetingHookTimeoutSeconds == 45)
        #expect(decoded.autoExportMarkdownEnabled == true)
        #expect(decoded.autoExportMarkdownFolderPath == "/tmp/muesli-auto-export")
        #expect(decoded.autoExportMarkdownContent == MeetingExportContent.fullMeeting.rawValue)
        #expect(decoded.resolvedAutoExportMarkdownContent == .fullMeeting)
        #expect(decoded.autoExportFileFormat == MeetingAutoExportFileFormat.markdownAndPDF.rawValue)
        #expect(decoded.resolvedAutoExportFileFormat == .markdownAndPDF)
        #expect(decoded.showScheduledMeetingNotifications == false)
        #expect(decoded.scheduledMeetingNotificationLeadTime == .threeMinutes)
        #expect(decoded.showMeetingDetectionNotification == false)
        #expect(decoded.mutedMeetingDetectionAppBundleIDs == ["com.google.Chrome", "com.tinyspeck.slackmacgap"])
        #expect(decoded.meetingTranscriptionBackend == config.meetingTranscriptionBackend)
        #expect(decoded.indicatorAnchor == config.indicatorAnchor)
        #expect(decoded.computerUseHotkey == HotkeyConfig(keyCode: 62, label: "Right Ctrl"))
        #expect(decoded.enableComputerUseHotkey == false)
        #expect(decoded.enableComputerUsePlanner == false)
        #expect(decoded.computerUsePlannerModel == "gpt-5.4")
        #expect(decoded.computerUseTimeoutSeconds == 180)
        #expect(decoded.hotkeyTriggerThresholdMS == 125)
        #expect(decoded.computerUseHotkeyTriggerThresholdMS == 350)
        #expect(decoded.meetingRecordingHotkeyTriggerThresholdMS == 900)
        #expect(decoded.lmStudioURL == "http://localhost:1234")
        #expect(decoded.lmStudioModel == "local-model")
        #expect(decoded.customLLMURL == "https://example.com")
        #expect(decoded.customLLMAPIKey == "custom-key")
        #expect(decoded.customLLMModel == "custom-model")
        #expect(decoded.customLLMFormat == "anthropic")
        #expect(decoded.meetingSummaryRetryCount == 5)
        #expect(decoded.postProcessorBackend == "openrouter")
        #expect(decoded.postProcessorChatGPTModel == "gpt-5.4-mini")
        #expect(decoded.postProcessorOpenAIModel == "gpt-5.4-mini")
        #expect(decoded.postProcessorOpenRouterModel == "openrouter/test-model")
        #expect(decoded.postProcessorOllamaModel == "qwen3.5")
        #expect(decoded.postProcessorLMStudioModel == "lmstudio-loaded")
        #expect(decoded.postProcessorCustomLLMModel == "custom-cleanup")
        #expect(decoded.activeTranscriptCleanupPromptId == "cleanup_custom_1")
        #expect(decoded.customTranscriptCleanupPrompts.count == 1)
        #expect(decoded.customTranscriptCleanupPrompts.first?.name == "Strict Dictation")
        #expect(decoded.postProcessorSystemPrompt == "Preserve labels and quotes.")
        #expect(decoded.enableScreenContext == true)
        #expect(decoded.enableDictationOCRContext == true)
        #expect(decoded.enableLiveStreamingPartials == true)
        #expect(decoded.meetingInputDeviceUID == "meeting-mic")
        #expect(decoded.enableAutomaticDiagnosticIssuePrompts == true)
        #expect(decoded.resolvedMeetingLiveCaptionBackend == .nemotron35)
        #expect(decoded.showMeetingTranscriptOnIndicatorHover == false)
        #expect(decoded.contributionPromptNextWordCount == 31_000)
        #expect(decoded.contributionPromptNextMeetingCount == 75)
        #expect(decoded.contributionGitHubStarClicked == true)
        #expect(decoded.contributionBuyMeCoffeeClicked == false)
        #expect(decoded.contributionTweetClicked == true)
        #expect(decoded.contributionLinkedInClicked == false)
        #expect(decoded.upcomingMeetingsDayCount == UpcomingMeetingsWindow.today.dayCount)
        #expect(decoded.hiddenCalendarEventSourceHints == config.hiddenCalendarEventSourceHints)
    }

    @Test("Automatic diagnostic issue prompts default off when absent")
    func automaticDiagnosticIssuePromptsDefaultOffWhenAbsent() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        #expect(decoded.enableAutomaticDiagnosticIssuePrompts == false)
    }

    @Test("JSON coding keys use snake_case")
    func snakeCaseKeys() throws {
        var config = AppConfig()
        config.contributionPromptNextWordCount = 1_000
        config.contributionPromptNextMeetingCount = 25
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["stt_backend"] != nil)
        #expect(json["stt_model"] != nil)
        #expect(json["computer_use_hotkey"] != nil)
        #expect(json["enable_computer_use_hotkey"] != nil)
        #expect(json["computer_use_hotkey_default_disabled_migration_applied"] != nil)
        #expect(json["enable_computer_use_planner"] != nil)
        #expect(json["computer_use_planner_model"] != nil)
        #expect(json["computer_use_timeout_seconds"] != nil)
        #expect(json["hotkey_trigger_threshold_ms"] != nil)
        #expect(json["computer_use_hotkey_trigger_threshold_ms"] != nil)
        #expect(json["meeting_recording_hotkey_trigger_threshold_ms"] != nil)
        #expect(json["cohere_language"] != nil)
        #expect(json["indic_asr_language"] != nil)
        #expect(json["whisper_language"] != nil)
        #expect(json["meeting_transcription_backend"] != nil)
        #expect(json["meeting_transcription_model"] != nil)
        #expect(json["indicator_anchor"] != nil)
        #expect(json["has_completed_onboarding"] != nil)
        #expect(json["onboarding_use_case"] != nil)
        #expect(json["user_name"] != nil)
        #expect(json["default_meeting_template_id"] != nil)
        #expect(json["meeting_recording_save_policy"] != nil)
        #expect(json["meeting_recording_file_format"] != nil)
        #expect(json["show_scheduled_meeting_notifications"] != nil)
        #expect(json["show_meeting_detection_notification"] != nil)
        #expect(json["muted_meeting_detection_app_bundle_ids"] != nil)
        #expect(json["custom_meeting_templates"] != nil)
        #expect(json["meeting_hook_enabled"] != nil)
        #expect(json["meeting_hook_path"] != nil)
        #expect(json["meeting_hook_timeout_seconds"] != nil)
        #expect(json["auto_export_markdown_enabled"] != nil)
        #expect(json["auto_export_markdown_folder_path"] != nil)
        #expect(json["auto_export_markdown_content"] != nil)
        #expect(json["auto_export_file_format"] != nil)
        #expect(json["contribution_prompt_next_word_count"] != nil)
        #expect(json["contribution_prompt_next_meeting_count"] != nil)
        #expect(json["contribution_github_star_clicked"] != nil)
        #expect(json["contribution_buy_me_coffee_clicked"] != nil)
        #expect(json["contribution_tweet_clicked"] != nil)
        #expect(json["contribution_linkedin_clicked"] != nil)
        #expect(json["lmstudio_url"] != nil)
        #expect(json["lmstudio_model"] != nil)
        #expect(json["custom_llm_url"] != nil)
        #expect(json["custom_llm_api_key"] != nil)
        #expect(json["custom_llm_model"] != nil)
        #expect(json["custom_llm_format"] != nil)
        #expect(json["meeting_summary_retry_count"] != nil)
        #expect(json["post_processor_backend"] != nil)
        #expect(json["post_processor_chatgpt_model"] != nil)
        #expect(json["post_processor_openai_model"] != nil)
        #expect(json["post_processor_openrouter_model"] != nil)
        #expect(json["post_processor_ollama_model"] != nil)
        #expect(json["post_processor_lmstudio_model"] != nil)
        #expect(json["post_processor_custom_llm_model"] != nil)
        #expect(json["active_transcript_cleanup_prompt_id"] != nil)
        #expect(json["custom_transcript_cleanup_prompts"] != nil)
        #expect(json["enable_screen_context"] != nil)
        #expect(json["enable_dictation_ocr_context"] != nil)
        #expect(json["enable_live_streaming_partials"] != nil)
        #expect(json["show_meeting_transcript_on_indicator_hover"] != nil)
    }

    @Test("decodes screen context flags from snake_case")
    func decodesScreenContextFlagsFromSnakeCase() throws {
        let json = """
        {
            "enable_screen_context": true,
            "enable_dictation_ocr_context": true
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.enableScreenContext == true)
        #expect(config.enableDictationOCRContext == true)
    }

    @Test("decodes with missing fields using defaults")
    func missingFieldsUseDefaults() throws {
        let json = "{\"stt_backend\": \"whisper\"}"
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.showFloatingIndicator == true)
        #expect(config.resolvedCohereLanguage == .english)
        #expect(config.resolvedIndicASRLanguage == .defaultLanguage)
        #expect(config.resolvedWhisperLanguage == .auto)
        #expect(config.resolvedAppleSpeechLanguage == AppleSpeechLanguageOption.systemIdentifier)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.resolvedOnboardingUseCase == .dictation)
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.upcomingMeetingsDayCount == UpcomingMeetingsWindow.threeDays.dayCount)
        #expect(config.hiddenCalendarEventSourceHints.isEmpty)
        #expect(config.meetingRecordingSavePolicy == .never)
        #expect(config.meetingRecordingFileFormat == MeetingRecordingFileFormat.m4a.rawValue)
        #expect(config.resolvedMeetingRecordingFileFormat == .m4a)
        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.showMeetingDetectionNotification == true)
        #expect(config.mutedMeetingDetectionAppBundleIDs.isEmpty)
        #expect(config.customMeetingTemplates.isEmpty)
        #expect(config.computerUseHotkey == .computerUseDefault)
        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        #expect(config.enableComputerUsePlanner == true)
        #expect(config.computerUsePlannerModel.isEmpty)
        #expect(config.computerUseTimeoutSeconds == 120)
        #expect(config.hotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.computerUseHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds)
        #expect(config.meetingRecordingHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds)
        #expect(config.meetingHookEnabled == false)
        #expect(config.meetingHookPath.isEmpty)
        #expect(config.meetingHookTimeoutSeconds == 30)
        #expect(config.autoExportMarkdownEnabled == false)
        #expect(config.autoExportMarkdownFolderPath.isEmpty)
        #expect(config.autoExportMarkdownContent == MeetingExportContent.notes.rawValue)
        #expect(config.resolvedAutoExportMarkdownContent == .notes)
        #expect(config.autoExportFileFormat == MeetingAutoExportFileFormat.markdown.rawValue)
        #expect(config.resolvedAutoExportFileFormat == .markdown)
        #expect(config.lmStudioURL == "http://localhost:1234")
        #expect(config.lmStudioModel.isEmpty)
        #expect(config.customLLMURL.isEmpty)
        #expect(config.customLLMAPIKey.isEmpty)
        #expect(config.customLLMModel.isEmpty)
        #expect(config.customLLMFormat == "openai")
        #expect(config.meetingSummaryRetryCount == MeetingSummaryRetryPolicy.defaultRetryCount)
        #expect(config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(config.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(config.customTranscriptCleanupPrompts.isEmpty)
        #expect(config.enableScreenContext == false)
        #expect(config.enableDictationOCRContext == false)
        #expect(config.enableLiveStreamingPartials == false)
        #expect(config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU)
        #expect(config.showMeetingTranscriptOnIndicatorHover == true)
    }

    @Test("legacy meeting config preserves its transcription model and leaves streaming off")
    func legacyMeetingConfigPreservesTranscriptionModel() throws {
        let json = """
        {
          "stt_backend": "fluidaudio",
          "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "has_completed_onboarding": true,
          "onboarding_use_case": "meetings"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.sttBackend == BackendOption.parakeetMultilingual.backend)
        #expect(config.sttModel == BackendOption.parakeetMultilingual.model)
        #expect(config.meetingTranscriptionBackend == BackendOption.parakeetMultilingual.backend)
        #expect(config.meetingTranscriptionModel == BackendOption.parakeetMultilingual.model)
        #expect(config.enableLiveStreamingPartials == false)
    }

    @Test("meeting summary retry count is clamped on decode")
    func meetingSummaryRetryCountIsClampedOnDecode() throws {
        let negativeConfig = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"meeting_summary_retry_count": -3}"#.utf8)
        )
        let excessiveConfig = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"meeting_summary_retry_count": 99}"#.utf8)
        )

        #expect(negativeConfig.meetingSummaryRetryCount == 0)
        #expect(excessiveConfig.meetingSummaryRetryCount == MeetingSummaryRetryPolicy.maximumRetryCount)
    }

    @Test("unknown cleanup backend resolves to local")
    func unknownCleanupBackendResolvesToLocal() throws {
        let json = """
        {
          "post_processor_backend": "future_provider"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
        #expect(TranscriptCleanupBackendOption.resolved(config.postProcessorBackend) == .local)
    }

    @Test("missing cleanup prompt preset falls back to built-in default")
    func missingCleanupPromptPresetFallsBackToDefault() throws {
        let json = """
        {
          "active_transcript_cleanup_prompt_id": "deleted-preset",
          "post_processor_system_prompt": "Legacy user-edited cleanup prompt"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(config.postProcessorSystemPrompt == PostProcessorOption.defaultSystemPrompt)
        #expect(
            TranscriptCleanupPrompts
                .resolve(id: config.activeTranscriptCleanupPromptId, custom: config.customTranscriptCleanupPrompts)
                .prompt == PostProcessorOption.defaultSystemPrompt
        )
    }

    @Test("default cleanup prompt explains app context")
    func defaultCleanupPromptExplainsAppContext() {
        #expect(PostProcessorOption.defaultSystemPrompt.contains("<APP-CONTEXT>"))
        #expect(PostProcessorOption.defaultSystemPrompt.contains("OCR screen text"))
        #expect(PostProcessorOption.defaultSystemPrompt.contains("Never copy app context into the output"))
    }

    @Test("dictation app context prompt includes OCR text")
    func dictationAppContextPromptIncludesOCRText() {
        let ocrText = String(repeating: "a", count: 3_200) + "tail"
        let context = DictationContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            documentContext: "Project Apollo",
            selectedText: "Mercury",
            url: "https://example.com",
            documentIdentifier: "Project Apollo",
            ocrText: ocrText
        )
        let prompt = DictationContextCapture.formatForPrompt(context)

        #expect(prompt.contains("App: Notes (https://example.com)"))
        #expect(prompt.contains("Document context: Project Apollo"))
        #expect(prompt.contains("Selected text: Mercury"))
        #expect(prompt.contains("OCR screen text: "))
        #expect(prompt.contains("tail"))
    }

    @Test("Quill context requires the original app and document identity")
    func quilContextRequiresBoundDocumentIdentity() {
        let matching = DictationContext(
            appName: "Chrome",
            bundleID: "com.google.Chrome",
            documentContext: "Draft",
            selectedText: "Selection",
            url: nil,
            documentIdentifier: "https://docs.google.com/document/d/original",
            ocrText: ""
        )
        let unidentified = DictationContext(
            appName: matching.appName,
            bundleID: matching.bundleID,
            documentContext: matching.documentContext,
            selectedText: matching.selectedText,
            url: matching.url,
            documentIdentifier: nil,
            ocrText: matching.ocrText
        )
        let otherDocument = DictationContext(
            appName: matching.appName,
            bundleID: matching.bundleID,
            documentContext: matching.documentContext,
            selectedText: matching.selectedText,
            url: matching.url,
            documentIdentifier: "https://docs.google.com/document/d/other",
            ocrText: matching.ocrText
        )
        let emptyIdentity = DictationContext(
            appName: matching.appName,
            bundleID: "",
            documentContext: matching.documentContext,
            selectedText: matching.selectedText,
            url: matching.url,
            documentIdentifier: "",
            ocrText: matching.ocrText
        )

        #expect(DictationContextCapture.matchesQuilSelection(
            matching,
            bundleID: "com.google.Chrome",
            documentIdentifier: "https://docs.google.com/document/d/original"
        ))
        #expect(!DictationContextCapture.matchesQuilSelection(
            unidentified,
            bundleID: "com.google.Chrome",
            documentIdentifier: "https://docs.google.com/document/d/original"
        ))
        #expect(!DictationContextCapture.matchesQuilSelection(
            otherDocument,
            bundleID: "com.google.Chrome",
            documentIdentifier: "https://docs.google.com/document/d/original"
        ))
        #expect(!DictationContextCapture.matchesQuilSelection(
            matching,
            bundleID: "com.apple.Safari",
            documentIdentifier: "https://docs.google.com/document/d/original"
        ))
        #expect(!DictationContextCapture.matchesQuilSelection(
            emptyIdentity,
            bundleID: "",
            documentIdentifier: ""
        ))
        #expect(!DictationContextCapture.matchesQuilSelection(
            matching,
            bundleID: "   ",
            documentIdentifier: "https://docs.google.com/document/d/original"
        ))
    }

    @Test("screen OCR binds to the focused accessibility window")
    func screenOCRBindsToFocusedAccessibilityWindow() {
        let focusedFrame = CGRect(x: 500, y: 80, width: 900, height: 700)
        let candidates = [
            ScreenContextCapture.WindowCandidate(
                id: 41,
                frame: CGRect(x: 20, y: 80, width: 900, height: 700),
                title: "Unrelated document"
            ),
            ScreenContextCapture.WindowCandidate(
                id: 42,
                frame: focusedFrame,
                title: "Focused document"
            ),
        ]

        #expect(ScreenContextCapture.focusedWindowID(
            from: candidates,
            focusedFrame: focusedFrame,
            focusedTitle: "Focused document",
            requiresTitleMatch: true
        ) == 42)
        #expect(ScreenContextCapture.focusedWindowID(
            from: candidates,
            focusedFrame: CGRect(x: 1_500, y: 80, width: 900, height: 700),
            focusedTitle: "Missing document"
        ) == nil)

        let ambiguous = [
            ScreenContextCapture.WindowCandidate(id: 51, frame: focusedFrame, title: ""),
            ScreenContextCapture.WindowCandidate(id: 52, frame: focusedFrame, title: ""),
        ]
        #expect(ScreenContextCapture.focusedWindowID(
            from: ambiguous,
            focusedFrame: focusedFrame,
            focusedTitle: ""
        ) == nil)

        let titleDisambiguated = [
            ScreenContextCapture.WindowCandidate(id: 61, frame: focusedFrame, title: "Other document"),
            ScreenContextCapture.WindowCandidate(id: 62, frame: focusedFrame, title: "Focused document"),
        ]
        #expect(ScreenContextCapture.focusedWindowID(
            from: titleDisambiguated,
            focusedFrame: focusedFrame,
            focusedTitle: "focused document"
        ) == 62)

        let frameOnlyCandidate = [
            ScreenContextCapture.WindowCandidate(
                id: 71,
                frame: focusedFrame,
                title: "Private payroll"
            ),
        ]
        #expect(ScreenContextCapture.focusedWindowID(
            from: frameOnlyCandidate,
            focusedFrame: focusedFrame,
            focusedTitle: "Focused document",
            requiresTitleMatch: true
        ) == nil)
        #expect(ScreenContextCapture.focusedWindowID(
            from: frameOnlyCandidate,
            focusedFrame: focusedFrame,
            focusedTitle: "",
            requiresTitleMatch: true
        ) == nil)
        #expect(ScreenContextCapture.focusedWindowID(
            from: frameOnlyCandidate,
            focusedFrame: focusedFrame,
            focusedTitle: "Focused document"
        ) == 71)
    }

    @Test("post processor input caps app context")
    func postProcessorInputCapsAppContext() {
        let prompt = Qwen3PostProcessorConfig.formatInput(
            "hello",
            appContext: String(repeating: "a", count: 20),
            maxAppContextCharacters: 5
        )

        #expect(prompt.contains("<APP-CONTEXT>\naaaaa\n</APP-CONTEXT>"))
        #expect(prompt.contains("<USER-INPUT>\nhello\n</USER-INPUT>"))
    }

    @Test("S1-mini input uses its exact trained control line")
    func s1MiniInputUsesTrainedControlLine() {
        #expect(
            Qwen3PostProcessorConfig.formatS1MiniInput("um send it friday") ==
                "[Styling: semi-formal] [Structure: prose] [Context: general]\num send it friday"
        )
    }

    @Test("hosted cleanup augments custom prompts when app context is present")
    func hostedCleanupAugmentsCustomPromptsWhenAppContextIsPresent() {
        let prompt = TranscriptCleanupClient.systemPromptWithAppContextGuidance(
            "Preserve the user's words.",
            appContext: "App: Notes"
        )

        #expect(prompt.contains("Preserve the user's words."))
        #expect(prompt.contains("<APP-CONTEXT>"))
        #expect(prompt.contains("OCR screen text"))
    }

    @Test("hosted cleanup does not duplicate app context guidance")
    func hostedCleanupDoesNotDuplicateAppContextGuidance() {
        let prompt = TranscriptCleanupClient.systemPromptWithAppContextGuidance(
            PostProcessorOption.defaultSystemPrompt,
            appContext: "App: Notes"
        )

        #expect(prompt == PostProcessorOption.defaultSystemPrompt)
    }

    @Test("unsupported ChatGPT model selections fall back to default")
    func unsupportedChatGPTModelSelectionsFallBackToDefault() throws {
        let json = """
        {
          "chatgpt_model": "chat-latest",
          "post_processor_chatgpt_model": "gpt-5.4-nano"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.chatGPTModel.isEmpty)
        #expect(config.postProcessorChatGPTModel.isEmpty)
    }

    @Test("stored GPT-5.5 selections migrate to GPT-5.6 Sol")
    func storedGPT55SelectionsMigrateToSol() throws {
        let json = """
        {
          "computer_use_planner_model": "gpt-5.5",
          "openai_model": "gpt-5.5",
          "chatgpt_model": "gpt-5.5",
          "post_processor_openai_model": "gpt-5.5",
          "post_processor_chatgpt_model": "gpt-5.5"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.computerUsePlannerModel == "gpt-5.6-sol")
        #expect(config.openAIModel == "gpt-5.6-sol")
        #expect(config.chatGPTModel == "gpt-5.6-sol")
        #expect(config.postProcessorOpenAIModel == "gpt-5.6-sol")
        #expect(config.postProcessorChatGPTModel == "gpt-5.6-sol")
    }

    @Test("legacy completed onboarding enables meetings when use case is missing")
    func legacyCompletedOnboardingEnablesMeetingsWhenUseCaseMissing() throws {
        let json = """
        {
          "has_completed_onboarding": true,
          "stt_backend": "fluidaudio",
          "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.hasCompletedOnboarding)
        #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(config.resolvedOnboardingUseCase.includesMeetings)
    }

    @Test("legacy completed onboarding enables meetings when use case is malformed")
    func legacyCompletedOnboardingEnablesMeetingsWhenUseCaseMalformed() throws {
        let jsonCases = [
            """
            {
              "has_completed_onboarding": true,
              "onboarding_use_case": null
            }
            """,
            """
            {
              "has_completed_onboarding": true,
              "onboarding_use_case": 7
            }
            """,
            """
            {
              "has_completed_onboarding": true,
              "onboarding_use_case": "future-meeting-mode"
            }
            """
        ]

        for json in jsonCases {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

            #expect(config.hasCompletedOnboarding)
            #expect(config.resolvedOnboardingUseCase == .dictationAndMeetings)
            #expect(config.resolvedOnboardingUseCase.includesMeetings)
        }
    }

    @Test("incomplete onboarding defaults malformed use case to dictation")
    func incompleteOnboardingDefaultsMalformedUseCaseToDictation() throws {
        let jsonCases = [
            """
            {
              "has_completed_onboarding": false
            }
            """,
            """
            {
              "has_completed_onboarding": false,
              "onboarding_use_case": null
            }
            """,
            """
            {
              "has_completed_onboarding": false,
              "onboarding_use_case": "future-meeting-mode"
            }
            """
        ]

        for json in jsonCases {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

            #expect(!config.hasCompletedOnboarding)
            #expect(config.resolvedOnboardingUseCase == .dictation)
            #expect(!config.resolvedOnboardingUseCase.includesMeetings)
        }
    }

    @Test("explicit completed dictation-only onboarding remains dictation-only")
    func explicitCompletedDictationOnlyOnboardingRemainsDictationOnly() throws {
        let json = """
        {
          "has_completed_onboarding": true,
          "onboarding_use_case": "dictation"
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.hasCompletedOnboarding)
        #expect(config.resolvedOnboardingUseCase == .dictation)
        #expect(!config.resolvedOnboardingUseCase.includesMeetings)
    }

    @Test("computer use default avoids existing right command dictation hotkey")
    func computerUseDefaultAvoidsExistingRightCommandDictationHotkey() throws {
        let json = """
        {
          "dictation_hotkey": {
            "keyCode": 54,
            "label": "Right Cmd"
          }
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationHotkey == HotkeyConfig(keyCode: 54, label: "Right Cmd"))
        #expect(config.computerUseHotkey == .default)
        #expect(config.enableComputerUseHotkey == false)
    }

    @Test("legacy computer use hotkey enabled config is disabled once")
    func legacyComputerUseHotkeyEnabledConfigIsDisabledOnce() throws {
        let json = """
        {
          "enable_computer_use_hotkey": true,
          "enable_computer_use_planner": true
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        #expect(config.enableComputerUsePlanner == true)
    }

    @Test("computer use hotkey remains enabled after migration is applied")
    func computerUseHotkeyRemainsEnabledAfterMigrationIsApplied() throws {
        let json = """
        {
          "enable_computer_use_hotkey": true,
          "computer_use_hotkey_default_disabled_migration_applied": true
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.enableComputerUseHotkey == true)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
    }

    @Test("unsupported onboarding use case falls back to dictation")
    func unsupportedOnboardingUseCaseFallsBackToDictation() throws {
        let json = """
        {
          "onboarding_use_case": "unknown"
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.resolvedOnboardingUseCase == .dictation)
    }

    @Test("voice notes use push-to-talk without paste dictation")
    func voiceNotesUsePushToTalkWithoutPasteDictation() {
        #expect(OnboardingUseCase.voiceNotes.includesVoiceNotes)
        #expect(OnboardingUseCase.voiceNotes.includesPushToTalk)
        #expect(!OnboardingUseCase.voiceNotes.includesDictation)
        #expect(!OnboardingUseCase.voiceNotes.includesMeetings)
    }

    @Test("voice notes escape hatch is dictation-only")
    func voiceNotesEscapeHatchIsDictationOnly() {
        #expect(OnboardingUseCase.dictation.canSwitchToVoiceNotesOnly)
        #expect(!OnboardingUseCase.dictationAndMeetings.canSwitchToVoiceNotesOnly)
        #expect(!OnboardingUseCase.meetings.canSwitchToVoiceNotesOnly)
        #expect(!OnboardingUseCase.voiceNotes.canSwitchToVoiceNotesOnly)
    }

    @Test("scheduled meeting notifications inherit legacy detection opt-out")
    func scheduledMeetingNotificationsInheritLegacyDetectionOptOut() throws {
        let json = """
        {
          "show_meeting_detection_notification": false
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.showScheduledMeetingNotifications == false)
        #expect(config.showMeetingDetectionNotification == false)
    }

    @Test("explicit scheduled meeting notification setting overrides legacy detection setting")
    func explicitScheduledMeetingNotificationSettingOverridesLegacyDetectionSetting() throws {
        let json = """
        {
          "show_scheduled_meeting_notifications": true,
          "show_meeting_detection_notification": false
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.showMeetingDetectionNotification == false)
    }

    @Test("unsupported cohere language falls back to english")
    func unsupportedCohereLanguageFallsBackToEnglish() throws {
        let json = """
        {
          "cohere_language": "xx"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.cohereLanguage == CohereTranscribeLanguage.english.rawValue)
        #expect(config.resolvedCohereLanguage == .english)
    }

    @Test("cohere language codes are normalized case-insensitively")
    func cohereLanguageCodesNormalizeCaseInsensitively() throws {
        let json = """
        {
          "cohere_language": " Fr "
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.cohereLanguage == CohereTranscribeLanguage.french.rawValue)
        #expect(config.resolvedCohereLanguage == .french)
    }

    @Test("meeting transcription falls back to dictation model when missing")
    func meetingTranscriptionFallsBackToDictationModel() throws {
        let json = """
        {
          "stt_backend": "whisper",
          "stt_model": "ggml-medium.en"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.meetingTranscriptionBackend == "whisper")
        #expect(config.meetingTranscriptionModel == "ggml-medium.en")
    }

    @Test("English-only Whisper selections keep their exact model identities")
    func englishOnlyWhisperSelectionsKeepExactModels() throws {
        let json = """
        {
          "stt_backend": "whisper",
          "stt_model": "tiny.en",
          "meeting_transcription_backend": "whisper",
          "meeting_transcription_model": "small.en",
          "whisper_model": "medium.en"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.sttModel == BackendOption.whisperTinyEnglish.model)
        #expect(config.meetingTranscriptionModel == BackendOption.whisperSmallEnglish.model)
        #expect(config.whisperModel == BackendOption.whisperMediumEnglish.model)
    }

    @Test("indicator anchor falls back to custom when legacy origin exists")
    func indicatorAnchorFallsBackToCustomForLegacyOrigin() throws {
        let json = """
        {
          "indicator_origin": [640, 320]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.indicatorAnchor == .custom)
        #expect(config.indicatorOrigin?.x == 640)
        #expect(config.indicatorOrigin?.y == 320)
    }

    @Test("custom words decode missing threshold with default")
    func customWordsDecodeMissingThresholdWithDefault() throws {
        let json = """
        {
          "custom_words": [
            {
              "id": "67A2A4E9-E707-4A65-B690-124AFA4F0C18",
              "word": "muesli",
              "replacement": "Muesli"
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.customWords.count == 1)
        #expect(config.customWords[0].matchingThreshold == 0.85)
    }

    @Test("custom words clamp thresholds into the supported UI range")
    func customWordsClampThresholdsIntoSupportedRange() throws {
        let json = """
        {
          "custom_words": [
            {
              "word": "aggressive",
              "matching_threshold": 0.1
            },
            {
              "word": "strict",
              "matching_threshold": 1.4
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.customWords.count == 2)
        #expect(config.customWords[0].matchingThreshold == 0.70)
        #expect(config.customWords[1].matchingThreshold == 0.95)
    }

    @Test("custom templates decode missing icon with fallback")
    func customTemplateMissingIconUsesFallback() throws {
        let json = """
        {
          "custom_meeting_templates": [
            {
              "id": "tmpl_123",
              "name": "Customer Follow-Up",
              "prompt": "## Summary"
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.customMeetingTemplates.count == 1)
        #expect(config.customMeetingTemplates.first?.icon == MeetingTemplates.customIconFallback)
    }

    @Test("custom templates normalize invalid icons")
    func customTemplateInvalidIconUsesFallback() {
        let template = CustomMeetingTemplate(
            id: "tmpl_invalid",
            name: "Test",
            prompt: "Prompt",
            icon: "invalid.icon"
        )

        #expect(template.icon == MeetingTemplates.customIconFallback)
        #expect(MeetingTemplates.customDefinition(from: template).icon == MeetingTemplates.customIconFallback)
    }
}

@Suite("HotkeyMonitor")
struct HotkeyMonitorTests {
    final class ManualHotkeyScheduler {
        private struct ScheduledItem {
            let deadline: TimeInterval
            let order: Int
            let item: DispatchWorkItem
        }

        private static let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

        private var now: TimeInterval = 0
        private var nextOrder = 0
        private var scheduled: [ScheduledItem] = []

        func schedule(after delay: TimeInterval, item: DispatchWorkItem) {
            scheduled.append(ScheduledItem(deadline: now + delay, order: nextOrder, item: item))
            nextOrder += 1
        }

        func currentDate() -> Date {
            Date(timeInterval: now, since: Self.referenceDate)
        }

        func advance(by interval: TimeInterval) {
            now += interval
            while let next = scheduled
                .filter({ $0.deadline <= now })
                .min(by: { lhs, rhs in
                    lhs.deadline == rhs.deadline ? lhs.order < rhs.order : lhs.deadline < rhs.deadline
                }) {
                scheduled.removeAll { $0.order == next.order }
                if !next.item.isCancelled {
                    next.item.perform()
                }
            }
        }

        func makeMonitor(
            prepareDelay: TimeInterval = 0.15,
            startDelay: TimeInterval = 0.25,
            doubleTapWindow: TimeInterval = 0.35
        ) -> HotkeyMonitor {
            HotkeyMonitor(
                prepareDelay: prepareDelay,
                startDelay: startDelay,
                doubleTapWindow: doubleTapWindow,
                scheduleAfter: { self.schedule(after: $0, item: $1) },
                now: currentDate
            )
        }
    }

    @Test("escape still cancels active hold dictation immediately")
    func escapeCancelsActiveHoldDictation() async throws {
        let monitor = HotkeyMonitor(
            prepareDelay: 0.01,
            startDelay: 0.02,
            doubleTapWindow: 0.03
        )
        var cancelCount = 0
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.setHoldRecordingActiveForTests()
        monitor.handleKeyDown(keyCode: 53)

        #expect(cancelCount == 1)
    }

    @Test("local monitor skips fresh hotkey starts while editing text")
    @MainActor
    func localMonitorSkipsFreshHotkeyStartsWhileEditingText() async throws {
        let monitor = HotkeyMonitor()
        let textView = NSTextView()

        #expect(
            monitor.shouldHandleLocalEventForTests(
                type: .flagsChanged,
                keyCode: 55,
                firstResponder: textView
            ) == false
        )
    }

    @Test("local monitor preserves key-up cleanup after hotkey session is armed")
    @MainActor
    func localMonitorPreservesKeyUpCleanupAfterHotkeySessionIsArmed() async throws {
        let monitor = HotkeyMonitor()
        let textView = NSTextView()
        var stopCount = 0
        monitor.onStop = {
            stopCount += 1
        }

        monitor.setHoldRecordingActiveForTests()

        #expect(
            monitor.shouldHandleLocalEventForTests(
                type: .flagsChanged,
                keyCode: 55,
                firstResponder: textView
            ) == true
        )

        monitor.handleFlagsChanged(keyCode: 55, flags: [])

        #expect(stopCount == 1)
    }

    @Test("local monitor still lets escape cancel active hold dictation while editing text")
    @MainActor
    func localMonitorLetsEscapeCancelActiveHoldDictationWhileEditingText() async throws {
        let monitor = HotkeyMonitor()
        let textView = NSTextView()

        monitor.setHoldRecordingActiveForTests()

        #expect(
            monitor.shouldHandleLocalEventForTests(
                type: .keyDown,
                keyCode: 53,
                firstResponder: textView
            ) == true
        )
    }

    @Test("trigger threshold derives prepare and start delays")
    func triggerThresholdTiming() {
        #expect(HotkeyTriggerTiming.clampedMilliseconds(10) == HotkeyTriggerTiming.minThresholdMilliseconds)
        #expect(HotkeyTriggerTiming.clampedMilliseconds(2_000) == HotkeyTriggerTiming.maxThresholdMilliseconds)
        #expect(HotkeyTriggerTiming.clampedMilliseconds(2_500) == HotkeyTriggerTiming.maxThresholdMilliseconds)
        #expect(HotkeyTriggerTiming.startDelay(forThresholdMilliseconds: 250) == 0.25)
        #expect(HotkeyTriggerTiming.prepareDelay(forThresholdMilliseconds: 250) == 0.15)
        #expect(HotkeyTriggerTiming.prepareDelay(forThresholdMilliseconds: 100) == 0)
    }

    @Test("low trigger threshold still allows double-tap toggle")
    @MainActor
    func lowTriggerThresholdStillAllowsDoubleTapToggle() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var prepareCount = 0
        var toggleStartCount = 0
        monitor.onPrepare = {
            prepareCount += 1
        }
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command)

        #expect(prepareCount == 0)
        #expect(toggleStartCount == 1)
    }

    @Test("Fn double-tap reuses hands-free start and tap-to-stop lifecycle")
    @MainActor
    func fnDoubleTapHandsFreeLifecycle() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configure(keyCode: 63)
        var toggleStartCount = 0
        var toggleStopCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }
        monitor.onToggleStop = {
            toggleStopCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 63, flags: .function)
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 63, flags: .function)

        #expect(monitor.isToggleRecording)
        #expect(toggleStartCount == 1)

        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        monitor.handleFlagsChanged(keyCode: 63, flags: .function)

        #expect(!monitor.isToggleRecording)
        #expect(toggleStopCount == 1)
    }

    @Test("double-tap outside window arms instead of toggling")
    @MainActor
    func doubleTapOutsideWindowArmsInsteadOfToggling() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var toggleStartCount = 0
        var armCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }
        monitor.onArm = {
            armCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        scheduler.advance(by: 0.40)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command)

        #expect(toggleStartCount == 0)
        #expect(armCount == 2)
    }

    @Test("low trigger threshold arms immediately but defers audio while double-tap is possible")
    @MainActor
    func lowTriggerThresholdArmsImmediatelyButDefersAudio() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var armCount = 0
        var prepareCount = 0
        var startCount = 0
        monitor.onArm = {
            armCount += 1
        }
        monitor.onPrepare = {
            prepareCount += 1
        }
        monitor.onStart = {
            startCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        #expect(armCount == 1)
        scheduler.advance(by: 0.10)
        #expect(prepareCount == 0)
        #expect(startCount == 0)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
    }

    @Test("quick armed tap cancels after double-tap window")
    @MainActor
    func quickArmedTapCancelsAfterDoubleTapWindow() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.05)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var cancelCount = 0
        monitor.onArm = {}
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        #expect(cancelCount == 0)

        scheduler.advance(by: 0.08)
        #expect(cancelCount == 1)
    }

    @Test("low trigger threshold starts quickly when double-tap is disabled")
    @MainActor
    func lowTriggerThresholdStartsQuicklyWhenDoubleTapDisabled() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        monitor.doubleTapEnabled = false
        var startCount = 0
        monitor.onStart = {
            startCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        scheduler.advance(by: 0.10)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])

        #expect(startCount == 1)
    }

    @Test("reconfiguring hotkey during active recording stops cleanly")
    func configureKeyCodeDuringActiveRecordingStopsCleanly() {
        let monitor = HotkeyMonitor()
        var stopCount = 0
        var cancelCount = 0
        monitor.onStop = {
            stopCount += 1
        }
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.setHoldRecordingActiveForTests()
        monitor.configure(keyCode: 56)

        #expect(stopCount == 1)
        #expect(cancelCount == 0)
        #expect(monitor.targetKeyCode == 56)
    }

    @Test("reconfiguring hotkey during pending double tap cancel cancels cleanly")
    @MainActor
    func configureKeyCodeDuringPendingDoubleTapCancelCancelsCleanly() async throws {
        let monitor = HotkeyMonitor(doubleTapWindow: 0.35)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var cancelCount = 0
        monitor.onArm = {}
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        monitor.configure(keyCode: 56)
        try await Task.sleep(for: .milliseconds(380))

        #expect(cancelCount == 1)
        #expect(monitor.targetKeyCode == 56)
    }

    @Test("changing trigger threshold during pending double tap cancel preserves cleanup")
    @MainActor
    func configureTriggerThresholdDuringPendingDoubleTapCancelPreservesCleanup() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(doubleTapWindow: 0.05)
        monitor.configureTriggerThreshold(milliseconds: 75)
        var cancelCount = 0
        monitor.onArm = {}
        monitor.onCancel = {
            cancelCount += 1
        }

        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        monitor.configureTriggerThreshold(milliseconds: 125)
        scheduler.advance(by: 0.08)

        #expect(cancelCount == 1)
    }

    @Test("combination shortcut requires hold threshold before toggling")
    @MainActor
    func combinationShortcutRequiresHoldThresholdBeforeToggling() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.05)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.02)
        monitor.handleCombinationForTests(type: .keyUp, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.05)

        #expect(toggleStartCount == 0)
    }

    @Test("combination shortcut toggles after hold threshold")
    @MainActor
    func combinationShortcutTogglesAfterHoldThreshold() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.03)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.05)

        #expect(toggleStartCount == 1)
    }

    @Test("combination toggle cancellation resets without firing stop")
    @MainActor
    func combinationToggleCancellationResetsWithoutFiringStop() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.03)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        var toggleStopCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }
        monitor.onToggleStop = {
            toggleStopCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.05)
        #expect(monitor.isToggleRecording)

        monitor.cancelToggleMode()

        #expect(!monitor.isToggleRecording)
        #expect(toggleStartCount == 1)
        #expect(toggleStopCount == 0)
    }

    @Test("combination shortcut cancels when modifiers release before threshold")
    @MainActor
    func combinationShortcutCancelsWhenModifiersReleaseBeforeThreshold() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(startDelay: 0.05)
        monitor.configure(HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15))
        var toggleStartCount = 0
        monitor.onToggleStart = {
            toggleStartCount += 1
        }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        scheduler.advance(by: 0.02)
        monitor.handleCombinationForTests(type: .flagsChanged, keyCode: 56, flags: .command)
        scheduler.advance(by: 0.05)

        #expect(toggleStartCount == 0)
    }

    @Test("combination shortcut can reuse push-to-talk lifecycle")
    @MainActor
    func combinationShortcutPushToTalkLifecycle() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(prepareDelay: 0.02, startDelay: 0.05)
        monitor.configure(HotkeyConfig.combination(modifiers: [.control], keyCode: 12))
        monitor.combinationActivation = .pushToTalk
        monitor.doubleTapEnabled = false
        var events: [String] = []
        monitor.onPrepare = { events.append("prepare") }
        monitor.onStart = { events.append("start") }
        monitor.onStop = { events.append("stop") }

        monitor.handleCombinationForTests(type: .keyDown, keyCode: 12, flags: .control)
        scheduler.advance(by: 0.06)
        monitor.handleCombinationForTests(type: .keyUp, keyCode: 12, flags: .control)

        #expect(events == ["prepare", "start", "stop"])
    }

    @Test("escape cancels a Carbon-style registered combination session")
    @MainActor
    func escapeCancelsRegisteredCombinationSession() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor()
        monitor.configure(HotkeyConfig.combination(modifiers: [.control], keyCode: 12))
        monitor.combinationActivation = .pushToTalk
        var cancelCount = 0
        monitor.onCancel = { cancelCount += 1 }

        monitor.handleRegisteredHotKeyPressForTests()
        scheduler.advance(by: 0.30)
        let consumed = monitor.handleCombinationForTests(
            type: .keyDown,
            keyCode: 53,
            flags: []
        )

        #expect(consumed)
        #expect(cancelCount == 1)
    }

    @Test("Muesli synthetic copy does not cancel an active Fn hold")
    @MainActor
    func syntheticCopyDoesNotCancelFnHold() {
        let scheduler = ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor(prepareDelay: 0.02, startDelay: 0.05)
        monitor.configure(keyCode: 63)
        monitor.doubleTapEnabled = false
        var events: [String] = []
        monitor.onPrepare = { events.append("prepare") }
        monitor.onStart = { events.append("start") }
        monitor.onStop = { events.append("stop") }
        monitor.onCancel = { events.append("cancel") }

        monitor.handleFlagsChanged(keyCode: 63, flags: .function)
        scheduler.advance(by: 0.03)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let copyKeyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 8,
                keyDown: true
              ),
              let copyEvent = NSEvent(cgEvent: copyKeyDown) else {
            // Headless CI sessions may not be able to construct synthetic events.
            return
        }
        MuesliSyntheticKeyboardEvent.mark(copyKeyDown)
        monitor.handleEventForTests(copyEvent)

        scheduler.advance(by: 0.03)
        monitor.handleFlagsChanged(keyCode: 63, flags: [])

        #expect(events == ["prepare", "start", "stop"])
    }
}

@Suite("MeetingResummarizationPolicy")
struct MeetingResummarizationPolicyTests {

    @Test("resummarize preserves the existing meeting title")
    func preservesExistingMeetingTitle() {
        let meeting = MeetingRecord(
            id: 42,
            title: "Customer pilot follow-up",
            startTime: "2026-03-24T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            wordCount: 123,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )

        #expect(
            MeetingResummarizationPolicy.plan(for: meeting) ==
            MeetingResummarizationPlan(
                promptTitle: "Customer pilot follow-up",
                persistedTitle: "Customer pilot follow-up"
            )
        )
    }

    @Test("blank titles fall back to Meeting in prompts without overwriting storage")
    func blankMeetingTitlesFallback() {
        let meeting = MeetingRecord(
            id: 43,
            title: "   ",
            startTime: "2026-03-24T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            wordCount: 123,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )

        #expect(
            MeetingResummarizationPolicy.plan(for: meeting) ==
            MeetingResummarizationPlan(
                promptTitle: "Meeting",
                persistedTitle: "   "
            )
        )
    }
}

@Suite("Meeting template resolution")
struct MeetingTemplateResolutionTests {

    @Test("exact resolution returns nil for deleted custom templates")
    func exactResolutionReturnsNilForDeletedCustomTemplates() {
        let customTemplates = [
            CustomMeetingTemplate(
                id: "tmpl_existing",
                name: "Existing Template",
                prompt: "## Summary",
                icon: "person.2"
            )
        ]

        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: "tmpl_deleted",
                customTemplates: customTemplates
            ) == nil
        )
    }

    @Test("exact resolution still supports auto and built-in templates")
    func exactResolutionSupportsDefaultTemplates() {
        let builtIn = MeetingTemplates.builtIns.first!

        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: MeetingTemplates.autoID,
                customTemplates: []
            )?.id == MeetingTemplates.autoID
        )
        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: builtIn.id,
                customTemplates: []
            )?.id == builtIn.id
        )
    }
}

@Suite("DictationState")
struct DictationStateTests {
    @Test("raw values")
    func rawValues() {
        #expect(DictationState.idle.rawValue == "idle")
        #expect(DictationState.preparing.rawValue == "preparing")
        #expect(DictationState.recording.rawValue == "recording")
        #expect(DictationState.transcribing.rawValue == "transcribing")
    }
}

@Suite("CGPointCodable")
struct CGPointCodableTests {

    @Test("keyed round-trip")
    func keyedRoundTrip() throws {
        let point = CGPointCodable(x: 100.5, y: 200.0)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CGPointCodable.self, from: data)
        #expect(decoded.x == 100.5)
        #expect(decoded.y == 200.0)
    }

    @Test("decodes from array format")
    func arrayDecode() throws {
        let json = "[42.0, 84.0]"
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CGPointCodable.self, from: data)
        #expect(decoded.x == 42.0)
        #expect(decoded.y == 84.0)
    }
}

@Suite("WordCount")
struct WordCountTests {

    @Test("basic counting")
    func basicCount() {
        #expect(DictationStore.countWords(in: "hello world") == 2)
        #expect(DictationStore.countWords(in: "one") == 1)
        #expect(DictationStore.countWords(in: "") == 0)
    }

    @Test("handles multiple whitespace")
    func multipleWhitespace() {
        #expect(DictationStore.countWords(in: "hello   world") == 2)
        #expect(DictationStore.countWords(in: "  leading and trailing  ") == 3)
    }
}

@Suite("HotkeyConfig")
struct HotkeyConfigTests {

    @Test("default is Right Option")
    func defaultConfig() {
        let config = HotkeyConfig.default
        #expect(config.keyCode == 61)
        #expect(config.label == "Right Option")
    }

    @Test("computer use default is Right Cmd")
    func computerUseDefaultConfig() {
        let config = HotkeyConfig.computerUseDefault
        #expect(config.keyCode == 54)
        #expect(config.label == "Right Cmd")
    }

    @Test("computer use fallback avoids dictation hotkey")
    func computerUseFallbackAvoidsDictationHotkey() {
        #expect(HotkeyConfig.computerUseDefault(avoiding: .default) == .computerUseDefault)
        #expect(HotkeyConfig.computerUseDefault(avoiding: .computerUseDefault) == .default)
    }

    @Test("hotkey policy blocks active duplicate shortcuts")
    func hotkeyPolicyBlocksActiveDuplicateShortcuts() {
        #expect(ShortcutHotkeyPolicy.validateDictationHotkey(
            .computerUseDefault,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: true
        ) == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))

        #expect(ShortcutHotkeyPolicy.validateDictationHotkey(
            .computerUseDefault,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false
        ) == .updated)

        #expect(ShortcutHotkeyPolicy.validateComputerUseHotkey(
            .default,
            dictationHotkey: .default,
            isComputerUseEnabled: true
        ) == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))

        #expect(ShortcutHotkeyPolicy.validateComputerUseHotkey(
            .default,
            dictationHotkey: .default,
            isComputerUseEnabled: false
        ) == .updated)
    }

    @Test("hotkey policy moves computer use key when enabling with a stale conflict")
    func hotkeyPolicyMovesComputerUseKeyWhenEnablingWithStaleConflict() {
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: .default,
            dictationHotkey: .default
        )

        #expect(resolution.hotkey == .computerUseDefault)
        #expect(resolution.result.didUpdate)
        #expect(resolution.result.message == "Computer Use Command moved to Right Cmd to avoid matching Push to Talk.")
    }

    @Test("hotkey policy rejects computer use enable when fallback conflicts with meeting recording")
    func hotkeyPolicyRejectsComputerUseEnableWhenFallbackConflictsWithMeetingRecording() {
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: .default,
            dictationHotkey: .default,
            meetingRecordingHotkey: .computerUseDefault,
            isMeetingRecordingEnabled: true
        )

        #expect(resolution.hotkey == .default)
        #expect(resolution.result == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))
    }

    @Test("hotkey policy rejects computer use enable when current shortcut conflicts with meeting recording")
    func hotkeyPolicyRejectsComputerUseEnableWhenCurrentShortcutConflictsWithMeetingRecording() {
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: .computerUseDefault,
            dictationHotkey: .default,
            meetingRecordingHotkey: .computerUseDefault,
            isMeetingRecordingEnabled: true
        )

        #expect(resolution.hotkey == .computerUseDefault)
        #expect(resolution.result == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))
    }

    @Test("combination conflicts ignore unsupported modifier flags")
    func combinationConflictsIgnoreUnsupportedModifierFlags() {
        let visible = HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 15)
        let withCapsLock = HotkeyConfig.combination(modifiers: [.command, .shift, .capsLock], keyCode: 15)

        #expect(visible.label == "⌘⇧R")
        #expect(withCapsLock.label == "⌘⇧R")
        #expect(visible.combinationModifiers == withCapsLock.combinationModifiers)
        #expect(ShortcutHotkeyPolicy.hotkeysConflict(visible, withCapsLock))
    }

    @Test("meeting recording warns for common global app shortcuts")
    func meetingRecordingWarnsForCommonGlobalAppShortcuts() {
        let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            .meetingRecordingDefault,
            dictationHotkey: .default,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false
        )

        #expect(result.didUpdate)
        #expect(result.message == ShortcutHotkeyPolicy.commonGlobalShortcutWarning)
    }

    @Test("meeting recording does not warn for uncommon global combinations")
    func meetingRecordingDoesNotWarnForUncommonGlobalCombinations() {
        let uncommon = HotkeyConfig.combination(modifiers: [.command, .option, .control], keyCode: 46)
        let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            uncommon,
            dictationHotkey: .default,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false
        )

        #expect(result == .updated)
    }

    @Test("label for known key codes")
    func knownKeyCodes() {
        #expect(HotkeyConfig.label(for: 55) == "Left Cmd")
        #expect(HotkeyConfig.label(for: 54) == "Right Cmd")
        #expect(HotkeyConfig.label(for: 63) == "Fn")
        #expect(HotkeyConfig.label(for: 59) == "Left Ctrl")
        #expect(HotkeyConfig.label(for: 62) == "Right Ctrl")
        #expect(HotkeyConfig.label(for: 58) == "Left Option")
        #expect(HotkeyConfig.label(for: 61) == "Right Option")
        #expect(HotkeyConfig.label(for: 56) == "Left Shift")
        #expect(HotkeyConfig.label(for: 60) == "Right Shift")
    }

    @Test("display label uses keyboard symbols")
    func displayLabelUsesKeyboardSymbols() {
        #expect(HotkeyConfig.default.displayLabel == "Right ⌥")
        #expect(HotkeyConfig.computerUseDefault.displayLabel == "Right ⌘")
        #expect(HotkeyConfig.meetingRecordingDefault.displayLabel == "⌘⇧R")
        #expect(HotkeyConfig(keyCode: 62, label: "Right Ctrl").displayLabel == "Right ⌃")
        #expect(HotkeyConfig(keyCode: 63, label: "Fn").displayLabel == "fn")
    }

    @Test("unknown key code returns nil")
    func unknownKeyCode() {
        #expect(HotkeyConfig.label(for: 0) == nil)
        #expect(HotkeyConfig.label(for: 100) == nil)
    }
}

@Suite("AppConfig — appearance fields")
struct AppConfigAppearanceTests {

    @Test("soundEnabled defaults to true")
    func soundEnabledDefault() {
        let config = AppConfig()
        #expect(config.soundEnabled == true)
    }

    @Test("Quill sounds default to enabled")
    func quilSoundEnabledDefault() {
        let config = AppConfig()
        #expect(config.quilSoundEnabled == true)
    }

    @Test("muteSystemAudioDuringDictation defaults to false")
    func muteSystemAudioDuringDictationDefault() {
        let config = AppConfig()
        #expect(config.muteSystemAudioDuringDictation == false)
    }

    @Test("pauseMediaDuringDictation defaults to false")
    func pauseMediaDuringDictationDefault() {
        let config = AppConfig()
        #expect(config.pauseMediaDuringDictation == false)
    }

    @Test("recordingColorHex defaults to Catppuccin Mocha base")
    func recordingColorHexDefault() {
        let config = AppConfig()
        #expect(config.recordingColorHex == "1e1e2e")
    }

    @Test("soundEnabled round-trips through JSON")
    func soundEnabledRoundTrip() throws {
        var config = AppConfig()
        config.soundEnabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.soundEnabled == false)
    }

    @Test("Quill sound preference round-trips independently from dictation sounds")
    func quilSoundEnabledRoundTrip() throws {
        var config = AppConfig()
        config.soundEnabled = true
        config.quilSoundEnabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.soundEnabled == true)
        #expect(decoded.quilSoundEnabled == false)
    }

    @Test("muteSystemAudioDuringDictation round-trips through JSON")
    func muteSystemAudioDuringDictationRoundTrip() throws {
        var config = AppConfig()
        config.muteSystemAudioDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.muteSystemAudioDuringDictation == true)
    }

    @Test("pauseMediaDuringDictation round-trips through JSON")
    func pauseMediaDuringDictationRoundTrip() throws {
        var config = AppConfig()
        config.pauseMediaDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.pauseMediaDuringDictation == true)
    }

    @Test("recordingColorHex round-trips through JSON")
    func recordingColorHexRoundTrip() throws {
        var config = AppConfig()
        config.recordingColorHex = "303446"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.recordingColorHex == "303446")
    }

    @Test("unknown JSON keys are ignored — soundEnabled falls back to default")
    func soundEnabledFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.soundEnabled == true)
    }

    @Test("missing Quill sound preference falls back to enabled")
    func quilSoundEnabledFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.quilSoundEnabled == true)
    }

    @Test("unknown JSON keys are ignored — muteSystemAudioDuringDictation falls back to default")
    func muteSystemAudioDuringDictationFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.muteSystemAudioDuringDictation == false)
    }

    @Test("unknown JSON keys are ignored — pauseMediaDuringDictation falls back to default")
    func pauseMediaDuringDictationFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.pauseMediaDuringDictation == false)
    }

    @Test("unknown JSON keys are ignored — recordingColorHex falls back to default")
    func recordingColorHexFallsBackOnMissingKey() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.recordingColorHex == "1e1e2e")
    }

    @Test("soundEnabled CodingKey is sound_enabled")
    func soundEnabledCodingKey() throws {
        var config = AppConfig()
        config.soundEnabled = false
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["sound_enabled"] as? Bool == false)
    }

    @Test("Quill sound CodingKey is quil_sound_enabled")
    func quilSoundEnabledCodingKey() throws {
        var config = AppConfig()
        config.quilSoundEnabled = false
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["quil_sound_enabled"] as? Bool == false)
    }

    @Test("muteSystemAudioDuringDictation CodingKey is mute_system_audio_during_dictation")
    func muteSystemAudioDuringDictationCodingKey() throws {
        var config = AppConfig()
        config.muteSystemAudioDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["mute_system_audio_during_dictation"] as? Bool == true)
    }

    @Test("pauseMediaDuringDictation CodingKey is pause_media_during_dictation")
    func pauseMediaDuringDictationCodingKey() throws {
        var config = AppConfig()
        config.pauseMediaDuringDictation = true
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["pause_media_during_dictation"] as? Bool == true)
    }

    @Test("recordingColorHex CodingKey is recording_color_hex")
    func recordingColorHexCodingKey() throws {
        var config = AppConfig()
        config.recordingColorHex = "eff1f5"
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["recording_color_hex"] as? String == "eff1f5")
    }
}

struct ParakeetUnifiedPlanTests {

    private func installPlan(in root: URL) throws -> ManagedASRModelPlan {
        let plan = ManagedASRModelPlans.parakeetUnified(modelsRoot: root)
        let installedPaths = [
            "parakeet_unified_encoder_int8.mlmodelc/coremldata.bin",
            "parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin",
            "parakeet_unified_decoder.mlmodelc/coremldata.bin",
            "parakeet_unified_decoder.mlmodelc/weights/weight.bin",
            "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
            "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin",
            "vocab.json",
            "metadata.json",
        ]
        let fm = FileManager.default
        for relativePath in installedPaths {
            let url = plan.cacheDirectory.appendingPathComponent(relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x01]).write(to: url)
        }
        let manifest = ModelDownloadManifest(
            id: plan.modelID,
            version: "test-install",
            files: installedPaths.map { relativePath in
                ModelDownloadFile(
                    relativePath: relativePath,
                    remoteURL: URL(string: "https://example.com/model")!,
                    expectedByteCount: 1
                )
            }
        )
        try plan.recordSuccessfulInstallation(manifest)
        return plan
    }

    @Test("Parakeet Unified plan detects a complete install")
    func completeInstallIsAvailable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pu-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let plan = try installPlan(in: root)
        #expect(plan.isAvailableLocally(fileManager: fm))
    }

    @Test("Parakeet Unified plan rejects installs with a missing artifact")
    func missingArtifactIsNotAvailable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pu-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let plan = try installPlan(in: root)
        try? fm.removeItem(at: plan.cacheDirectory.appendingPathComponent("vocab.json"))
        #expect(!plan.isAvailableLocally(fileManager: fm))
        try? fm.removeItem(at: plan.cacheDirectory.appendingPathComponent("parakeet_unified_decoder.mlmodelc"))
        #expect(!plan.isAvailableLocally(fileManager: fm))
    }

    @Test("Parakeet Unified plan rejects an incomplete mlmodelc bundle")
    func incompleteBundleIsNotAvailable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pu-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let plan = try installPlan(in: root)
        try? fm.removeItem(
            at: plan.cacheDirectory
                .appendingPathComponent("parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin")
        )
        #expect(!plan.isAvailableLocally(fileManager: fm))
    }
}

struct ParakeetLanguageTests {

    @Test("ParakeetLanguage resolves auto and pinned ISO codes")
    func resolvesAutoAndPinned() {
        #expect(ParakeetLanguage.resolved(nil) == .auto)
        #expect(ParakeetLanguage.resolved("") == .auto)
        #expect(ParakeetLanguage.resolved("auto") == .auto)
        #expect(ParakeetLanguage.resolved("en") == .english)
        #expect(ParakeetLanguage.resolved("EL") == .greek)
        #expect(ParakeetLanguage.resolved("bogus") == .auto)
    }

    @Test("ParakeetLanguage exposes labels and ISO codes")
    func exposesLabelsAndCodes() {
        #expect(ParakeetLanguage.auto.isoCode == nil)
        #expect(ParakeetLanguage.auto.label == "Auto-detect")
        #expect(ParakeetLanguage.english.isoCode == "en")
        #expect(ParakeetLanguage.english.label == "English")
        #expect(ParakeetLanguage.allCases.count == 29)
    }

    @Test("ParakeetLanguage selection survives config encode/decode round-trip")
    func persistenceRoundTrip() throws {
        var config = AppConfig()
        config.parakeetLanguage = ParakeetLanguage.german.rawValue

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.resolvedParakeetLanguage == .german)
    }
}

@Suite("OpenAIDictationProvider")
struct OpenAIDictationProviderTests {
    @Test("DictationProvider resolves raw values")
    func providerResolution() {
        #expect(DictationProvider.resolved("local") == .local)
        #expect(DictationProvider.resolved("openAI") == .openAI)
        #expect(DictationProvider.resolved("openRouter") == .openRouter)
        #expect(DictationProvider.resolved(nil) == .local)
        #expect(DictationProvider.resolved("bogus") == .local)
    }

    @Test("AppConfig persists provider settings")
    func configRoundTrip() throws {
        var config = AppConfig()
        config.dictationProvider = DictationProvider.openRouter.rawValue
        config.openaiDictationModel = "gpt-transcribe"
        config.openRouterDictationModel = "provider/transcribe"
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["dictation_provider"] as? String == "openRouter")
        #expect(json?["openai_dictation_model"] as? String == "gpt-transcribe")
        #expect(json?["openrouter_dictation_model"] as? String == "provider/transcribe")

        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.resolvedDictationProvider == .openRouter)
        #expect(decoded.openaiDictationModel == "gpt-transcribe")
        #expect(decoded.openRouterDictationModel == "provider/transcribe")
    }

    @Test("AppConfig defaults provider settings when keys are missing or invalid")
    func configDefaultsForMissingProviderSettings() throws {
        let missing = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(missing.resolvedDictationProvider == .local)
        #expect(missing.openaiDictationModel == OpenAITranscriptionClient.defaultModel)
        #expect(missing.openRouterDictationModel.isEmpty)

        let invalidJSON = Data("{\"dictation_provider\":\"bogus\"}".utf8)
        let invalid = try JSONDecoder().decode(AppConfig.self, from: invalidJSON)
        #expect(invalid.resolvedDictationProvider == .local)
        #expect(invalid.openaiDictationModel == OpenAITranscriptionClient.defaultModel)
    }

    @Test("OpenAITranscriptionClient normalizes empty model")
    func normalizeModel() {
        #expect(OpenAITranscriptionClient.normalizeModel("") == OpenAITranscriptionClient.defaultModel)
        #expect(OpenAITranscriptionClient.normalizeModel("  gpt-transcribe  ") == "gpt-transcribe")
    }

    @Test("hosted model menus are hidden without provider credentials")
    func hostedModelVisibilityWithoutCredentials() {
        let visibility = HostedDictationModelVisibility.resolve(
            openAIAPIKey: "  ",
            openRouterAPIKey: "  "
        )

        #expect(visibility.visibleProviders.isEmpty)
        #expect(!visibility.shows(.openAI))
        #expect(!visibility.shows(.openRouter))
    }

    @Test("hosted model menus show only providers with credentials")
    func hostedModelVisibilityWithProviderCredentials() {
        let openAIOnly = HostedDictationModelVisibility.resolve(
            openAIAPIKey: " sk-openai ",
            openRouterAPIKey: ""
        )
        #expect(openAIOnly.visibleProviders == [.openAI])

        let openRouterOnly = HostedDictationModelVisibility.resolve(
            openAIAPIKey: "",
            openRouterAPIKey: " sk-or-legacy "
        )
        #expect(openRouterOnly.visibleProviders == [.openRouter])

        let both = HostedDictationModelVisibility.resolve(
            openAIAPIKey: "sk-openai",
            openRouterAPIKey: "sk-or-oauth"
        )
        #expect(both.visibleProviders == [.openAI, .openRouter])
    }

    @Test("Realtime session update uses current transcription schema")
    func realtimeSessionUpdate() throws {
        let data = try #require(OpenAIRealtimeProtocol.sessionUpdate(model: "gpt-live-transcribe").data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "session.update")
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(input["turn_detection"] is NSNull)
    }

    @Test("Realtime PCM encoder resamples and clips")
    func realtimePCMEncoder() {
        var encoder = OpenAIRealtimePCMEncoder()
        let first = encoder.encode([-2, 0, 2])
        let second = encoder.encode([0, 0])
        #expect(!first.isEmpty)
        #expect(!second.isEmpty)
        #expect(first.count.isMultiple(of: 2))
        let firstPCM = first.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        #expect(Int16(littleEndian: firstPCM) == Int16.min)

        let samples = (0..<257).map { index in
            Float(sin(Double(index) * 0.07))
        }
        var oneShotEncoder = OpenAIRealtimePCMEncoder()
        let oneShot = oneShotEncoder.encode(samples)
        var chunkedEncoder = OpenAIRealtimePCMEncoder()
        var chunked = Data()
        chunked.append(chunkedEncoder.encode(Array(samples[..<79])))
        chunked.append(chunkedEncoder.encode(Array(samples[79..<181])))
        chunked.append(chunkedEncoder.encode(Array(samples[181...])))
        #expect(chunked == oneShot)
    }
}
