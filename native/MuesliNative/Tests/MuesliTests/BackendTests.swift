import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {

    @Test("whisper models use whisper backend")
    func whisperModelsBackend() {
        let whisperOptions = BackendOption.all.filter { $0.backend == "whisper" }
        for option in whisperOptions {
            #expect(option.backend == "whisper", "\(option.label) should use whisper backend")
        }
    }

    @Test("whisper models use WhisperKit variant names")
    func whisperModelsVariantNames() {
        let whisperOptions = BackendOption.all.filter { $0.backend == "whisper" }
        for option in whisperOptions {
            // WhisperKit models should NOT have ggml- prefix (that was the old SwiftWhisper format)
            #expect(!option.model.hasPrefix("ggml-"), "\(option.label) should not use ggml- prefix")
            #expect(!option.model.hasSuffix(".bin"), "\(option.label) should not use .bin suffix")
        }
    }
}

@Suite("FluidAudioTranscriber")
struct FluidAudioTranscriberTests {

    @Test("parakeet models use FluidInference repo")
    func parakeetModels() {
        #expect(BackendOption.parakeetMultilingual.model.contains("FluidInference"))
        #expect(BackendOption.parakeetEnglish.model.contains("FluidInference"))
    }

    @Test("v2 model contains v2 in path")
    func v2Identification() {
        #expect(BackendOption.parakeetEnglish.model.contains("v2"))
        #expect(!BackendOption.parakeetMultilingual.model.contains("v2"))
    }

    @Test("v3 model contains v3 in path")
    func v3Identification() {
        #expect(BackendOption.parakeetMultilingual.model.contains("v3"))
    }
}

@Suite("SenseVoiceTranscriber")
struct SenseVoiceTranscriberTests {

    @Test("sensevoice model uses FluidAudio CoreML repo")
    func senseVoiceModel() {
        #expect(BackendOption.senseVoiceSmall.backend == "sensevoice")
        #expect(BackendOption.senseVoiceSmall.model.contains("FluidInference"))
        #expect(BackendOption.senseVoiceSmall.model.contains("sensevoice"))
    }

    @Test("sensevoice stays experimental")
    func senseVoiceExperimental() {
        #expect(BackendOption.experimental.contains(.senseVoiceSmall))
        #expect(!BackendOption.onboarding.contains(.senseVoiceSmall))
    }

    @Test("sensevoice cache path uses FluidAudio model store")
    func senseVoiceCachePath() {
        #expect(SenseVoiceTranscriber.cacheRelativePath == "Library/Application Support/FluidAudio/Models/sensevoice-small-coreml")
        #expect(SenseVoiceTranscriber.cacheDirectory().path.hasSuffix(SenseVoiceTranscriber.cacheRelativePath))
    }

    @Test("sensevoice metadata reflects INT8 download footprint")
    func senseVoiceInt8DownloadMetadata() {
        #expect(SenseVoiceTranscriber.downloadedModelSizeLabel == "~240 MB")
        #expect(BackendOption.senseVoiceSmall.sizeLabel == SenseVoiceTranscriber.downloadedModelSizeLabel)
        #expect(BackendOption.senseVoiceSmall.description.contains("INT8"))
    }
}

@Suite("NemotronStreamingTranscriber")
struct NemotronStreamingTranscriberTests {

    @Test("nemotron model references coreml repo")
    func nemotronModel() {
        #expect(BackendOption.nemotronStreaming.model.contains("coreml"))
        #expect(BackendOption.nemotronStreaming.model.contains("FluidInference"))
        #expect(BackendOption.nemotronStreaming.model.contains("nemotron"))
    }

    @Test("nemotron uses streaming in label")
    func nemotronLabel() {
        #expect(BackendOption.nemotronStreaming.label.lowercased().contains("streaming"))
    }
}

@Suite("Backend coverage")
struct BackendCoverageTests {

    @Test("each backend has at least one model")
    func eachBackendHasModel() {
        let backendCounts = Dictionary(grouping: BackendOption.all, by: \.backend)
            .mapValues(\.count)
        #expect(backendCounts["fluidaudio"]! >= 2, "FluidAudio should have at least 2 models")
        #expect(backendCounts["whisper"]! >= 1, "Whisper should have at least 1 model")
        #expect(backendCounts["sensevoice"]! >= 1, "SenseVoice should have at least 1 model")
        // Nemotron excluded from .all until RNNT decode is validated
        // #expect(backendCounts["nemotron"]! >= 1)
    }

    @Test("size labels are human-readable")
    func sizeLabelsReadable() {
        for option in BackendOption.all {
            #expect(option.sizeLabel.contains("MB") || option.sizeLabel.contains("GB"),
                    "\(option.label) sizeLabel should contain MB or GB: \(option.sizeLabel)")
        }
    }

    @Test("descriptions are informative")
    func descriptionsMinLength() {
        for option in BackendOption.all {
            #expect(option.description.count > 20,
                    "\(option.label) description too short: \(option.description)")
        }
    }
}
