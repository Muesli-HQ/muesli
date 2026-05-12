import Testing
import AppKit
import Foundation
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
        let known: Set<String> = ["fluidaudio", "whisper", "qwen", "nemotron", "canary", "cohere"]
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
        #expect(BackendOption.whisperSmall.backend == "whisper")
        #expect(BackendOption.whisperMedium.backend == "whisper")
        #expect(BackendOption.whisperLargeTurbo.backend == "whisper")
    }

    @Test("Nemotron uses nemotron backend")
    func nemotronBackend() {
        #expect(BackendOption.nemotronStreaming.backend == "nemotron")
        #expect(BackendOption.nemotronStreaming.model.contains("nemotron"))
    }

    @Test("whisper alias points to parakeetMultilingual")
    func whisperAlias() {
        #expect(BackendOption.whisper == BackendOption.parakeetMultilingual)
    }

    @Test("all contains all defined options")
    func allContainsAll() {
        #expect(BackendOption.all.contains(.parakeetMultilingual))
        #expect(BackendOption.all.contains(.parakeetEnglish))
        #expect(BackendOption.all.contains(.whisperSmall))
        #expect(BackendOption.all.contains(.whisperMedium))
        #expect(BackendOption.all.contains(.whisperLargeTurbo))
        #expect(BackendOption.all.contains(.qwen3Asr))
        #expect(BackendOption.all.contains(.canaryQwen))
        #expect(BackendOption.all.contains(.cohereTranscribe))
        #expect(BackendOption.all.contains(.nemotronStreaming))
    }

    @Test("Cohere uses cohere backend")
    func cohereBackend() {
        #expect(BackendOption.cohereTranscribe.backend == "cohere")
        #expect(BackendOption.cohereTranscribe.model.contains("cohere"))
    }

    @Test("Cohere is not in experimental list")
    func cohereNotExperimental() {
        #expect(!BackendOption.experimental.contains(.cohereTranscribe))
    }

    @Test("onboarding model choices exclude experimental models")
    func onboardingModelsExcludeExperimentalOptions() {
        #expect(BackendOption.onboarding == [.parakeetMultilingual, .whisperTinyEnglish, .whisperSmall, .cohereTranscribe])
        for option in BackendOption.experimental {
            #expect(!BackendOption.onboarding.contains(option))
        }
    }

    @Test("Whisper models use WhisperKit CoreML identifiers")
    func whisperKitModels() {
        // WhisperKit models use short variant names, not ggml- prefixed binaries
        #expect(BackendOption.whisperTinyEnglish.model == "tiny.en")
        #expect(BackendOption.whisperSmall.model == "small.en")
        #expect(BackendOption.whisperMedium.model == "medium.en")
        #expect(BackendOption.whisperLargeTurbo.model.contains("large"))
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

    @Test("default option is first and matches config default")
    func defaultOption() {
        #expect(PostProcessorOption.all.first == PostProcessorOption.defaultOption)
        #expect(AppConfig().activePostProcessorId == PostProcessorOption.defaultOption.id)
    }

    @Test("unknown ids resolve to default")
    func unknownIDResolvesToDefault() {
        #expect(PostProcessorOption.resolve(id: "missing") == PostProcessorOption.defaultOption)
    }

    @Test("resolveDownloaded prefers selected downloaded option")
    func resolveDownloadedPrefersSelected() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.finetunedV2.id,
            PostProcessorOption.qwen35_0_8b.id,
        ]
        #expect(PostProcessorOption.resolveDownloaded(
            id: PostProcessorOption.qwen35_0_8b.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.qwen35_0_8b)
    }

    @Test("resolveDownloaded falls back to first downloaded option")
    func resolveDownloadedFallsBack() {
        let downloadedIDs: Set<String> = [PostProcessorOption.finetunedV2.id]
        #expect(PostProcessorOption.resolveDownloaded(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.finetunedV2)
    }

    @Test("runtimeOption prefers selected downloaded option")
    func runtimeOptionPrefersSelectedDownloadedOption() {
        let downloadedIDs: Set<String> = [
            PostProcessorOption.finetunedV2.id,
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
        let downloadedIDs: Set<String> = [PostProcessorOption.finetunedV2.id]
        #expect(PostProcessorOption.runtimeOption(
            id: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: false
        ) == PostProcessorOption.finetunedV2)
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
            PostProcessorOption.finetunedV2.id,
        ]
        #expect(PostProcessorOption.firstDownloaded(
            excluding: PostProcessorOption.finetunedV3.id,
            downloadedIDs: downloadedIDs
        ) == PostProcessorOption.finetunedV2)
    }
}

@Suite("SummaryModelPreset")
struct SummaryModelPresetTests {

    @Test("OpenAI presets have valid model IDs")
    func openAIModels() {
        #expect(!SummaryModelPreset.openAIModels.isEmpty)
        for preset in SummaryModelPreset.openAIModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("OpenRouter presets have valid model IDs")
    func openRouterModels() {
        #expect(!SummaryModelPreset.openRouterModels.isEmpty)
        for preset in SummaryModelPreset.openRouterModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("Computer use planner presets include GPT-5.5 default")
    func computerUsePlannerModels() {
        #expect(SummaryModelPreset.computerUsePlannerModels.first?.id == "gpt-5.5")
        #expect(SummaryModelPreset.computerUsePlannerModels.contains { $0.id == "gpt-5.4-mini" })
        for preset in SummaryModelPreset.computerUsePlannerModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
        }
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
        #expect(MeetingSummaryBackendOption.all.count == 4)
        #expect(MeetingSummaryBackendOption.all.contains(.openAI))
        #expect(MeetingSummaryBackendOption.all.contains(.openRouter))
        #expect(MeetingSummaryBackendOption.all.contains(.chatGPT))
        #expect(MeetingSummaryBackendOption.all.contains(.ollama))
    }

    @Test("backend strings are lowercase")
    func backendStrings() {
        #expect(MeetingSummaryBackendOption.openAI.backend == "openai")
        #expect(MeetingSummaryBackendOption.openRouter.backend == "openrouter")
        #expect(MeetingSummaryBackendOption.ollama.backend == "ollama")
    }

    @Test("configured values resolve with ChatGPT fallback")
    func resolvedValues() {
        #expect(MeetingSummaryBackendOption.resolved("chatgpt") == .chatGPT)
        #expect(MeetingSummaryBackendOption.resolved("openrouter") == .openRouter)
        #expect(MeetingSummaryBackendOption.resolved("ollama") == .ollama)
        #expect(MeetingSummaryBackendOption.resolved("unknown") == .chatGPT)
        #expect(MeetingSummaryBackendOption.resolved(nil) == .chatGPT)
    }
}

@Suite("AppConfig")
struct AppConfigTests {

    @Test("default values")
    func defaults() {
        let config = AppConfig()
        #expect(config.sttBackend == BackendOption.whisper.backend)
        #expect(config.sttModel == BackendOption.whisper.model)
        #expect(config.cohereLanguage == CohereTranscribeLanguage.defaultLanguage.rawValue)
        #expect(config.meetingTranscriptionBackend == BackendOption.whisper.backend)
        #expect(config.meetingTranscriptionModel == BackendOption.whisper.model)
        #expect(config.meetingSummaryBackend == "chatgpt")
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.meetingRecordingSavePolicy == .never)
        #expect(config.showScheduledMeetingNotifications == true)
        #expect(config.showMeetingDetectionNotification == true)
        #expect(config.mutedMeetingDetectionAppBundleIDs.isEmpty)
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.openRouterAPIKey.isEmpty)
        #expect(config.ollamaURL == "http://localhost:11434")
        #expect(config.ollamaModel == "qwen3.5")
        #expect(config.dictationHotkey == .default)
        #expect(config.computerUseHotkey == .computerUseDefault)
        #expect(config.enableComputerUseHotkey == false)
        #expect(config.computerUseHotkeyDefaultDisabledMigrationApplied == true)
        #expect(config.enableComputerUsePlanner == true)
        #expect(config.computerUsePlannerModel.isEmpty)
        #expect(config.computerUseTimeoutSeconds == 120)
        #expect(config.showFloatingIndicator == true)
        #expect(config.indicatorAnchor == .midTrailing)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.resolvedOnboardingUseCase == .dictation)
        #expect(config.userName.isEmpty)
        #expect(config.customMeetingTemplates.isEmpty)
        #expect(config.meetingHookEnabled == false)
        #expect(config.meetingHookPath.isEmpty)
        #expect(config.meetingHookTimeoutSeconds == 30)
    }

    @Test("JSON encode/decode round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.openAIAPIKey = "sk-test-key-123"
        config.userName = "Test User"
        config.hasCompletedOnboarding = true
        config.onboardingUseCase = OnboardingUseCase.dictationAndMeetings.rawValue
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.defaultMeetingTemplateID = "weekly-team-meeting"
        config.meetingRecordingSavePolicy = .always
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
        config.showScheduledMeetingNotifications = false
        config.showMeetingDetectionNotification = false
        config.mutedMeetingDetectionAppBundleIDs = ["com.google.Chrome", "com.tinyspeck.slackmacgap"]
        config.computerUseHotkey = HotkeyConfig(keyCode: 62, label: "Right Ctrl")
        config.enableComputerUseHotkey = false
        config.enableComputerUsePlanner = false
        config.computerUsePlannerModel = "gpt-5.4"
        config.computerUseTimeoutSeconds = 180

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.openAIAPIKey == "sk-test-key-123")
        #expect(decoded.userName == "Test User")
        #expect(decoded.hasCompletedOnboarding == true)
        #expect(decoded.resolvedOnboardingUseCase == .dictationAndMeetings)
        #expect(decoded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(decoded.defaultMeetingTemplateID == "weekly-team-meeting")
        #expect(decoded.meetingRecordingSavePolicy == .always)
        #expect(decoded.customMeetingTemplates.count == 1)
        #expect(decoded.customMeetingTemplates.first?.name == "Customer Follow-Up")
        #expect(decoded.customMeetingTemplates.first?.icon == "dollarsign.circle")
        #expect(decoded.meetingHookEnabled == true)
        #expect(decoded.meetingHookPath == "/tmp/meeting-hook.sh")
        #expect(decoded.meetingHookTimeoutSeconds == 45)
        #expect(decoded.showScheduledMeetingNotifications == false)
        #expect(decoded.showMeetingDetectionNotification == false)
        #expect(decoded.mutedMeetingDetectionAppBundleIDs == ["com.google.Chrome", "com.tinyspeck.slackmacgap"])
        #expect(decoded.meetingTranscriptionBackend == config.meetingTranscriptionBackend)
        #expect(decoded.indicatorAnchor == config.indicatorAnchor)
        #expect(decoded.computerUseHotkey == HotkeyConfig(keyCode: 62, label: "Right Ctrl"))
        #expect(decoded.enableComputerUseHotkey == false)
        #expect(decoded.enableComputerUsePlanner == false)
        #expect(decoded.computerUsePlannerModel == "gpt-5.4")
        #expect(decoded.computerUseTimeoutSeconds == 180)
    }

    @Test("JSON coding keys use snake_case")
    func snakeCaseKeys() throws {
        let config = AppConfig()
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
        #expect(json["cohere_language"] != nil)
        #expect(json["meeting_transcription_backend"] != nil)
        #expect(json["meeting_transcription_model"] != nil)
        #expect(json["indicator_anchor"] != nil)
        #expect(json["has_completed_onboarding"] != nil)
        #expect(json["onboarding_use_case"] != nil)
        #expect(json["user_name"] != nil)
        #expect(json["default_meeting_template_id"] != nil)
        #expect(json["meeting_recording_save_policy"] != nil)
        #expect(json["show_scheduled_meeting_notifications"] != nil)
        #expect(json["show_meeting_detection_notification"] != nil)
        #expect(json["muted_meeting_detection_app_bundle_ids"] != nil)
        #expect(json["custom_meeting_templates"] != nil)
        #expect(json["meeting_hook_enabled"] != nil)
        #expect(json["meeting_hook_path"] != nil)
        #expect(json["meeting_hook_timeout_seconds"] != nil)
    }

    @Test("decodes with missing fields using defaults")
    func missingFieldsUseDefaults() throws {
        let json = "{\"stt_backend\": \"whisper\"}"
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.showFloatingIndicator == true)
        #expect(config.resolvedCohereLanguage == .english)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.resolvedOnboardingUseCase == .dictation)
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.meetingRecordingSavePolicy == .never)
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
        #expect(config.meetingHookEnabled == false)
        #expect(config.meetingHookPath.isEmpty)
        #expect(config.meetingHookTimeoutSeconds == 30)
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

    @Test("recordingColorHex CodingKey is recording_color_hex")
    func recordingColorHexCodingKey() throws {
        var config = AppConfig()
        config.recordingColorHex = "eff1f5"
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["recording_color_hex"] as? String == "eff1f5")
    }
}
