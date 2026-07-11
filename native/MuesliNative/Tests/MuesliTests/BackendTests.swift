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

@Suite("Gemma4LiteRTTranscriber")
struct Gemma4LiteRTTranscriberTests {

    @Test("gemma4 model uses managed LiteRT-LM metadata")
    func gemma4Model() {
        #expect(BackendOption.gemma4E2BLiteRT.backend == "gemma4-litert")
        #expect(BackendOption.gemma4E2BLiteRT.model == Gemma4LiteRTModelStore.repoID)
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("managed local weights"))
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("ASR-tuned Gemma artifact"))
        #expect(BackendOption.gemma4E2BLiteRT.description.contains("chat-style outputs fail closed"))
        #expect(Gemma4LiteRTModelStore.downloadURL.absoluteString.contains(Gemma4LiteRTModelStore.repoID))
        #expect(Gemma4LiteRTModelStore.downloadURL.absoluteString.contains(Gemma4LiteRTModelStore.modelFilename))
    }

    @Test("gemma4 stays experimental and out of onboarding")
    func gemma4Experimental() {
        #expect(BackendOption.experimental.contains(.gemma4E2BLiteRT))
        #expect(!BackendOption.onboarding.contains(.gemma4E2BLiteRT))
    }

    @available(macOS 15, *)
    @Test("gemma4 cleanup reuses the managed model and excludes Gemma ASR")
    func gemma4CleanupCompatibility() {
        let cleanup = TranscriptCleanupBackendOption.gemma4LiteRT

        #expect(cleanup.isOnDevice)
        #expect(cleanup.isGemma4LiteRT)
        #expect(cleanup.backend == BackendOption.gemma4E2BLiteRT.backend)
        #expect(TranscriptCleanupBackendOption.resolved(cleanup.backend) == cleanup)
        #expect(TranscriptCleanupClient.defaultModel(for: cleanup) == Gemma4LiteRTModelStore.repoID)
        #expect(cleanup.isCompatible(with: .parakeetMultilingual))
        #expect(!cleanup.isCompatible(with: .gemma4E2BLiteRT))
        #expect(TranscriptCleanupBackendOption.available(for: .parakeetMultilingual).contains(cleanup))
        #expect(!TranscriptCleanupBackendOption.available(for: .gemma4E2BLiteRT).contains(cleanup))
        #expect(TranscriptCleanupBackendOption.available(for: .gemma4E2BLiteRT).contains(.local))
        #expect(Gemma4LiteRTTranscriber.maxCleanupOutputTokens == 1024)
    }

    @Test("gemma4 model store uses env override and detects local file")
    func gemma4ModelStoreEnvOverride() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-gemma4-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelURL = dir.appendingPathComponent("model.litertlm")
        try Data([0x4c, 0x54, 0x4d]).write(to: modelURL)

        let environment = [Gemma4LiteRTModelStore.modelPathEnvVar: modelURL.path]
        #expect(Gemma4LiteRTModelStore.resolvedModelURL(environment: environment) == modelURL)
        #expect(Gemma4LiteRTModelStore.isAvailableLocally(environment: environment))
    }

    @Test("gemma4 override directory is not treated as a model file")
    func gemma4ModelStoreRejectsDirectoryOverride() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-gemma4-directory-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentinelURL = dir.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: sentinelURL)
        defer { try? FileManager.default.removeItem(at: dir) }

        let environment = [Gemma4LiteRTModelStore.modelPathEnvVar: dir.path]
        #expect(!Gemma4LiteRTModelStore.isAvailableLocally(environment: environment))
        #expect(!Gemma4LiteRTModelStore.isValidLiteRTLMFile(at: dir, minimumSizeBytes: 1))

        try Gemma4LiteRTModelStore.deleteModelFiles(environment: environment)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    @Test("gemma4 delete removes only explicit model override file")
    func gemma4DeleteRespectsModelOverride() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-gemma4-delete-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelURL = dir.appendingPathComponent("model.litertlm")
        let siblingURL = dir.appendingPathComponent("keep-me.txt")
        try Data([0x4c, 0x54, 0x4d]).write(to: modelURL)
        try Data("keep".utf8).write(to: siblingURL)

        let environment = [Gemma4LiteRTModelStore.modelPathEnvVar: modelURL.path]
        try Gemma4LiteRTModelStore.deleteModelFiles(environment: environment)

        #expect(!FileManager.default.fileExists(atPath: modelURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
        #expect(!Gemma4LiteRTModelStore.isAvailableLocally(environment: environment))
    }

    @Test("gemma4 default paths use managed model cache")
    func gemma4DefaultPathsUseManagedCache() {
        #expect(Gemma4LiteRTModelStore.cacheRelativePath == ".cache/muesli/models/gemma-4-e2b-litert-lm")
        #expect(Gemma4LiteRTModelStore.managedModelURL().path.hasSuffix("/.cache/muesli/models/gemma-4-e2b-litert-lm/\(Gemma4LiteRTModelStore.modelFilename)"))
        #expect(Gemma4LiteRTModelStore.managedLiteRTCacheDirectory().path.hasSuffix("/.cache/muesli/models/gemma-4-e2b-litert-lm/litert-cache"))
    }

    @Test("gemma4 managed download validation rejects tiny files")
    func gemma4ManagedDownloadValidationRejectsTinyFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-gemma4-small-\(UUID().uuidString).litertlm")
        try Data([0x4c, 0x54, 0x4d]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(Gemma4LiteRTModelStore.isValidLiteRTLMFile(at: url, minimumSizeBytes: 1))
        #expect(!Gemma4LiteRTModelStore.isValidLiteRTLMFile(
            at: url,
            minimumSizeBytes: Gemma4LiteRTModelStore.minimumDownloadedModelSizeBytes
        ))
        #expect(throws: Error.self) {
            try Gemma4LiteRTModelStore.validateDownloadedLiteRTLMFile(
                at: url,
                fileManager: .default
            )
        }
    }

    @Test("gemma4 managed download validation rejects directories")
    func gemma4ManagedDownloadValidationRejectsDirectories() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-gemma4-download-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Error.self) {
            try Gemma4LiteRTModelStore.validateDownloadedLiteRTLMFile(
                at: url,
                fileManager: .default
            )
        }
    }

    @Test("gemma4 defaults to GPU backend and allows a CPU override")
    func gemma4BackendSelection() {
        #expect(Gemma4LiteRTModelStore.resolvedBackend(environment: [:]) == "gpu")
        #expect(Gemma4LiteRTModelStore.resolvedBackend(environment: [Gemma4LiteRTModelStore.backendEnvVar: "gpu"]) == "gpu")
        #expect(Gemma4LiteRTModelStore.resolvedBackend(environment: [Gemma4LiteRTModelStore.backendEnvVar: "cpu"]) == "cpu")
        #expect(Gemma4LiteRTModelStore.resolvedBackend(environment: [Gemma4LiteRTModelStore.backendEnvVar: "webgpu"]) == "gpu")
    }

    @available(macOS 15, *)
    @Test("gemma4 follows Google's canonical ASR prompt")
    func gemma4DefaultPromptUsesGoogleASRRecipe() {
        let prompt = Gemma4LiteRTModelStore.defaultPrompt.lowercased()

        #expect(prompt.contains("transcribe the following speech segment in its original language"))
        #expect(prompt.contains("only output the transcription, with no newlines"))
        #expect(prompt.contains("when transcribing numbers, write the digits"))
        #expect(prompt.contains("write 1.7 and not one point seven"))
        #expect(Gemma4LiteRTTranscriber.maxOutputTokens == 128)
    }

    @Test("gemma4 enables MTP only for supported models unless disabled")
    func gemma4MTPSelection() {
        #expect(Gemma4LiteRTModelStore.shouldEnableMTP(modelSupportsMTP: true, environment: [:]))
        #expect(!Gemma4LiteRTModelStore.shouldEnableMTP(modelSupportsMTP: false, environment: [:]))
        #expect(!Gemma4LiteRTModelStore.shouldEnableMTP(
            modelSupportsMTP: true,
            environment: [Gemma4LiteRTModelStore.mtpEnvVar: "0"]
        ))
    }

    @available(macOS 15, *)
    @Test("gemma4 response parser throws on unrecognized content")
    func gemma4ResponseParserThrowsOnUnknownShape() {
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.textContent(fromResponseJSON: #"{"status":"ok"}"#)
        }
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.textContent(fromResponseJSON: #"{"content":[]}"#)
        }
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.textContent(
                fromResponseJSON: #"{"content":[{"type":"audio","data":"ignored"}]}"#
            )
        }
    }

    @available(macOS 15, *)
    @Test("gemma4 response parser extracts supported content shapes")
    func gemma4ResponseParserExtractsSupportedShapes() throws {
        let stringContent = try Gemma4LiteRTTranscriber.textContent(
            fromResponseJSON: #"{"content":"hello world"}"#
        )
        #expect(stringContent == "hello world")

        let arrayContent = try Gemma4LiteRTTranscriber.textContent(
            fromResponseJSON: #"{"content":[{"type":"text","text":"hello"},{"type":"text","text":"again"}]}"#
        )
        #expect(arrayContent == "hello again")
    }

    @available(macOS 15, *)
    @Test("gemma4 rejects assistant-style chat responses")
    func gemma4RejectsAssistantStyleChatResponses() {
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validatedTranscript(
                fromResponseJSON: #"{"content":"Hello! I understand you're looking for a quick and accurate transcription service. I can certainly help you with that."}"#
            )
        }
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validatedTranscript(
                fromResponseJSON: #"{"content":"That's a valid point. While GemMA 4 is a powerful model, its speed can vary depending on the specific task and hardware. Paracode, with its optimized architecture and fine-tuning for transcription cleanup, might offer a faster experience for certain applications."}"#
            )
        }
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validatedTranscript(
                fromResponseJSON: #"{"content":"I understand. I will transcribe the audio as it is and then provide the system prompt output or system prompt word-by-word."}"#
            )
        }
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validatedTranscript(
                fromResponseJSON: #"{"content":"Sure, here is the system prompt for Bard: You are a helpful and informative AI assistant."}"#
            )
        }
        #expect(Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "Please upload the audio file and I can transcribe it."
        ))
        #expect(Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "That's a valid point. While Gemma 4 is a powerful model, its speed can vary depending on the specific task and hardware."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "What is the mistake you are referring to?"
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "Sure, I can help you with that."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "I understand you're looking for help with this report."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "Hello, I am trying to check whether you can hear me properly."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "That's a valid point, and I want to transcribe the rest of this sentence literally."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "She works as an aide at the hospital."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "He served as an aide to the senator for three years."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "Speaking as an AI, I can confirm that the model is efficient."
        ))
        #expect(Gemma4LiteRTTranscriber.looksLikeAssistantResponse(
            "I am not able to respond as an AI assistant."
        ))
    }

    @available(macOS 15, *)
    @Test("gemma4 rejects substantial leaked prompt text without rejecting one quoted fragment")
    func gemma4RejectsLeakedPromptText() {
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validatedTranscript(
                fromResponseJSON: #"{"content":"Transcribe the following speech segment in its original language. Follow these specific instructions for formatting the answer."}"#
            )
        }
        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validatedTranscript(
                fromResponseJSON: #"{"content":"Only output the transcription, with no newlines. When transcribing numbers, write the digits."}"#
            )
        }

        #expect(Gemma4LiteRTTranscriber.looksLikePromptLeak(
            "Transcribe the following speech segment in its original language. Only output the transcription, with no newlines."
        ))
        #expect(!Gemma4LiteRTTranscriber.looksLikePromptLeak(
            "When transcribing numbers, write the digits."
        ))
    }

    @available(macOS 15, *)
    @Test("gemma4 validated transcript passes normal dictation")
    func gemma4ValidatedTranscriptPassesNormalDictation() throws {
        let text = try Gemma4LiteRTTranscriber.validatedTranscript(
            fromResponseJSON: #"{"content":"Hello, I am trying to check whether you can hear me properly."}"#
        )
        #expect(text == "Hello, I am trying to check whether you can hear me properly.")

        let quotedAssistantPhrase = try Gemma4LiteRTTranscriber.validatedTranscript(
            fromResponseJSON: #"{"content":"Sure, I can help you with that."}"#
        )
        #expect(quotedAssistantPhrase == "Sure, I can help you with that.")
    }

    @available(macOS 15, *)
    @Test("gemma4 cleanTranscript strips prefixes without corrupting transcription: prefix")
    func gemma4CleanTranscriptPrefixOrdering() {
        // "transcript:" is a prefix of "transcription:", so the longer form must be checked first.
        // If "transcript:" were matched first, "Transcription: Hello world" would drop only 11 chars
        // yielding "on: Hello world" instead of "Hello world".
        #expect(Gemma4LiteRTTranscriber.cleanTranscript("Transcription: Hello world") == "Hello world")
        #expect(Gemma4LiteRTTranscriber.cleanTranscript("Transcript: Hello world") == "Hello world")
        #expect(Gemma4LiteRTTranscriber.cleanTranscript("Final transcript: Hello world") == "Hello world")
        // Longer prefix takes precedence over shorter overlapping prefix
        #expect(Gemma4LiteRTTranscriber.cleanTranscript("Transcription: transcript:") == "transcript:")
    }

    @available(macOS 15, *)
    @Test("gemma4 user message puts Google's ASR instruction before audio")
    func gemma4UserMessageContainsPromptThenAudio() throws {
        let wavURL = URL(fileURLWithPath: "/tmp/muesli-gemma4-sample.wav")
        let messageJSON = try Gemma4LiteRTTranscriber.userMessageJSONString(wavURL: wavURL)
        let data = try #require(messageJSON.data(using: .utf8))
        let message = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try #require(message["content"] as? [[String: String]])

        #expect(message["role"] as? String == "user")
        #expect(content.count == 2)
        #expect(content[0] == ["type": "text", "text": Gemma4LiteRTModelStore.defaultPrompt])
        #expect(content[1] == ["type": "audio", "path": wavURL.path])
    }

    @available(macOS 15, *)
    @Test("gemma4 rejects audio longer than Google's 30 second limit")
    func gemma4RejectsLongAudio() throws {
        let samples = [Float](repeating: 0, count: 31 * Int(WavWriter.sampleRate))
        let wavURL = try WavWriter.writeTemporaryWAV(samples: samples, directoryName: "muesli-gemma4-duration-test")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(throws: Gemma4LiteRTTranscriber.TranscriberError.self) {
            try Gemma4LiteRTTranscriber.validateAudioDuration(wavURL: wavURL)
        }
    }

    @available(macOS 15, *)
    @Test("gemma4 optional runtime smoke test")
    func gemma4OptionalRuntimeSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MUESLI_GEMMA4_LITERT_RUNTIME_SMOKE"] == "1",
              let samplePath = environment["MUESLI_GEMMA4_LITERT_SAMPLE_WAV"] else {
            return
        }

        let transcriber = Gemma4LiteRTTranscriber()
        try await transcriber.prepare()
        let result = try await transcriber.transcribe(wavURL: URL(fileURLWithPath: samplePath))
        #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let cleanup = try await transcriber.cleanTranscript(
            "Um, this is teh final releese.",
            systemPrompt: PostProcessorOption.defaultSystemPrompt,
            appContext: nil
        )
        #expect(!cleanup.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(cleanup.text.localizedCaseInsensitiveContains("the final release"))
        #expect(cleanup.processingTime > 0)
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
        #expect(backendCounts["nemotron35"]! == 1, "Nemotron 3.5 should be the only Nemotron backend")
        #expect(backendCounts["gemma4-litert"]! == 1, "Gemma 4 LiteRT should have exactly 1 experimental model")
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
